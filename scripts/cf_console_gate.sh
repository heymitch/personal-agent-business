#!/usr/bin/env bash
# Stand up the Cloudflare Access email gate for the OPERATOR CONSOLE: the SAME gate
# the client agent surfaces use (cf_portal.sh), minus the tunnel. The console runs on
# Vercel, so there is no origin to tunnel; we just gate its hostname with a
# self_hosted Access app whose policy allows ONLY the operator's email.
#
# Prereqs (narrated in /setup): the console is reachable at CONSOLE_HOST
# (default console.<AGENT_DOMAIN>) as a Cloudflare-proxied record pointing at the
# Vercel deployment, so Cloudflare Access can intercept it. Pass --cname-target
# <vercel-dns-target> to have this script create that proxied CNAME for you.
#
# Emits (capture these into the console's Vercel env so middleware.js can verify):
#   CONSOLE-GATE-READY
#   CONSOLE_HOST=<host>
#   CF_ACCESS_AUTH_DOMAIN=<your-team>.cloudflareaccess.com
#   CF_ACCESS_AUD=<the Access app audience tag>
#
# Usage: ./cf_console_gate.sh [--dry-run] [--host <h>] [--cname-target <t>]
# Reads: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, AGENT_DOMAIN, OWNER_EMAIL
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0; HOST_OVERRIDE="${CONSOLE_HOST:-}"; CNAME_TARGET=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run)      DRY_RUN=1; shift;;
  --host)         HOST_OVERRIDE="$2"; shift 2;;
  --cname-target) CNAME_TARGET="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

require_env CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID AGENT_DOMAIN OWNER_EMAIL
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

TOK="$CLOUDFLARE_API_TOKEN"; ACC="$CLOUDFLARE_ACCOUNT_ID"
API="https://api.cloudflare.com/client/v4"
DOMAIN="$AGENT_DOMAIN"; EMAIL="$OWNER_EMAIL"
HOST="${HOST_OVERRIDE:-console.$DOMAIN}"
CURL="${CURL:-curl}"
cf() { "$CURL" -sS -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "$@"; }
ok() { echo "$1" | jq -e '.success' >/dev/null 2>&1; }
die() { echo "ERROR ($1): $(echo "$2" | jq -c '.errors' 2>/dev/null || echo "$2")" >&2; exit 1; }
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"

# Read the logged-in Vercel CLI token from its on-disk config (never printed). Falls back
# to VERCEL_API_TOKEN / VERCEL_TOKEN when set (the test harness uses this).
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

# Idempotent CNAME upsert at a given proxied state (true=orange, false=grey). Uses $ZONE.
upsert_cname() {
  local host="$1" target="$2" proxied="$3" rid R
  rid="$(cf "$API/zones/$ZONE/dns_records?name=$host" | jq -r '.result[0].id // empty')"
  if [ -n "$rid" ]; then
    R="$(cf -X PATCH "$API/zones/$ZONE/dns_records/$rid" \
      --data "{\"type\":\"CNAME\",\"name\":\"$host\",\"content\":\"$target\",\"proxied\":$proxied}")"
  else
    R="$(cf -X POST "$API/zones/$ZONE/dns_records" \
      --data "{\"type\":\"CNAME\",\"name\":\"$host\",\"content\":\"$target\",\"proxied\":$proxied}")"
  fi
  ok "$R" || die "dns.cname" "$R"
}

