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

# Decode a cloudflared connector token (base64 of {"a","t","s"}) to its tunnel id (.t).
# A token-managed cloudflared tunnel is best targeted by ID: matching by a guessed name
# can miss the real tunnel (its name may be capitalised, e.g. "Goose..."). Prints the id
# (case preserved) and returns 0, or prints nothing and returns 1.
tunnel_id_from_token() {
  local tok="${1:-}" json id
  [ -n "$tok" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Try GNU (-d) then BSD (-D) decode; the value is base64 of a small JSON object.
  json="$(printf '%s' "$tok" | base64 -d 2>/dev/null || true)"
  [ -n "$json" ] || json="$(printf '%s' "$tok" | base64 -D 2>/dev/null || true)"
  [ -n "$json" ] || return 1
  id="$(printf '%s' "$json" | jq -r '.t // empty' 2>/dev/null || true)"
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}
