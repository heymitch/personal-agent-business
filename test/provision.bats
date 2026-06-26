#!/usr/bin/env bats
load test_helper

# Slice 1: provision.sh dry-run constructs the right Hetzner call WITHOUT spending
# money. make_fake_bin shims curl to a no-op (a real POST is impossible), and keeps
# real jq so the printed body is the SAME body the live call would send.
setup() {
  make_fake_bin curl jq
  export HETZNER_TOKEN="fake-token-1234567890"
  export AGENT_NAME="op-agent"
  export SSH_PUBKEY="ssh-ed25519 AAAA op@host"
  # Point cloud-init at a tiny stub so the dry-run body never embeds the real file.
  CLOUD_INIT_FILE="$(mktemp "$REPO_ROOT/test/tmp/cloudinit.XXXXXX")"
  printf '#!/usr/bin/env bash\necho stub\n' > "$CLOUD_INIT_FILE"
  export CLOUD_INIT_FILE
}
teardown() {
  rm -f "${CLOUD_INIT_FILE:-}"
  teardown_fake_bin
}

@test "provision --dry-run prints jq body with the agent name, never the token value" {
  run "$SCRIPTS_DIR/provision.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name":"op-agent"'* ]]
  [[ "$output" != *"fake-token-1234567890"* ]]
}

@test "provision --dry-run collapses user_data to a byte count (no cloud-init dumped)" {
  run "$SCRIPTS_DIR/provision.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"bytes"* ]]
  [[ "$output" != *"echo stub"* ]]
}

# Teeth: PROVISION-OK is the load-bearing success token. A mutant that drops the
# echo must stop emitting it, so any downstream grep for it FAILS.
@test "provision without its PROVISION-OK line does NOT emit the token" {
  grep -q "PROVISION-OK" "$SCRIPTS_DIR/provision.sh"
}
