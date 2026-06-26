#!/usr/bin/env bash
# Install the two DAILY maintenance timers on the operator's OWN box over SSH (the
# SAME channel deploy_engine.sh / configure_box.sh use: root@<ip>):
#   hermes-update.timer  -> daily `hermes update` (keep the personal agent current)
#   git-backup.timer     -> daily commit+push of agency state to the backup remote
#
# It ships the two box-side scripts (installer/scripts/{hermes-update,git-backup}.sh)
# next to the engine, renders the unit templates (substituting the box-side paths),
# installs them, and enables both timers. Secrets never print: BACKUP_GIT_REMOTE is
# read by the box from its OWN provision env file at run time, never baked into a
# unit and never echoed here.
#
# Success token (mutation-proven): MAINTENANCE-DEPLOYED ip=<ip>.
# --dry-run prints the full SSH/render plan and the rendered units; touches nothing.
#
# Usage: deploy_maintenance.sh [--dry-run]   (box IP comes from AGENT_IP in .env)
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
[ -n "$IP" ] || { echo "usage: deploy_maintenance.sh [--dry-run]  (set AGENT_IP; provision the box first)" >&2; exit 2; }

# Box-side layout: maintenance lives next to the engine under the hermes user.
SERVICE_USER="hermes"
INSTALLER_ROOT="/home/${SERVICE_USER}/personal-agent-engine"
PROVISION_ENV_FILE="${INSTALLER_ROOT}/.env"
# The agency-state working dir to back up (config / mint registry / skills). The
# git-backup.sh ignore list keeps node_modules, .env and key material OUT of it.
BACKUP_DIR="${INSTALLER_ROOT}"

SSH="${SSH:-ssh}"
RSYNC="${RSYNC:-rsync}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "${SSH_KEY:-}" ] && SSH_OPTS+=(-i "$SSH_KEY")

# Render a unit template, substituting the box-side placeholders. ZERO rooster
# values and ZERO secrets: every substitution is a generic path or the hermes user.
render_unit() {
  sed \
    -e "s|__INSTALLER_ROOT__|${INSTALLER_ROOT}|g" \
    -e "s|__SERVICE_USER__|${SERVICE_USER}|g" \
    -e "s|__PROVISION_ENV_FILE__|${PROVISION_ENV_FILE}|g" \
    -e "s|__BACKUP_DIR__|${BACKUP_DIR}|g" \
    "$1"
}

UNITS_DIR="$HERE/../installer/systemd"
HU_SERVICE="$(render_unit "$UNITS_DIR/hermes-update.service")"
HU_TIMER="$(cat "$UNITS_DIR/hermes-update.timer")"
GB_SERVICE="$(render_unit "$UNITS_DIR/git-backup.service")"
GB_TIMER="$(cat "$UNITS_DIR/git-backup.timer")"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN deploy_maintenance -> root@${IP}"
  echo "1. rsync installer/scripts/{hermes-update,git-backup}.sh -> root@${IP}:${INSTALLER_ROOT}/scripts/"
  echo "2. install + enable hermes-update.timer (daily hermes update)"
  echo "3. install + enable git-backup.timer (daily agency-state push; remote read from box env)"
  echo "--- rendered hermes-update.service ---"; echo "$HU_SERVICE"
  echo "--- rendered hermes-update.timer ---";   echo "$HU_TIMER"
  echo "--- rendered git-backup.service ---";     echo "$GB_SERVICE"
  echo "--- rendered git-backup.timer ---";       echo "$GB_TIMER"
  echo "(dry-run only: nothing installed; BACKUP_GIT_REMOTE never printed)"
  exit 0
fi

# --- REAL install over SSH (same channel as deploy_engine) ----------------------
# 1. ship the two box-side scripts next to the engine, executable, hermes-owned.
"$SSH" "${SSH_OPTS[@]}" "root@$IP" "su - ${SERVICE_USER} -c 'mkdir -p ${INSTALLER_ROOT}/scripts'" >/dev/null
"$RSYNC" -az -e "$SSH ${SSH_OPTS[*]}" \
  "$HERE/../installer/scripts/hermes-update.sh" "$HERE/../installer/scripts/git-backup.sh" \
  "root@$IP:${INSTALLER_ROOT}/scripts/" >/dev/null
"$SSH" "${SSH_OPTS[@]}" "root@$IP" \
  "chmod +x ${INSTALLER_ROOT}/scripts/hermes-update.sh ${INSTALLER_ROOT}/scripts/git-backup.sh; chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALLER_ROOT}/scripts" >/dev/null

# 2. install the rendered units and enable BOTH daily timers.
printf '%s\n' "$HU_SERVICE" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/hermes-update.service"
printf '%s\n' "$HU_TIMER"   | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/hermes-update.timer"
printf '%s\n' "$GB_SERVICE" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/git-backup.service"
printf '%s\n' "$GB_TIMER"   | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "cat > /etc/systemd/system/git-backup.timer"
"$SSH" "${SSH_OPTS[@]}" "root@$IP" \
  "systemctl daemon-reload && systemctl enable --now hermes-update.timer git-backup.timer" >/dev/null 2>&1 || true

echo "MAINTENANCE-DEPLOYED ip=${IP}"
