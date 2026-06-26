#!/usr/bin/env bash
# /doctor backing script: a READ-ONLY health check across the whole setup. It
# probes each component, prints a PASS/FAIL line per check (never a secret value),
# and emits a single verdict the agent greps for:
#   all green  -> DOCTOR-OK
#   any broken -> DOCTOR-FAIL component=<name> [component=<name> ...]
# It mutates nothing, so it is safe to re-run any number of times (idempotent).
#
# Checks:
#   keys      required operator keys present (reported via redact: "set (N chars)")
#   box       the operator's own box reachable over SSH (AGENT_IP)
#   engine    the receiver + the timers active on the box
#   surfaces  the deployed Vercel surface URL(s) respond
# shellcheck source-path=SCRIPTDIR/..
set -uo pipefail   # NOT -e: a failing probe is a reported FAIL, not a crash
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

CURL="${CURL:-curl}"
SSH="${SSH:-ssh}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
[ -n "${SSH_KEY:-}" ] && SSH_OPTS+=(-i "$SSH_KEY")

FAILS=()
pass() { echo "[PASS] $1: $2"; }
fail() { echo "[FAIL] $1: $2"; FAILS+=("$1"); }

# --- keys: required operator keys present (values never printed) -----------------
REQUIRED=(HETZNER_TOKEN OPENAI_BASE_URL BRAIN_MODEL AGENTMAIL_API_KEY AGENTMAIL_INBOX \
          COMPOSIO_API_KEY CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID AGENT_DOMAIN \
          OWNER_EMAIL VERCEL_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USERS)
if require_env "${REQUIRED[@]}" 2>/dev/null; then
  pass keys "all ${#REQUIRED[@]} operator keys present (values never printed)"
else
  missing=()
  for k in "${REQUIRED[@]}"; do
    v="${!k:-}"; v="${v//[[:space:]]/}"
    [ -n "$v" ] || missing+=("$k")
  done
  fail keys "missing: ${missing[*]}"
fi

# --- box: the operator's own box reachable over SSH ------------------------------
IP="${AGENT_IP:-}"
if [ -z "$IP" ]; then
  fail box "AGENT_IP unset (provision your own agent first)"
elif "$SSH" "${SSH_OPTS[@]}" "root@$IP" true >/dev/null 2>&1; then
  pass box "reachable over SSH (root@${IP})"
else
  fail box "not reachable over SSH (root@${IP})"
fi

# --- engine: the receiver + the maintenance/reconcile timers active --------------
if [ -z "$IP" ]; then
  fail engine "no box to check (AGENT_IP unset)"
elif "$SSH" "${SSH_OPTS[@]}" "root@$IP" \
       "systemctl is-active reconcile-sessions.timer hermes-update.timer git-backup.timer && pgrep -f 'receiver/server' >/dev/null" \
       >/dev/null 2>&1; then
  pass engine "receiver up + reconcile/hermes-update/git-backup timers active"
else
  fail engine "receiver or a timer is not active on root@${IP}"
fi

# --- surfaces: the deployed Vercel surface URL(s) respond ------------------------
surface_ok=1
checked=0
for var in ONBOARDER_BASE_URL LANDING_URL CONSOLE_URL; do
  url="${!var:-}"
  [ -n "$url" ] || continue
  checked=$((checked + 1))
  "$CURL" -fsS -o /dev/null --max-time 10 "$url" >/dev/null 2>&1 || surface_ok=0
done
if [ "$checked" -eq 0 ]; then
  fail surfaces "no surface URL set (deploy your surfaces first)"
elif [ "$surface_ok" -eq 1 ]; then
  pass surfaces "all ${checked} deployed surface URL(s) responded"
else
  fail surfaces "a deployed surface URL did not respond"
fi

# --- verdict ---------------------------------------------------------------------
if [ "${#FAILS[@]}" -eq 0 ]; then
  echo "DOCTOR-OK"
  exit 0
fi
printf 'DOCTOR-FAIL'
for c in "${FAILS[@]}"; do printf ' component=%s' "$c"; done
printf '\n'
exit 1
