#!/usr/bin/env bash
# Upsert ONE key into the box's provision env file over the SAME SSH channel as
# deploy_engine.sh (root@<AGENT_IP>, -i <SSH_KEY>). The receiver on the box reads
# /home/hermes/personal-agent-engine/.env (its OWN provision env, GR4) for
# OPENAI_ADMIN_KEY / COMPOSIO_API_KEY / SIM_SECRET / MINT_SECRET. This lets an
# operator ADD or ROTATE one of those keys on a LIVE box WITHOUT a full re-deploy
# and WITHOUT disturbing any other line in that file.
#
# The VALUE is read from the LOCAL .env (via lib/env.sh) and travels to the box over
# SSH STDIN -- never on the command line, never printed. Upsert = replace-if-present,
# append-if-absent, so running twice is identical to running once (idempotent).
#
# Secrets never print. Success token (non-secret): BOX-ENV-SET key=<KEY_NAME>.
# --dry-run prints the plan (key name + target file), reads no value, fires no ssh.
#
# Usage: set_box_env.sh [--dry-run] <KEY_NAME>   (box IP comes from AGENT_IP in .env)
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0
KEY_NAME=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY_RUN=1; shift;;
  -*) echo "unknown arg: $1" >&2; exit 2;;
  *) [ -z "$KEY_NAME" ] || { echo "ERROR: only one <KEY_NAME> may be set per run" >&2; exit 2; }
     KEY_NAME="$1"; shift;;
esac; done

usage() { echo "usage: set_box_env.sh [--dry-run] <KEY_NAME>  (set AGENT_IP; reads VALUE from local .env)" >&2; }
[ -n "$KEY_NAME" ] || { echo "ERROR: <KEY_NAME> is required" >&2; usage; exit 2; }

# Box-side layout: mirror deploy_engine.sh so we target the SAME provision env file
# the receiver actually reads. BOX_ENV_FILE is overridable for tests only.
SERVICE_USER="hermes"
BOX_ENV_FILE="${BOX_ENV_FILE:-/home/${SERVICE_USER}/personal-agent-engine/.env}"

SSH="${SSH:-ssh}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "${SSH_KEY:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY"); fi

IP="${AGENT_IP:-}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN set_box_env"
  echo "key=${KEY_NAME}"
  echo "target=root@${IP:-<AGENT_IP unset>}:${BOX_ENV_FILE}"
  echo "plan: read VALUE for ${KEY_NAME} from local .env, send it over ssh STDIN, UPSERT" \
       "(replace-if-present, append-if-absent) into the box env; value never printed, no other line touched"
  exit 0
fi

# --- REAL upsert ---------------------------------------------------------------
[ -n "$IP" ] || { echo "ERROR: AGENT_IP is not set (provision the box first)" >&2; usage; exit 2; }

# The VALUE must be present + non-blank in the LOCAL env. require_env reports the
# missing key by NAME (never a value) and returns non-zero.
require_env "$KEY_NAME" || { echo "ERROR: set ${KEY_NAME} in your local .env before pushing it to the box" >&2; exit 2; }
VALUE="${!KEY_NAME}"

# Remote upsert, run as root (root can write ${SERVICE_USER}'s file; we chown it back
# so the receiver, which runs as ${SERVICE_USER}, can still read it). The VALUE arrives
# on STDIN ($(cat)); only the non-secret KEY_NAME + path travel in the command. Every
# remote-evaluated $ is escaped so it runs on the BOX, not locally. `grep -v` drops any
# existing KEY= line (replace), then we append exactly one (append) -> idempotent, and
# no other line in the file is disturbed.
REMOTE_UPSERT="f=\"${BOX_ENV_FILE}\"; key=\"${KEY_NAME}\"; val=\"\$(cat)\"; \
mkdir -p \"\$(dirname \"\$f\")\"; touch \"\$f\"; \
tmp=\"\$(mktemp)\"; \
grep -v \"^\${key}=\" \"\$f\" 2>/dev/null > \"\$tmp\" || true; \
printf '%s=%s\n' \"\$key\" \"\$val\" >> \"\$tmp\"; \
chmod 600 \"\$tmp\"; chown ${SERVICE_USER}:${SERVICE_USER} \"\$tmp\" 2>/dev/null || true; \
mv \"\$tmp\" \"\$f\""

# Value -> stdin only. Never an argument, never echoed.
printf '%s' "$VALUE" | "$SSH" "${SSH_OPTS[@]}" "root@$IP" "$REMOTE_UPSERT"

echo "BOX-ENV-SET key=${KEY_NAME}"
