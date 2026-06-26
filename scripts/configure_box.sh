#!/usr/bin/env bash
# Configure the box AFTER boot, over SSH: brain (openai-api + base_url) and
# Slack tokens + allowlist, then restart the gateway. App connections (Composio)
# are wired AFTER provisioning by saying "connect <app> to my cloud agent", which
# runs the Hermes MCP installer on the box -- not pre-wired here.
# Secrets ride the encrypted SSH channel; none is printed locally.
# Usage: configure_box.sh <box_ip>
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

IP="${1:-}"
[ -n "$IP" ] || { echo "usage: configure_box.sh <box_ip>" >&2; exit 2; }

require_env OPENAI_BASE_URL BRAIN_MODEL \
  SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS

SSH="${SSH:-ssh}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "${SSH_KEY:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi

# --- 1. brain: provider openai-api + EXPLICIT base_url (admin key can't infer) ---
# Only runs when OPENAI_API_KEY is set. On the own-agent path the buyer may
# skip the key here and instead connect a model by OAuth in the dashboard
# after the box is up (Providers -> connect), exactly like Session 1.
# hermes config set writes config.yaml; the base_url is the footgun fix.
if [ -n "${OPENAI_API_KEY:-}" ]; then
  # shellcheck disable=SC2029
  "$SSH" "${SSH_OPTS[@]}" "root@$IP" \
    "su - hermes -c 'hermes config set model.provider openai-api \
&& hermes config set model.default \"$BRAIN_MODEL\" \
&& hermes config set model.base_url \"$OPENAI_BASE_URL\" \
&& (grep -q \"^OPENAI_API_KEY=\" ~/.hermes/.env \
    || printf \"OPENAI_API_KEY=%s\n\" \"$OPENAI_API_KEY\" >> ~/.hermes/.env)'" \
    >/dev/null
else
  echo "[configure_box] OPENAI_API_KEY not set -- skipping brain config." \
    "Connect a model via the dashboard (Providers -> connect) after provisioning." >&2
fi

# --- 2. Slack: bot + app tokens + owner allowlist --------------------------------
# shellcheck disable=SC2029
"$SSH" "${SSH_OPTS[@]}" "root@$IP" \
  "su - hermes -c 'ENV=\$HOME/.hermes/.env
touch \$ENV
for kv in \"SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN\" \
           \"SLACK_APP_TOKEN=$SLACK_APP_TOKEN\" \
           \"SLACK_ALLOWED_USERS=$SLACK_ALLOWED_USERS\"; do
  k=\${kv%%=*}
  grep -q \"^\$k=\" \$ENV \
    && sed -i \"s|^\$k=.*|\$kv|\" \$ENV \
    || echo \"\$kv\" >> \$ENV
done'" \
  >/dev/null

# --- 3. restart gateway so new .env keys + config load --------------------------
# shellcheck disable=SC2029
"$SSH" "${SSH_OPTS[@]}" "root@$IP" \
  "su - hermes -c 'export PATH=\$HOME/.local/bin:\$PATH; hermes gateway restart'" \
  >/dev/null 2>&1 || true

echo "CONFIGURE-OK"
