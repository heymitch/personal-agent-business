#!/usr/bin/env bash
# Stand up a Cloudflare Access login-link portal for the agent.
# De-tenanted from PAO cf_portal.sh: inputs from .env (no per-client args),
# adds --dry-run. The httpHostHeader:"localhost" rule is the 502 fix — keep it.
#
# Usage: ./cf_portal.sh [--dry-run] [--target http://localhost:9119]
# Reads: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, AGENT_DOMAIN,
#        OWNER_EMAIL, AGENT_NAME  (from .env or environment)
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0; TARGET="http://localhost:9119"; HOSTHEADER="localhost"
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY_RUN=1; shift;;
  --target)  TARGET="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

require_env CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID AGENT_DOMAIN OWNER_EMAIL AGENT_NAME
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

TOK="$CLOUDFLARE_API_TOKEN"; ACC="$CLOUDFLARE_ACCOUNT_ID"
API="https://api.cloudflare.com/client/v4"
NAME="$AGENT_NAME"; DOMAIN="$AGENT_DOMAIN"; EMAIL="$OWNER_EMAIL"; HOST="$NAME.$DOMAIN"
CURL="${CURL:-curl}"
cf() { "$CURL" -sS -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "$@"; }
ok() { echo "$1" | jq -e '.success' >/dev/null 2>&1; }
die() { echo "ERROR ($1): $(echo "$2" | jq -c '.errors' 2>/dev/null || echo "$2")" >&2; exit 1; }

# Pre-build the tunnel ingress config — httpHostHeader:"localhost" is the 502 fix.
# -c (compact) keeps the body on one line, matching grep assertions in tests.
TUNNEL_CFG="$(jq -cn \
  --arg h "$HOST" \
  --arg s "$TARGET" \
  --arg hh "$HOSTHEADER" \
  '{config:{ingress:[{hostname:$h,service:$s,originRequest:{httpHostHeader:$hh}},{service:"http_status:404"}]}}')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN Cloudflare portal call sequence for $HOST:"
  echo "1. GET  $API/zones?name=$DOMAIN"
  echo "2. POST $API/accounts/$ACC/cfd_tunnel"
  echo "   body: {\"name\":\"wingman-$NAME\",\"config_src\":\"cloudflare\"}"
  echo "3. PUT  $API/accounts/\$ACC/cfd_tunnel/<TID>/configurations"
  echo "   body: $TUNNEL_CFG"
  echo "   (note httpHostHeader=localhost — the 502 fix)"
  echo "4. POST $API/zones/<ZONE>/dns_records"
  echo "   body: CNAME $HOST -> <TID>.cfargotunnel.com proxied=true"
  echo "5. POST $API/accounts/$ACC/access/apps"
  echo "   body: self_hosted domain=$HOST"
  echo "6. POST $API/accounts/$ACC/access/apps/<APPID>/policies"
  echo "   body: allow email=$EMAIL"
  exit 0
fi

# State vars for rollback (Fix 4)
TID=""; DNS_ID=""; ZONE=""; completed=0

cleanup() {
  if [ "$completed" -eq 0 ]; then
    [ -n "$TID" ] && cf -X DELETE "$API/accounts/$ACC/cfd_tunnel/$TID" >/dev/null 2>&1 || true
    [ -n "$DNS_ID" ] && cf -X DELETE "$API/zones/$ZONE/dns_records/$DNS_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# 0. Preflight: verify Cloudflare Access (Zero Trust) is enabled (Fix 5)
preflight="$(cf "$API/accounts/$ACC/access/apps" 2>/dev/null || true)"
if ! echo "$preflight" | jq -e '.success' >/dev/null 2>&1; then
  echo "Cloudflare Access (Zero Trust) is not enabled on this account." >&2
  echo "Enable it once at https://one.dash.cloudflare.com (pick a team name + the Free plan), then retry." >&2
  echo "Underlying error: $(echo "$preflight" | jq -c '.errors // .error // .' 2>/dev/null || echo "$preflight")" >&2
  exit 1
fi

# 1. Discover zone ID from domain name (no manual input required)
ZONE="$(cf "$API/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')"
[ -n "$ZONE" ] || { echo "zone $DOMAIN not found / not on Cloudflare" >&2; exit 1; }

# 2. Create remotely-managed tunnel (config_src=cloudflare returns id + connector token)
R="$(cf -X POST "$API/accounts/$ACC/cfd_tunnel" \
  --data "{\"name\":\"wingman-$NAME\",\"config_src\":\"cloudflare\"}")"
ok "$R" || die "tunnel.create" "$R"
TID="$(echo "$R" | jq -r '.result.id')"
TTOKEN="$(echo "$R" | jq -r '.result.token')"

# 3. PUT ingress configuration: hostname -> localhost:9119, host header localhost (502 fix)
R="$(cf -X PUT "$API/accounts/$ACC/cfd_tunnel/$TID/configurations" --data "$TUNNEL_CFG")"
ok "$R" || die "tunnel.config" "$R"

# 4. Proxied CNAME DNS record pointing to the tunnel
R="$(cf -X POST "$API/zones/$ZONE/dns_records" \
  --data "{\"type\":\"CNAME\",\"name\":\"$HOST\",\"content\":\"$TID.cfargotunnel.com\",\"proxied\":true}")"
ok "$R" || die "dns.cname" "$R"
DNS_ID="$(echo "$R" | jq -r '.result.id')"

# 5. Access application (self_hosted)
R="$(cf -X POST "$API/accounts/$ACC/access/apps" \
  --data "{\"name\":\"Personal Agent $NAME\",\"domain\":\"$HOST\",\"type\":\"self_hosted\",\"session_duration\":\"24h\"}")"
ok "$R" || die "access.app" "$R"
APPID="$(echo "$R" | jq -r '.result.id')"

# 6. Access policy: allow the operator's email (one-time PIN)
R="$(cf -X POST "$API/accounts/$ACC/access/apps/$APPID/policies" \
  --data "{\"name\":\"owner\",\"decision\":\"allow\",\"include\":[{\"email\":{\"email\":\"$EMAIL\"}}]}")"
ok "$R" || die "access.policy" "$R"
completed=1

echo "PORTAL-READY"
echo "URL=https://$HOST"
echo "TUNNEL_ID=$TID"
echo "TUNNEL_TOKEN=$TTOKEN"
