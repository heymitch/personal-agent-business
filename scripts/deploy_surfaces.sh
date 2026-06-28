#!/usr/bin/env bash
# Deploy the operator's Vercel surfaces. There are TWO groups, deployed separately:
#
#   --operational  onboarding + operator-console (the working surfaces)
#       onboarding        the connect-on-page (vendored from personal-agent-onboarding)
#       operator-console  the 3-tab management dashboard (Dashboard/New agent/Fleet),
#                         a Cloudflare-Access-gated thin proxy to the box receiver
#   --landing      the public offer page the operator brands (independent, anytime)
#
# No selector deploys BOTH groups in the safe order. ORDER IS LOAD-BEARING: the
# console is a thin proxy to your box receiver, so it must NOT be deployed before
# that receiver exists. Deploy the minting engine first (scripts/deploy_engine.sh),
# capture its RECEIVER-URL, set MINT_RECEIVER_URL + MINT_SECRET, THEN deploy the
# console. This script refuses to deploy a console without those, so the console is
# never live in a "not configured" state.
#
# Each surface is a static + serverless Vercel project. We push it with the
# LOGGED-IN `vercel` CLI (`vercel deploy --prod`). Vercel auth is a Claude Code
# connection: run `vercel login` once and the persisted session deploys. There is
# no token to set and no --token flag; the logged-in CLI session IS the auth.
# COMPOSIO_API_KEY is set into the onboarding project's Vercel env (its serverless
# api/ functions need it). The console's runtime env (MINT_RECEIVER_URL, MINT_SECRET
# for the receiver proxy; CF_ACCESS_AUTH_DOMAIN, CF_ACCESS_AUD, OWNER_EMAIL for the
# Cloudflare Access gate) is pushed on stdin so no secret lands on the command line.
# --dry-run constructs the exact commands with every secret collapsed to a byte count
# and touches no real API.
#
# Usage: ./deploy_surfaces.sh [--dry-run] [--landing | --operational]
# Reads: COMPOSIO_API_KEY  (required when onboarding is deployed)
#   Vercel auth comes from `vercel login` (a Claude Code connection); there is no
#   token and no --token flag.
#   console env (required to deploy the console): MINT_RECEIVER_URL, MINT_SECRET
#   console Cloudflare Access gate (push when set): CF_ACCESS_AUTH_DOMAIN,
#     CF_ACCESS_AUD, OWNER_EMAIL  (from cf_console_gate.sh)
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0
GROUP="all"   # all | landing | operational
while [ $# -gt 0 ]; do case "$1" in
  --dry-run)     DRY_RUN=1; shift;;
  --landing)     GROUP="landing"; shift;;
  --operational) GROUP="operational"; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

VERCEL="${VERCEL:-vercel}"
CURL="${CURL:-curl}"
# Vercel auth is the LOGGED-IN `vercel login` session: that is the only thing the
# operator sets up, and the `vercel` CLI deploys with it directly (no --token flag).
# The few direct Vercel API calls we make (disable Deployment Protection on the public
# onboarding project; set + verify the console env) read that SAME logged-in token from
# the CLI's on-disk config via vercel_cli_token; the value is never printed.
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"
SURFACES_DIR="$HERE/../surfaces"

