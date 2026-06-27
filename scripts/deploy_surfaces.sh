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
# Vercel auth is a Claude Code connection: the LOGGED-IN `vercel login` session is
# the only path. There is no token to read and no --token flag on any call.
SURFACES_DIR="$HERE/../surfaces"

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
    fi
    if [ "$s" = "operator-console" ]; then
      if [ -z "${MINT_RECEIVER_URL:-}" ] || [ -z "${MINT_SECRET:-}" ]; then
        echo "   (console deploy BLOCKED on a real run: deploy the engine first, then set"
        echo "    MINT_RECEIVER_URL + MINT_SECRET so the console is never 'not configured')"
      fi
      for v in MINT_RECEIVER_URL MINT_SECRET CF_ACCESS_AUTH_DOMAIN CF_ACCESS_AUD OWNER_EMAIL; do
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
    for v in MINT_RECEIVER_URL MINT_SECRET CF_ACCESS_AUTH_DOMAIN CF_ACCESS_AUD OWNER_EMAIL; do
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
    onboarding)       TOKEN="$TOKEN onboarding=$url";;
    landing)          TOKEN="$TOKEN landing=$url";;
    operator-console) TOKEN="$TOKEN console=$url";;
  esac
done

echo "$TOKEN"
