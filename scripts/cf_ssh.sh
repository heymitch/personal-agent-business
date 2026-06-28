#!/usr/bin/env bash
# Add a Tailscale-free SSH path to the box's existing Cloudflare tunnel:
# ssh://localhost:22 ingress + ssh-<name>.<domain> CNAME. Reach the box with:
#   ssh -o ProxyCommand="cloudflared access ssh --hostname %h" root@ssh-<name>.<domain>
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY_RUN=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

require_env CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID AGENT_DOMAIN AGENT_NAME
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

TOK="$CLOUDFLARE_API_TOKEN"; ACC="$CLOUDFLARE_ACCOUNT_ID"; API="https://api.cloudflare.com/client/v4"
NAME="$AGENT_NAME"; DOMAIN="$AGENT_DOMAIN"; SSHHOST="ssh-$NAME.$DOMAIN"
CURL="${CURL:-curl}"
cf(){ "$CURL" -sS -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" "$@"; }
ok(){ echo "$1" | jq -e '.success' >/dev/null 2>&1; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN cf_ssh for $SSHHOST:"
  echo "1. find tunnel agent-$NAME"
  echo "2. add ingress {hostname:$SSHHOST, service:ssh://localhost:22} before the 404 catchall"
  echo "3. CNAME $SSHHOST -> <TID>.cfargotunnel.com proxied"
  exit 0
fi

# Target the tunnel by ID. A guessed lowercase name can miss the real tunnel (its name
# may be capitalised, e.g. "Goose..."), so prefer the tunnel id decoded from the box's
# cloudflared connector token; fall back to a CASE-INSENSITIVE name match.
TID=""
TOKEN_SRC="${CLOUDFLARED_TOKEN:-${TUNNEL_TOKEN:-}}"
[ -n "$TOKEN_SRC" ] && TID="$(tunnel_id_from_token "$TOKEN_SRC" || true)"
if [ -z "$TID" ]; then
  TID="$(cf "$API/accounts/$ACC/cfd_tunnel?is_deleted=false&per_page=200" \
    | jq -r --arg n "agent-$NAME" '.result[] | select((.name|ascii_downcase)==($n|ascii_downcase)) | .id' | head -1)"
fi
[ -n "$TID" ] || { echo "no tunnel for agent-$NAME found (set CLOUDFLARED_TOKEN/TUNNEL_TOKEN from the box, or run cf_portal.sh first)" >&2; exit 1; }

# Preserve every existing ingress route; only dedupe THIS ssh hostname (case-insensitively,
# since DNS hostnames are case-insensitive) before re-appending it and the 404 catchall.
CUR="$(cf "$API/accounts/$ACC/cfd_tunnel/$TID/configurations" | jq ".result.config.ingress // []")"
NEW="$(echo "$CUR" | jq --arg h "$SSHHOST" \
  'map(select((.hostname // "" | ascii_downcase) != ($h|ascii_downcase))) | (map(select(.service!="http_status:404"))) + [{hostname:$h, service:"ssh://localhost:22"}] + [{service:"http_status:404"}]')"
R="$(cf -X PUT "$API/accounts/$ACC/cfd_tunnel/$TID/configurations" --data "$(jq -n --argjson ing "$NEW" '{config:{ingress:$ing}}')")"
ok "$R" || { echo "ingress update failed: $(echo "$R"|jq -c .errors)" >&2; exit 1; }

ZONE="$(cf "$API/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')"
[ -n "$ZONE" ] || { echo "zone $DOMAIN not found" >&2; exit 1; }
if [ -z "$(cf "$API/zones/$ZONE/dns_records?name=$SSHHOST" | jq -r '.result[0].id // empty')" ]; then
  R="$(cf -X POST "$API/zones/$ZONE/dns_records" --data "{\"type\":\"CNAME\",\"name\":\"$SSHHOST\",\"content\":\"$TID.cfargotunnel.com\",\"proxied\":true}")"
  ok "$R" || { echo "dns failed: $(echo "$R"|jq -c .errors)" >&2; exit 1; }
fi

echo "SSH-READY  host=$SSHHOST  tunnel=$TID"
echo "Reach it:  ssh -o ProxyCommand=\"cloudflared access ssh --hostname %h\" root@$SSHHOST"
