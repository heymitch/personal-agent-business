#!/usr/bin/env bash
# Daily Hermes self-update on the operator's OWN box: keeps the personal agent
# current. Box-side: installed by deploy_maintenance.sh and run by the
# hermes-update.timer.
#
# Optional fleet fan-out: with UPDATE_FLEET=1 it loops the non-retired agents in
# the mint registry and runs `hermes update` on each client box over SSH. This is
# a deliberately SIMPLE, OPTIONAL v1 hook (off by default); the registry is the
# append-only mint record the receiver writes.
#
# Secrets never print (the SSH key path is passed as a flag, never echoed).
# Success token (mutation-proven): HERMES-UPDATE-OK count=<n>  (n = own box + fleet).
set -euo pipefail

HERMES="${HERMES_BIN:-hermes}"
SSH="${SSH:-ssh}"
JQ="${JQ:-jq}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
[ -n "${SSH_KEY:-}" ] && SSH_OPTS+=(-i "$SSH_KEY")

count=0

# 1. Self-update the operator's own box. Try `update`, fall back to `self-update`.
if command -v "$HERMES" >/dev/null 2>&1; then
  "$HERMES" update >/dev/null 2>&1 || "$HERMES" self-update >/dev/null 2>&1 || true
fi
echo "self: hermes update (own box)"
count=$((count + 1))

# 2. OPTIONAL fleet fan-out: loop the non-retired agents in the mint registry and
#    update each client box. Off unless UPDATE_FLEET=1. The client host follows the
#    cf_ssh naming convention: ssh-<slug>.<AGENT_DOMAIN>.
if [ "${UPDATE_FLEET:-0}" = "1" ]; then
  REGISTRY="${REGISTRY_FILE:-}"
  DOMAIN="${AGENT_DOMAIN:-}"
  if [ -n "$REGISTRY" ] && [ -f "$REGISTRY" ] && command -v "$JQ" >/dev/null 2>&1; then
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      host="ssh-${slug}.${DOMAIN}"
      "$SSH" "${SSH_OPTS[@]}" "root@${host}" \
        "su - hermes -c 'export PATH=\$HOME/.local/bin:\$PATH; hermes update'" \
        >/dev/null 2>&1 || true
      echo "fleet: hermes update -> ${host}"
      count=$((count + 1))
    done < <("$JQ" -r 'select(.retired != true) | .slug' "$REGISTRY" 2>/dev/null | awk 'NF' | sort -u)
  fi
fi

echo "HERMES-UPDATE-OK count=${count}"