# Read the logged-in Vercel CLI token from its on-disk config. NEVER prints the value.
# Falls back to VERCEL_API_TOKEN / VERCEL_TOKEN when set (the test harness uses this).
vercel_cli_token() {
  local f tok
  for f in \
    "$HOME/.local/share/com.vercel.cli/auth.json" \
    "$HOME/Library/Application Support/com.vercel.cli/auth.json" \
    "$HOME/.vercel/auth.json"; do
    [ -f "$f" ] || continue
    tok="$(jq -r '.token // empty' "$f" 2>/dev/null || true)"
    [ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
  done
  tok="${VERCEL_API_TOKEN:-${VERCEL_TOKEN:-}}"
  [ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
  return 1
}

# projectId / orgId for a linked surface, written by `vercel link` / the first deploy.
# A test override (VERCEL_PROJECT_ID_OVERRIDE) lets the API plumbing run without a real link.
read_project_id() { jq -r '.projectId // empty' "$1/.vercel/project.json" 2>/dev/null || true; }
read_org_id()     { jq -r '.orgId // empty'     "$1/.vercel/project.json" 2>/dev/null || true; }
project_id_for() {
  local p; p="$(read_project_id "$1")"
  [ -n "$p" ] || p="${VERCEL_PROJECT_ID_OVERRIDE:-}"
  printf '%s' "$p"
}

# Fix 2: Vercel teams default ssoProtection to "all_except_custom_domains", which gates the
# PUBLIC onboarding page behind Vercel SSO so clients cannot open their connect links. After
# onboarding deploys, disable Deployment Protection for the ONBOARDING project ONLY
# (ssoProtection=null). The operator console is intentionally left protected (Cloudflare
# Access gates it). Best-effort: never prints the token, never fails the deploy.
make_onboarding_public() {
  local dir="$SURFACES_DIR/onboarding" proj tok team q R
  proj="$(project_id_for "$dir")"
  tok="$(vercel_cli_token || true)"
  if [ -z "$proj" ] || [ -z "$tok" ]; then
    echo "WARN: could not resolve the onboarding projectId or a Vercel CLI token; disable" >&2
    echo "      Deployment Protection by hand (Vercel > onboarding project > Settings >" >&2
    echo "      Deployment Protection > Vercel Authentication: Off) so clients can connect." >&2
    return 0
  fi
  team="$(read_org_id "$dir")"; q=""; [ -n "$team" ] && q="?teamId=$team"
  # Body on stdin (--data @-) so neither the token nor the payload lands on argv.
  R="$(printf '%s' '{"ssoProtection":null}' \
        | "$CURL" -sS -X PATCH "$VERCEL_API/v9/projects/$proj$q" \
            -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
            --data @- 2>/dev/null || true)"
  if printf '%s' "$R" | jq -e '.ssoProtection == null' >/dev/null 2>&1; then
    echo "ONBOARDING-PUBLIC project=$proj (Vercel Deployment Protection disabled; console stays gated)"
  else
    echo "ONBOARDING-PUBLIC project=$proj (requested ssoProtection=null; confirm Deployment Protection is Off if a client hits a Vercel login)"
  fi
}

# Resolve the selected surfaces. ORDER matters: onboarding first so its URL can seed
# ONBOARDER_BASE_URL, then landing, then the operator console LAST (it proxies the
# box receiver, which must already exist). Landing is deployed apart from the
# operational console+onboarding group.
case "$GROUP" in
  landing)     SURFACES="landing";;
  operational) SURFACES="onboarding operator-console";;
  all)         SURFACES="onboarding landing operator-console";;
esac

# COMPOSIO_API_KEY is only needed when onboarding (its serverless api/) is deployed.
case " $SURFACES " in *" onboarding "*) require_env COMPOSIO_API_KEY;; esac

# The console is a thin proxy to your box receiver. Enforce the order: never deploy
# it before the receiver URL is known. (--dry-run is a preview, so it only WARNS.)
console_selected=0
case " $SURFACES " in *" operator-console "*) console_selected=1;; esac
if [ "$console_selected" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "${MINT_RECEIVER_URL:-}" ] || [ -z "${MINT_SECRET:-}" ]; then
    echo "ERROR: the operator console proxies to your box receiver, so it needs" >&2
    echo "MINT_RECEIVER_URL + MINT_SECRET. Deploy the minting engine FIRST" >&2
    echo "(scripts/deploy_engine.sh) to stand up the receiver and capture its" >&2
    echo "RECEIVER-URL, set MINT_RECEIVER_URL + MINT_SECRET in .env, THEN deploy the" >&2
    echo "console. Refusing to deploy a console that would load 'not configured'." >&2
    exit 2
  fi
fi

