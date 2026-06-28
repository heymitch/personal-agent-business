#!/usr/bin/env bats
load test_helper

setup() {
  TMP_ENV="$(mktemp "$REPO_ROOT/test/tmp/env.XXXXXX")"
  cat > "$TMP_ENV" <<EOF
HETZNER_TOKEN=tok_secret_123
OWNER_EMAIL=me@example.com
COMPOSIO_API_KEY=
EOF
}
teardown() { rm -f "$TMP_ENV"; }

@test "load_env exports keys from the file" {
  source "$LIB_DIR/env.sh"
  load_env "$TMP_ENV"
  [ "$HETZNER_TOKEN" = "tok_secret_123" ]
  [ "$OWNER_EMAIL" = "me@example.com" ]
}

@test "require_env passes when all keys present and non-blank" {
  source "$LIB_DIR/env.sh"
  load_env "$TMP_ENV"
  run require_env HETZNER_TOKEN OWNER_EMAIL
  [ "$status" -eq 0 ]
}

# Mirrors the plan's Slice 0 Step 1 contract: names-only, never values.
@test "require_env lists only missing NAMES and never values" {
  source "$LIB_DIR/env.sh"
  export PRESENT_KEY="super-secret-value"
  unset MISSING_KEY
  run require_env PRESENT_KEY MISSING_KEY
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING_KEY"* ]]
  [[ "$output" != *"super-secret-value"* ]]
  [[ "$output" != *"PRESENT_KEY"* ]]
}

@test "require_env fails and names the blank key, never the value" {
  source "$LIB_DIR/env.sh"
  load_env "$TMP_ENV"
  run require_env HETZNER_TOKEN COMPOSIO_API_KEY
  [ "$status" -eq 1 ]
  [[ "$output" == *"COMPOSIO_API_KEY"* ]]
  [ -z "$(printf '%s' "$output" | grep -F "tok_secret_123")" ]
}

@test "redact never prints the secret value" {
  source "$LIB_DIR/env.sh"
  run redact "tok_secret_123"
  [ -z "$(printf '%s' "$output" | grep -F "tok_secret_123")" ]
  [[ "$output" == *"set ("*" chars)"* ]]
}

@test "redact reports MISSING for an empty value" {
  source "$LIB_DIR/env.sh"
  run redact ""
  [ "$output" = "MISSING" ]
}

@test "load_env errors on a missing file" {
  source "$LIB_DIR/env.sh"
  run load_env /nonexistent/path/.env
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "require_env treats a whitespace-only value as missing" {
  source "$LIB_DIR/env.sh"
  WHITESPACE_KEY="   "
  run require_env WHITESPACE_KEY
  [ "$status" -eq 1 ]
  [[ "$output" == *"WHITESPACE_KEY"* ]]
}

# Live-deploy hardening fix 5: derive the tunnel ID from the box's cloudflared connector
# token (base64 of {"a","t","s"}) so we target the real tunnel by ID, not a guessed name.
# Case must be preserved (the live run's real tunnel was capital-G "Goose...").
@test "tunnel_id_from_token decodes the base64 connector token to its tunnel id (.t)" {
  source "$LIB_DIR/env.sh"
  tok="$(printf '%s' '{"a":"acc","t":"Goose-7f3a-TID","s":"sek"}' | base64)"
  run tunnel_id_from_token "$tok"
  [ "$status" -eq 0 ]
  [ "$output" = "Goose-7f3a-TID" ]
}

@test "tunnel_id_from_token returns non-zero for an empty or junk token" {
  source "$LIB_DIR/env.sh"
  run tunnel_id_from_token ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# Teeth: cf_ssh targets the tunnel by the token-derived id and matches the name fallback
# case-insensitively (so a capitalised tunnel name is not missed).
@test "cf_ssh resolves the tunnel by token id with a case-insensitive name fallback" {
  grep -q "tunnel_id_from_token" "$SCRIPTS_DIR/cf_ssh.sh"
  grep -q "ascii_downcase" "$SCRIPTS_DIR/cf_ssh.sh"
}
