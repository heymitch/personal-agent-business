#!/usr/bin/env bash
# Deploy the minting ENGINE (the receiver + the reconcile timer) onto the
# operator's OWN box over SSH. This is the operator standing up THEIR OWN rooster:
# ONE box hosts their personal agent AND their minting engine. No separate infra.
#
# Reuses the SAME SSH channel as configure_box.sh / move_up.sh: root@<ip>, then
# `su - hermes` for box-side work. The engine runs as the hermes service user.
#
# What it installs:
#   1. rsync installer/ -> ~/personal-agent-engine on the box (the vendored, de-tenanted
#      Composio session engine), then `npm ci` there.
#   2. render the systemd unit templates (substitute __INSTALLER_ROOT__,
#      __SERVICE_USER__, __PROVISION_ENV_FILE__) and install + enable
#      reconcile-sessions.{service,timer} (GR1 backstop path).
#   3. install + start the receiver service (POST /refresh-session, GR1 instant
#      path). The receiver reads its OWN provision env file (GR4), NOT the agent's
#      ~/.hermes/.env.
#
# Secrets never print. Success token (mutation-proven): ENGINE-DEPLOYED ip=<ip>.
# --dry-run prints the full SSH/render plan and the rendered units; touches nothing.
#
# Usage: deploy_engine.sh [--dry-run]   (box IP comes from AGENT_IP in .env)
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

IP="${AGENT_IP:-}"
[ -n "$IP" ] || { echo "usage: deploy_engine.sh [--dry-run]  (set AGENT_IP; provision the box first)" >&2; exit 2; }

# Box-side layout: the engine lives under the hermes user's home.
SERVICE_USER="hermes"
INSTALLER_ROOT="/home/${SERVICE_USER}/personal-agent-engine"
PROVISION_ENV_FILE="/home/${SERVICE_USER}/personal-agent-engine/.env"

SSH="${SSH:-ssh}"
RSYNC="${RSYNC:-rsync}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "${SSH_KEY:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi

# Render a unit template, substituting the box-side placeholders. ZERO rooster
# values: the substitutions are generic (hermes user + the box install path).
render_unit() {
  sed \
    -e "s|__INSTALLER_ROOT__|${INSTALLER_ROOT}|g" \
    -e "s|__SERVICE_USER__|${SERVICE_USER}|g" \
    -e "s|__PROVISION_ENV_FILE__|${PROVISION_ENV_FILE}|g" \
    "$1"
}

SERVICE_RENDERED="$(render_unit "$HERE/../installer/systemd/reconcile-sessions.service")"
TIMER_RENDERED="$(cat "$HERE/../installer/systemd/reconcile-sessions.timer")"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN deploy_engine -> root@${IP}"
  echo "1. rsync installer/ -> root@${IP}:${INSTALLER_ROOT} (then su - ${SERVICE_USER} -c 'npm ci')"
  echo "2. install receiver service (POST /refresh-session, GR1 instant path)"
  echo "3. install + enable reconcile-sessions.timer (GR1 backstop path, every 5 min)"
  echo "--- rendered reconcile-sessions.service ---"
  echo "$SERVICE_RENDERED"
  echo "--- rendered reconcile-sessions.timer ---"
  echo "$TIMER_RENDERED"
  exit 0
fi

# --- REAL deploy over SSH (same channel as configure_box / move_up) -------------
# 1. ship the engine and install deps as the hermes user.
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'mkdir -p ${INSTALLER_ROOT}'" >/dev/null
"$RSYNC" -az --delete \
  --exclude node_modules --exclude 'receiver/session-store*.json' --exclude '*.log' \
  -e "$SSH ${SSH_OPTS[*]}" \
  "$HERE/../installer/" "root@$IP:${INSTALLER_ROOT}/" >/dev/null
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALLER_ROOT}" >/dev/null
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'cd ${INSTALLER_ROOT} && npm ci --omit=dev || npm install'" >/dev/null

# 2. install the rendered systemd units and enable the timer (GR1 backstop).
printf '%s\n' "$SERVICE_RENDERED" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/reconcile-sessions.service"
printf '%s\n' "$TIMER_RENDERED" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/reconcile-sessions.timer"
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "systemctl daemon-reload && systemctl enable --now reconcile-sessions.timer" >/dev/null 2>&1 || true

# 3. start the receiver (POST /refresh-session). It reads its OWN provision env
#    file (GR4), not the agent's ~/.hermes/.env.
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'cd ${INSTALLER_ROOT} && (nohup node_modules/.bin/tsx receiver/server.ts >/dev/null 2>&1 &)'" >/dev/null 2>&1 || true

echo "ENGINE-DEPLOYED ip=${IP}"