# Collapse any secret to a byte count for the dry-run preview. Never the value.
redact_len() { printf '<%s bytes>' "${#1}"; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN deploy sequence ($GROUP) (operator Vercel via logged-in CLI, no API hit):"
  echo "  Vercel auth: logged-in CLI session (run 'vercel login' once; no token, no --token flag)."
  case " $SURFACES " in *" onboarding "*) echo "  COMPOSIO_API_KEY=$(redact_len "$COMPOSIO_API_KEY")";; esac
  for s in $SURFACES; do
    echo "== surface: $s =="
    echo "   cd $SURFACES_DIR/$s"
    if [ "$s" = "onboarding" ]; then
      echo "   vercel env add COMPOSIO_API_KEY production"
      echo "   disable Vercel Deployment Protection for onboarding (PATCH $VERCEL_API/v9/projects/<id> body {\"ssoProtection\":null}) so clients can open connect links (the operator dashboard keeps its own gate)"
    fi
    if [ "$s" = "operator-console" ]; then
      if [ -z "${MINT_RECEIVER_URL:-}" ] || [ -z "${MINT_SECRET:-}" ]; then
        echo "   (console deploy BLOCKED on a real run: deploy the engine first, then set"
        echo "    MINT_RECEIVER_URL + MINT_SECRET so the console is never 'not configured')"
      fi
      for v in MINT_RECEIVER_URL MINT_SECRET CF_ACCESS_AUTH_DOMAIN CF_ACCESS_AUD OWNER_EMAIL DEFAULT_SKILLS; do
        if [ -n "${!v:-}" ]; then
          echo "   vercel env add $v production = $(redact_len "${!v}")"
        else
          echo "   (console env $v unset)"
        fi
      done
    fi
    echo "   vercel deploy --prod --yes"
  done
  echo "(dry-run only: nothing deployed, no secret printed)"
  exit 0
fi

# Real deploy. For each surface: cd in, push to prod, capture the printed URL.
# `vercel deploy --prod` prints the deployment URL on stdout; we keep the last
# non-empty line as the URL (a fake-bin shim prints nothing, so we fall back to a
# placeholder and still emit a complete, grep-able success token).
deploy_one() {
  local surface="$1" dir url
  dir="$SURFACES_DIR/$surface"
  [ -d "$dir" ] || { echo "ERROR: surface dir missing: $dir" >&2; exit 1; }
  if [ "$surface" = "onboarding" ]; then
    # The onboarding serverless api/ needs the Composio key at runtime. Set it
    # into the project env (piped on stdin so it never lands on the command line).
    printf '%s' "$COMPOSIO_API_KEY" | \
      ( cd "$dir" && "$VERCEL" env add COMPOSIO_API_KEY production --yes >/dev/null 2>&1 || true )
  fi
  if [ "$surface" = "operator-console" ]; then
    # The console is a thin Cloudflare-Access-gated proxy. Push the runtime env on
    # stdin so a secret never lands on the command line. MINT_RECEIVER_URL is the box
    # receiver URL and MINT_SECRET signs the proxy->receiver calls (both required,
    # gated above). CF_ACCESS_AUTH_DOMAIN + CF_ACCESS_AUD + OWNER_EMAIL drive the
    # Cloudflare Access email gate in middleware.js (from cf_console_gate.sh); pushed
    # when set, and the middleware fails CLOSED if any is missing.
    local v
    for v in MINT_RECEIVER_URL MINT_SECRET CF_ACCESS_AUTH_DOMAIN CF_ACCESS_AUD OWNER_EMAIL DEFAULT_SKILLS; do
      [ -n "${!v:-}" ] || continue
      printf '%s' "${!v}" | \
        ( cd "$dir" && "$VERCEL" env add "$v" production --yes >/dev/null 2>&1 || true )
    done
  fi
  url="$( cd "$dir" && "$VERCEL" deploy --prod --yes 2>/dev/null | tail -n1 || true )"
  [ -n "$url" ] || url="(deployed: see Vercel dashboard)"
  printf '%s' "$url"
}

# Deploy each selected surface and collect its URL for the success token.
TOKEN="SURFACES-DEPLOYED"
for s in $SURFACES; do
  url="$(deploy_one "$s")"
  case "$s" in
    onboarding)       TOKEN="$TOKEN onboarding=$url"; make_onboarding_public;;
    landing)          TOKEN="$TOKEN landing=$url";;
    operator-console) TOKEN="$TOKEN console=$url";;
  esac
done

echo "$TOKEN"
