#!/usr/bin/env bash
# Lift the local Hermes Desktop persona up to the cloud box: copy SOUL + skills
# + memory into the box's ~/.hermes, then restart the gateway. The JUDGMENT of
# WHAT to lift lives in .claude/commands/move-up.md; this does the mechanical copy.
# Usage: move_up.sh <box_ip>
set -euo pipefail

IP="${1:-}"; [ -n "$IP" ] || { echo "usage: move_up.sh <box_ip>" >&2; exit 2; }
LH="${LOCAL_HERMES_HOME:-$HOME/.hermes}"
SCP="${SCP:-scp}"; SSH="${SSH:-ssh}"
OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [ -n "${SSH_KEY:-}" ]; then OPTS+=(-i "$SSH_KEY"); fi

# Collect the persona artifacts that actually exist locally.
items=()
for p in "SOUL.md" "AGENTS.md" "memory.md" "memory" "skills"; do
  [ -e "$LH/$p" ] && items+=("$LH/$p")
done
[ ${#items[@]} -gt 0 ] || { echo "ERROR: nothing to move (no SOUL/skills/memory in $LH)" >&2; exit 1; }

"$SSH" "${OPTS[@]}" "root@$IP" "su - hermes -c 'mkdir -p ~/.hermes'" >/dev/null
"$SCP" "${OPTS[@]}" -r "${items[@]}" "root@$IP:/home/hermes/.hermes/" >/dev/null
"$SSH" "${OPTS[@]}" "root@$IP" "chown -R hermes:hermes /home/hermes/.hermes" >/dev/null
"$SSH" "${OPTS[@]}" "root@$IP" "su - hermes -c 'export PATH=\$HOME/.local/bin:\$PATH; hermes gateway restart'" >/dev/null 2>&1 || true

echo "MOVE-UP-OK (lifted: ${items[*]##*/})"
