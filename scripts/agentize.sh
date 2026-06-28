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
# AGENT PROFILES restrict any stage to one named build the operator defined. A profile
# is a NAME + a set of the operator's own skill ids, stored in config/agent-profiles.json
# (gitignored; config/agent-profiles.example.json is the neutral template). Two flags:
#   --profile <name>  restrict to exactly that profile's skill set.
#   --defaults        restrict to the defaultProfile's skill set (the mint floor).
# Use either with --load-skills to ship exactly that build onto a freshly minted agent.
#
# Usage:
#   agentize.sh --scan-skills    [--source <dir>] [--profile <name>|--defaults] [--dry-run]
#   agentize.sh --package-skills [--source <dir>] [--staging <dir>] [--profile <name>|--defaults] [--dry-run]
#   agentize.sh --load-skills --target <client_ip_or_host> [--staging <dir>]
#                                [--source <dir>] [--profile <name>|--defaults] [--dry-run]
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
PROFILE=""
# Operator's agent profiles (named builds). Overridable for tests via AGENT_PROFILES_FILE.
PROFILES_FILE="${AGENT_PROFILES_FILE:-$HERE/../config/agent-profiles.json}"

usage() {
  cat >&2 <<'EOF'
usage:
  agentize.sh --scan-skills    [--source <dir>] [--profile <name>|--defaults] [--dry-run]
  agentize.sh --package-skills [--source <dir>] [--staging <dir>] [--profile <name>|--defaults] [--dry-run]
  agentize.sh --load-skills --target <client_ip_or_host> [--staging <dir>] [--source <dir>] [--profile <name>|--defaults] [--dry-run]

  --profile <name>  restrict to that named agent profile's skill set (config/agent-profiles.json).
  --defaults        restrict to the defaultProfile's skill set (the mint floor every new agent gets).
EOF
}

while [ $# -gt 0 ]; do case "$1" in
  --scan-skills)    MODE="scan"; shift;;
  --package-skills) MODE="package"; shift;;
  --load-skills)    MODE="load"; shift;;
  --source)         SOURCE="${2:-}"; shift 2;;
  --target)         TARGET="${2:-}"; shift 2;;
  --staging)        STAGING="${2:-}"; shift 2;;
  --profile)        PROFILE="${2:-}"; shift 2;;
  --defaults)       DEFAULTS_ONLY=1; shift;;
  --dry-run)        DRY_RUN=1; shift;;
  -h|--help)        usage; exit 0;;
  *) echo "unknown arg: $1" >&2; usage; exit 2;;
esac; done

[ -n "$MODE" ] || { echo "ERROR: pick one of --scan-skills / --package-skills / --load-skills" >&2; usage; exit 2; }
[ -n "$PROFILE" ] && [ "$DEFAULTS_ONLY" -eq 1 ] && { echo "ERROR: pass --profile <name> OR --defaults, not both" >&2; usage; exit 2; }

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

# resolve_profile_name : the profile to restrict to. With --profile <name> it is that name; with
# --defaults it is the config's defaultProfile (falling back to the first profile). Empty otherwise.
resolve_profile_name() {
  if [ -n "$PROFILE" ]; then
    printf '%s' "$PROFILE"
    return 0
  fi
  if [ "$DEFAULTS_ONLY" -eq 1 ]; then
    [ -f "$PROFILES_FILE" ] || return 0
    local name
    name="$(jq -r '.defaultProfile // empty' "$PROFILES_FILE" 2>/dev/null || true)"
    [ -n "$name" ] || name="$(jq -r '.profiles[0].name // empty' "$PROFILES_FILE" 2>/dev/null || true)"
    printf '%s' "$name"
  fi
}

# profile_skill_ids <name> : the skill ids of the named profile (one per line) from the profiles
# config. Empty if no name, no config file, or the profile is unknown.
profile_skill_ids() {
  local name="$1"
  [ -n "$name" ] || return 0
  [ -f "$PROFILES_FILE" ] || return 0
  jq -r --arg n "$name" '.profiles[] | select(.name==$n) | .skills[]?' "$PROFILES_FILE" 2>/dev/null || true
}

# filter_to_profile : pass through only the skill names in the active profile's skill set.
filter_to_profile() {
  local allow line
  allow=" $(profile_skill_ids "$(resolve_profile_name)" | tr '\n' ' ') "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$allow" in *" $line "*) echo "$line";; esac
  done
}

# discover_names_filtered : discover, then (when --profile/--defaults) keep only that profile's set.
discover_names_filtered() {
  if [ -n "$PROFILE" ] || [ "$DEFAULTS_ONLY" -eq 1 ]; then
    discover_names | filter_to_profile
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

# profile_plan_note : when restricting to a profile, name it for the operator (no token, no secret).
profile_plan_note() {
  local name
  name="$(resolve_profile_name)"
  if [ -n "$PROFILE" ]; then
    echo "profile: $name"
  elif [ "$DEFAULTS_ONLY" -eq 1 ]; then
    echo "profile: ${name:-<none>} (defaultProfile)"
  fi
}

case "$MODE" in
  scan)
    desc="$(source_desc)"
    echo "scan source: $desc"
    profile_plan_note
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
    profile_plan_note
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
    profile_plan_note
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
