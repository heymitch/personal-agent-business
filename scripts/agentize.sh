#!/usr/bin/env bash
# agentize: the operator's-skills pipeline. The operator builds their OWN skills
# on their OWN Hermes agent (whatever they want; there is NO fixed library). This
# script is the MECHANISM that ships those skills to the client agents they mint:
#
#   --scan-skills      discover the operator's built skill folders
#   --package-skills   tar each skill folder into a portable bundle (no transform)
#   --load-skills      rsync the bundles onto a client agent + restart its gateway
#
# Source is configurable: a LOCAL skills dir (--source / AGENTIZE_SKILLS_DIR) OR
# the operator's OWN box at /home/hermes/.hermes/skills over SSH (the DEFAULT,
# via AGENT_IP + SSH_KEY from .env). The box path is the same destination
# move_up.sh lifts the operator's local Hermes skills into.
#
# Success tokens (mutation-proven; the agent greps the EXACT string):
#   --scan-skills    -> SKILLS-SCANNED count=<n>
#   --package-skills -> SKILLS-PACKAGED count=<n>
#   --load-skills    -> SKILLS-LOADED count=<n>
#
# --dry-run on every stage: print the plan, touch nothing, spend nothing, and
# NEVER print a secret value (the SSH key path is referenced as a redacted flag).
#
# --defaults restricts any stage to DEFAULT_SKILLS (comma-separated capability ids
# in .env): the skills EVERY newly minted client agent ships with by default. Use it
# with --load-skills to ship exactly your defaults onto a freshly minted agent.
#
# Usage:
#   agentize.sh --scan-skills    [--source <dir>] [--defaults] [--dry-run]
#   agentize.sh --package-skills [--source <dir>] [--staging <dir>] [--defaults] [--dry-run]
#   agentize.sh --load-skills --target <client_ip_or_host> [--staging <dir>]
#                                [--source <dir>] [--defaults] [--dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

# The canonical Hermes skills directory on every box (operator's AND clients').
BOX_SKILLS_DIR="/home/hermes/.hermes/skills"

SSH="${SSH:-ssh}"
RSYNC="${RSYNC:-rsync}"
TAR="${TAR:-tar}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
# The SSH key is referenced as a flag; its PATH VALUE is never printed.
SSH_KEY_FLAG=""
if [ -n "${SSH_KEY:-}" ]; then SSH_OPTS+=(-i "$SSH_KEY"); SSH_KEY_FLAG="-i <SSH_KEY>"; fi

MODE=""
SOURCE=""
TARGET=""
STAGING="${AGENTIZE_STAGING_DIR:-$HERE/../.agentize-staging}"
DRY_RUN=0
DEFAULTS_ONLY=0

usage() {
  cat >&2 <<'EOF'
usage:
  agentize.sh --scan-skills    [--source <dir>] [--defaults] [--dry-run]
  agentize.sh --package-skills [--source <dir>] [--staging <dir>] [--defaults] [--dry-run]
  agentize.sh --load-skills --target <client_ip_or_host> [--staging <dir>] [--source <dir>] [--defaults] [--dry-run]

  --defaults  restrict to your DEFAULT_SKILLS (comma-separated capability ids in .env):
              the skills EVERY newly minted client agent ships with by default.
EOF
}

while [ $# -gt 0 ]; do case "$1" in
  --scan-skills)    MODE="scan"; shift;;
  --package-skills) MODE="package"; shift;;
  --load-skills)    MODE="load"; shift;;
  --source)         SOURCE="${2:-}"; shift 2;;
  --target)         TARGET="${2:-}"; shift 2;;
  --staging)        STAGING="${2:-}"; shift 2;;
  --defaults)       DEFAULTS_ONLY=1; shift;;
  --dry-run)        DRY_RUN=1; shift;;
  -h|--help)        usage; exit 0;;
  *) echo "unknown arg: $1" >&2; usage; exit 2;;
esac; done

[ -n "$MODE" ] || { echo "ERROR: pick one of --scan-skills / --package-skills / --load-skills" >&2; usage; exit 2; }