# Poll Vercel until it stops reporting the domain as "misconfigured" (origin cert issued).
# Best-effort: with no Vercel token we skip the poll and tell the operator how to confirm.
wait_vercel_cert() {
  local host="$1" tok cfg mis
  tok="$(vercel_cli_token || true)"
  if [ -z "$tok" ]; then
    echo "note: no Vercel CLI token found; skipping the cert-issued poll. If you see a Cloudflare" >&2
    echo "      525 after Access login, wait ~1 min for Vercel to issue the cert, then retry." >&2
    return 0
  fi
  for _ in $(seq 1 "${CERT_POLL_TRIES:-20}"); do
    cfg="$("$CURL" -sS -H "Authorization: Bearer $tok" "$VERCEL_API/v6/domains/$host/config" 2>/dev/null || true)"
    mis="$(printf '%s' "$cfg" | jq -r '.misconfigured // empty' 2>/dev/null || true)"
    [ "$mis" = "false" ] && return 0
    sleep "${CERT_POLL_SLEEP:-5}"
  done
  echo "note: Vercel still reports $host as misconfigured after polling; the cert may still be" >&2
  echo "      issuing. Re-run /doctor in a minute to confirm the console responds." >&2
  return 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN Cloudflare Access console gate for $HOST:"
  echo "1. GET  $API/accounts/$ACC/access/organizations   (discover team auth domain)"
  if [ -n "$CNAME_TARGET" ]; then
    echo "2. cert dance for $HOST (avoids a Cloudflare 525 after Access login):"
    echo "   a. upsert CNAME $HOST -> $CNAME_TARGET proxied=false (grey: let Vercel issue its TLS cert)"
    echo "   b. poll Vercel $VERCEL_API/v6/domains/$HOST/config until misconfigured=false (cert issued)"
    echo "   c. upsert CNAME $HOST -> $CNAME_TARGET proxied=true (orange: Cloudflare Access gates it)"
  else
    echo "2. (no --cname-target: point $HOST at Vercel yourself -- create it GREY first, wait for"
    echo "    the Vercel cert, THEN switch it to proxied/orange, or you will hit a Cloudflare 525)"
  fi
  echo "3. POST $API/accounts/$ACC/access/apps"
  echo "   body: self_hosted domain=$HOST  (captures the AUD)"
  echo "4. POST $API/accounts/$ACC/access/apps/<APPID>/policies"
  echo "   body: allow email=$EMAIL"
  echo "would emit: CONSOLE-GATE-READY + CONSOLE_HOST + CF_ACCESS_AUTH_DOMAIN + CF_ACCESS_AUD"
  exit 0
fi

# 0. Preflight: Access (Zero Trust) must be enabled, and we need the team auth domain.
ORG="$(cf "$API/accounts/$ACC/access/organizations" 2>/dev/null || true)"
if ! echo "$ORG" | jq -e '.success' >/dev/null 2>&1; then
  echo "Cloudflare Access (Zero Trust) is not enabled on this account." >&2
  echo "Enable it once at https://one.dash.cloudflare.com (team name + Free plan), then retry." >&2
  exit 1
fi
TEAM_DOMAIN="$(echo "$ORG" | jq -r '.result.auth_domain // empty')"
[ -n "$TEAM_DOMAIN" ] || { echo "could not read your Access team auth domain" >&2; exit 1; }

# 1. Optional: create the CNAME so Cloudflare fronts the console (Access can gate it). Do
#    the cert dance: a PROXIED (orange) Vercel origin hides the real origin, so Vercel can
#    never complete its TLS challenge -> no origin cert -> Cloudflare 525 after Access login.
#    Create the record GREY (proxied=false) first so Vercel issues the cert, poll Vercel
#    until the domain is no longer "misconfigured", THEN flip it ORANGE so Access intercepts.
#    Every step is idempotent (upsert + re-runnable poll), so a re-run is safe.
if [ -n "$CNAME_TARGET" ]; then
  ZONE="$(cf "$API/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')"
  [ -n "$ZONE" ] || { echo "zone $DOMAIN not found on Cloudflare" >&2; exit 1; }
  upsert_cname "$HOST" "$CNAME_TARGET" false   # grey: origin visible so Vercel can issue the cert
  wait_vercel_cert "$HOST"                      # poll until Vercel stops reporting misconfigured
  upsert_cname "$HOST" "$CNAME_TARGET" true     # orange: Cloudflare Access now fronts the console
  echo "CONSOLE-CERT-READY host=$HOST (grey -> Vercel cert -> orange)"
fi

# 2. Access application (self_hosted) for the console host. Capture the AUD tag.
R="$(cf -X POST "$API/accounts/$ACC/access/apps" \
  --data "{\"name\":\"Operator Console\",\"domain\":\"$HOST\",\"type\":\"self_hosted\",\"session_duration\":\"24h\"}")"
ok "$R" || die "access.app" "$R"
AUD="$(echo "$R" | jq -r '.result.aud')"
APPID="$(echo "$R" | jq -r '.result.id')"

# 3. Access policy: allow ONLY the operator's email (one-time PIN).
R="$(cf -X POST "$API/accounts/$ACC/access/apps/$APPID/policies" \
  --data "{\"name\":\"owner\",\"decision\":\"allow\",\"include\":[{\"email\":{\"email\":\"$EMAIL\"}}]}")"
ok "$R" || die "access.policy" "$R"

echo "CONSOLE-GATE-READY"
echo "CONSOLE_HOST=$HOST"
echo "CF_ACCESS_AUTH_DOMAIN=$TEAM_DOMAIN"
echo "CF_ACCESS_AUD=$AUD"
