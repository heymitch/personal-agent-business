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

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN Cloudflare Access console gate for $HOST:"
  echo "1. GET  $API/accounts/$ACC/access/organizations   (discover team auth domain)"
  if [ -n "$CNAME_TARGET" ]; then
    echo "2. POST $API/zones/<ZONE>/dns_records"
    echo "   body: CNAME $HOST -> $CNAME_TARGET proxied=true"
  else
    echo "2. (no --cname-target: you point $HOST at Vercel as a proxied record yourself)"
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

# 1. Optional: create the proxied CNAME so Cloudflare fronts the console (Access can gate it).
if [ -n "$CNAME_TARGET" ]; then
  ZONE="$(cf "$API/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')"
  [ -n "$ZONE" ] || { echo "zone $DOMAIN not found on Cloudflare" >&2; exit 1; }
  R="$(cf -X POST "$API/zones/$ZONE/dns_records" \
    --data "{\"type\":\"CNAME\",\"name\":\"$HOST\",\"content\":\"$CNAME_TARGET\",\"proxied\":true}")"
  ok "$R" || die "dns.cname" "$R"
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
