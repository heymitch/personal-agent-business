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

# The receiver URL the operator console proxies to (set as MINT_RECEIVER_URL, with
# MINT_SECRET as the shared x-sim-secret). Expose the box receiver (port 8788)
# through your box's Cloudflare tunnel as receiver-<name>.<domain>; that gated host
# is the value to set. We emit it as RECEIVER-URL so /setup can capture it BEFORE the
# console is deployed (the console must never go live before its receiver exists).
RECEIVER_URL="${MINT_RECEIVER_URL:-}"
if [ -z "$RECEIVER_URL" ]; then
  if [ -n "${AGENT_NAME:-}" ] && [ -n "${AGENT_DOMAIN:-}" ]; then
    RECEIVER_URL="https://receiver-${AGENT_NAME}.${AGENT_DOMAIN}"
  else
    RECEIVER_URL="http://${IP}:8788"
  fi
fi

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

# State-preserving rsync exclude set. The deploy uses --delete, so anything the
# BOX writes at runtime must be excluded or a RE-DEPLOY onto a live box wipes it:
#   .env / .env.*              the operator's provision env (OPENAI_ADMIN_KEY,
#                              COMPOSIO_API_KEY, SIM_SECRET, MINT_SECRET). Losing
#                              it re-keys every client on the box.
#   receiver/session-store*    the userId -> sessionId bindings.
#   receiver/*.jsonl           the CLIENT REGISTRY + mint queue + activity/status
#                              logs (registry.jsonl, checkout-queue.jsonl,
#                              activity.jsonl, status.jsonl). Losing it wipes the
#                              operator's EXISTING clients.
#   node_modules / *.log       rebuildable / noise.
# None of these ship from the repo (all runtime-only), so excluding them never
# skips a real deploy artifact.
RSYNC_EXCLUDES=(
  --exclude 'node_modules'
  --exclude '.env'
  --exclude '.env.*'
  --exclude 'receiver/session-store*.json'
  --exclude 'receiver/*.jsonl'
  --exclude '*.log'
)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN deploy_engine -> root@${IP}"
  echo "1. rsync installer/ -> root@${IP}:${INSTALLER_ROOT} (then su - ${SERVICE_USER} -c 'npm ci')"
  echo "2. install receiver service (POST /refresh-session, GR1 instant path)"
  echo "3. install + enable reconcile-sessions.timer (GR1 backstop path, every 5 min)"
  echo "   rsync excludes (state-preserving, survive the --delete on a re-deploy): ${RSYNC_EXCLUDES[*]}"
  echo "4. restart receiver CLEAN: stop the old receiver + free port 8788, wait for release, THEN start the new one (exactly ONE receiver on the new code)"
  echo "--- rendered reconcile-sessions.service ---"
  echo "$SERVICE_RENDERED"
  echo "--- rendered reconcile-sessions.timer ---"
  echo "$TIMER_RENDERED"
  echo "RECEIVER-URL=${RECEIVER_URL}"
  exit 0
fi

# --- REAL deploy over SSH (same channel as configure_box / move_up) -------------
# 1. ship the engine and install deps as the hermes user.
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'mkdir -p ${INSTALLER_ROOT}'" >/dev/null
"$RSYNC" -az --delete \
  "${RSYNC_EXCLUDES[@]}" \
  -e "$SSH ${SSH_OPTS[*]}" \
  "$HERE/../installer/" "root@$IP:${INSTALLER_ROOT}/" >/dev/null
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALLER_ROOT}" >/dev/null
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'cd ${INSTALLER_ROOT} && npm ci --omit=dev || npm install'" >/dev/null

# 2. install the rendered systemd units and enable the timer (GR1 backstop).
printf '%s\n' "$SERVICE_RENDERED" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/reconcile-sessions.service"
printf '%s\n' "$TIMER_RENDERED" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/reconcile-sessions.timer"
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "systemctl daemon-reload && systemctl enable --now reconcile-sessions.timer" >/dev/null 2>&1 || true

# 3. restart the receiver CLEAN + idempotent (POST /refresh-session). A re-deploy
#    onto a LIVE box would otherwise leave the OLD receiver holding port 8788 while
#    the new code never serves (silent stale code). So STOP any existing receiver
#    and free 8788 FIRST, wait for it to release, THEN start the new one -> exactly
#    ONE receiver on the new code. The [r] bracket keeps pkill/pgrep from matching
#    this very command line (the plain string only lives in the start call below).
#    The receiver reads its OWN provision env file (GR4), not the agent's
#    ~/.hermes/.env, and no secret is printed.
STOP_RECEIVER="pkill -f \"[r]eceiver/server.ts\" 2>/dev/null || true; \
command -v fuser >/dev/null 2>&1 && fuser -k 8788/tcp 2>/dev/null || true; \
for _i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f \"[r]eceiver/server.ts\" >/dev/null 2>&1 || break; sleep 1; done"
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c '${STOP_RECEIVER}'" >/dev/null 2>&1 || true
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'cd ${INSTALLER_ROOT} && (nohup node_modules/.bin/tsx receiver/server.ts >/dev/null 2>&1 &)'" >/dev/null 2>&1 || true

echo "ENGINE-DEPLOYED ip=${IP}"
echo "RECEIVER-URL=${RECEIVER_URL}"