# scan_local <dir> : print each skill folder name (a dir holding a SKILL.md) on
# its own line; print nothing if the dir is empty/missing. Deterministic order.
scan_local() {
  local dir="$1" d
  [ -d "$dir" ] || return 0
  for d in "$dir"/*/; do
    [ -d "$d" ] || continue
    [ -f "${d}SKILL.md" ] || continue
    basename "$d"
  done | sort
}

# read_names_into <arrayname> <command...> : portable mapfile (bash 3.2 has no
# `mapfile`). Runs the command and appends each output line to the named array.
read_names_into() {
  local __arr="$1"; shift
  local __line
  eval "$__arr=()"
  while IFS= read -r __line; do
    [ -n "$__line" ] || continue
    eval "$__arr+=(\"\$__line\")"
  done < <("$@")
}

# discover_names : resolve the scan source and emit the skill names found.
#   - --source <dir>      -> scan that LOCAL dir
#   - default (no source) -> the operator's OWN box at BOX_SKILLS_DIR over SSH
discover_names() {
  if [ -n "$SOURCE" ]; then
    scan_local "$SOURCE"
  else
    local box="${AGENT_IP:-}"
    [ -n "$box" ] || { echo "ERROR: no --source and AGENT_IP is unset (cannot reach the operator box)" >&2; return 1; }
    # List the skill folders on the operator's own box over SSH. With the test
    # PATH-shim this is a no-op (zero dirs); in production it lists the real ones.
    "$SSH" "${SSH_OPTS[@]}" "root@$box" \
      "ls -1 '$BOX_SKILLS_DIR' 2>/dev/null" 2>/dev/null | sort || true
  fi
}

# filter_defaults : pass through only the skill names in DEFAULT_SKILLS (the operator's chosen
# mint-default subset, comma-separated capability ids in .env). Used when --defaults is set.
filter_defaults() {
  local allow line
  allow=" $(printf '%s' "${DEFAULT_SKILLS:-}" | tr ',' ' ') "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$allow" in *" $line "*) echo "$line";; esac
  done
}

# discover_names_filtered : discover, then (when --defaults) keep only DEFAULT_SKILLS.
discover_names_filtered() {
  if [ "$DEFAULTS_ONLY" -eq 1 ]; then
    discover_names | filter_defaults
  else
    discover_names
  fi
}

# Source descriptor for human-readable plan lines (no secret in it).
source_desc() {
  if [ -n "$SOURCE" ]; then printf 'local:%s' "$SOURCE"
  else printf 'box:root@%s:%s (ssh %s)' "${AGENT_IP:-UNSET}" "$BOX_SKILLS_DIR" "$SSH_KEY_FLAG"
  fi
}

case "$MODE" in
  scan)
    desc="$(source_desc)"
    echo "scan source: $desc"
    read_names_into NAMES discover_names_filtered
    n="${#NAMES[@]}"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "DRY-RUN scan: would enumerate skill folders under $desc"
    fi
    if [ "$n" -gt 0 ]; then
      for name in "${NAMES[@]}"; do echo "  skill: $name"; done
    fi
    echo "SKILLS-SCANNED count=$n"
    ;;

  package)
    desc="$(source_desc)"
    echo "package source: $desc -> staging: $STAGING"
    read_names_into NAMES discover_names_filtered
    n="${#NAMES[@]}"
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ "$n" -gt 0 ]; then
        for name in "${NAMES[@]}"; do
          echo "  would tar: ${SOURCE:-$BOX_SKILLS_DIR}/$name -> $STAGING/$name.tgz"
        done
      fi
      echo "SKILLS-PACKAGED count=$n"
      exit 0
    fi
    # Real packaging: tar each skill folder verbatim (no transform of contents).
    [ -n "$SOURCE" ] || { echo "ERROR: --package-skills needs a local --source (pull the box skills down first)" >&2; exit 2; }
    mkdir -p "$STAGING"
    if [ "$n" -gt 0 ]; then
      for name in "${NAMES[@]}"; do
        "$TAR" -czf "$STAGING/$name.tgz" -C "$SOURCE" "$name"
        echo "  packaged: $name -> $STAGING/$name.tgz"
      done
    fi
    echo "SKILLS-PACKAGED count=$n"
    ;;

  load)
    [ -n "$TARGET" ] || { echo "ERROR: --load-skills requires --target <client_ip_or_host>" >&2; usage; exit 2; }
    desc="$(source_desc)"
    read_names_into NAMES discover_names_filtered
    n="${#NAMES[@]}"
    echo "load source: $desc"
    echo "load target: root@$TARGET:$BOX_SKILLS_DIR (rsync $SSH_KEY_FLAG)"
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ "$n" -gt 0 ]; then
        for name in "${NAMES[@]}"; do
          echo "  would rsync: $STAGING/$name.tgz -> root@$TARGET:$BOX_SKILLS_DIR/"
        done
      fi
      echo "  would: ssh root@$TARGET 'su - hermes -c \"hermes gateway restart\"'"
      echo "SKILLS-LOADED count=$n"
      exit 0
    fi
    # Real load: ensure the client skills dir, rsync each bundle, unpack, restart.
    "$SSH" "${SSH_OPTS[@]}" "root@$TARGET" "su - hermes -c 'mkdir -p $BOX_SKILLS_DIR'" >/dev/null
    if [ "$n" -gt 0 ]; then
      for name in "${NAMES[@]}"; do
        "$RSYNC" -az -e "$SSH ${SSH_OPTS[*]}" "$STAGING/$name.tgz" "root@$TARGET:$BOX_SKILLS_DIR/" >/dev/null
        "$SSH" "${SSH_OPTS[@]}" "root@$TARGET" \
          "tar -xzf $BOX_SKILLS_DIR/$name.tgz -C $BOX_SKILLS_DIR && rm -f $BOX_SKILLS_DIR/$name.tgz" >/dev/null
        echo "  loaded: $name -> root@$TARGET:$BOX_SKILLS_DIR/$name"
      done
    fi
    "$SSH" "${SSH_OPTS[@]}" "root@$TARGET" "chown -R hermes:hermes $BOX_SKILLS_DIR" >/dev/null
    "$SSH" "${SSH_OPTS[@]}" "root@$TARGET" \
      "su - hermes -c 'export PATH=\$HOME/.local/bin:\$PATH; hermes gateway restart'" >/dev/null 2>&1 || true
    echo "SKILLS-LOADED count=$n"
    ;;
esac
