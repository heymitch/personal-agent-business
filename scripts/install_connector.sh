#!/usr/bin/env bash
# Install the cloudflared connector on the box over SSH, using the tunnel token
# from cf_portal.sh. The token is passed as an arg and NEVER printed. Gates on
# `systemctl is-active cloudflared`.
# Usage: install_connector.sh <box_ip> <tunnel_token>
set -euo pipefail
IP="${1:-}"; TOKEN="${2:-}"
[ -n "$IP" ] && [ -n "$TOKEN" ] || { echo "usage: install_connector.sh <box_ip> <tunnel_token>" >&2; exit 2; }
SSH="${SSH:-ssh}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "${SSH_KEY:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi

# Install cloudflared from the official apt repo, then register the connector
# with the token. Run as one remote command so the token never lands in a file.
"$SSH" "${SSH_OPTS[@]}" "root@$IP" \
  "command -v cloudflared >/dev/null 2>&1 || (mkdir -p /usr/share/keyrings && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list && apt-get update && apt-get install -y cloudflared)" >/dev/null

"$SSH" "${SSH_OPTS[@]}" "root@$IP" "cloudflared service install $TOKEN" >/dev/null

state="$("$SSH" "${SSH_OPTS[@]}" "root@$IP" "systemctl is-active cloudflared" 2>/dev/null || true)"
if [ "$state" != "active" ]; then
  echo "ERROR: cloudflared connector did not come up active (state: $state)" >&2
  exit 1
fi
echo "CONNECTOR-OK"
