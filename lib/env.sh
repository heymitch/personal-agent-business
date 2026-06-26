#!/usr/bin/env bash
# Config lib: load + validate .env. Never echoes a secret value.
# Ported from the proven Session 3 cockpit.
# shellcheck disable=SC1090

load_env() {
  # Meant to be sourced; .env must be KEY=VALUE lines (it is eval'd as bash).
  local f="${1:-${COCKPIT_ENV_FILE:-$PWD/.env}}"
  if [ ! -f "$f" ]; then
    echo "ERROR: env file not found: $f (copy .env.example to .env)" >&2
    return 1
  fi
  set -a
  . "$f"
  set +a
}

# Print a redacted descriptor for a value: never the value itself.
redact() {
  local v="$1"
  if [ -z "$v" ]; then echo "MISSING"; else echo "set (${#v} chars)"; fi
}

# Exit 1 listing every missing/blank key. Values are never printed.
require_env() {
  local missing=() k val
  for k in "$@"; do
    val="${!k:-}"
    val="${val//[[:space:]]/}"
    if [ -z "$val" ]; then missing+=("$k"); fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing required keys in .env: ${missing[*]}" >&2
    return 1
  fi
  return 0
}
