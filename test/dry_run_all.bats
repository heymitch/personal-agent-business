#!/usr/bin/env bats
load test_helper

# dry_run_all chains every script's --dry-run plus the SSH-only usage guards, then
# emits the contract token. Shim every external command so the chain spends no money
# and touches no box; keep jq real so the dry-run bodies actually compute.
setup() {
  make_fake_bin curl jq ssh scp rsync cloudflared vercel
  export HETZNER_TOKEN="fake-token" AGENT_NAME="op-agent"
  export SSH_PUBKEY="ssh-ed25519 AAAA op@host"
  export CLOUDFLARE_API_TOKEN="ck" CLOUDFLARE_ACCOUNT_ID="acct"
  export AGENT_DOMAIN="op.example.com" OWNER_EMAIL="op@x.com"
  export COMPOSIO_API_KEY="fake-composio-key"
  CLOUD_INIT_FILE="$(mktemp "$REPO_ROOT/test/tmp/cloudinit.XXXXXX")"
  printf 'stub\n' > "$CLOUD_INIT_FILE"
  export CLOUD_INIT_FILE
}
teardown() {
  rm -f "${CLOUD_INIT_FILE:-}"
  teardown_fake_bin
}

@test "dry_run_all emits the DRY-RUN-ALL-OK token and exits 0" {
  run "$SCRIPTS_DIR/dry_run_all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN-ALL-OK"* ]]
}

@test "dry_run_all never prints a secret value" {
  run "$SCRIPTS_DIR/dry_run_all.sh"
  [[ "$output" != *"fake-token"* ]]
  [[ "$output" != *"fake-vercel-token"* ]]
  [[ "$output" != *"fake-composio-key"* ]]
}

# Teeth: the token is load-bearing. Drop the echo and the token must vanish,
# so any downstream grep for it FAILS. Mirror the script into a temp dir,
# delete the token line, and assert the mutant no longer emits the sentinel.
# Never mutates anything under the real scripts/.
@test "dry_run_all without its token line does NOT emit the sentinel" {
  local work; work="$(mktemp -d "$REPO_ROOT/test/tmp/mut.XXXXXX")"
  grep -v "DRY-RUN-ALL-OK" "$SCRIPTS_DIR/dry_run_all.sh" > "$work/dry_run_all.sh"
  chmod +x "$work/dry_run_all.sh"
  run "$work/dry_run_all.sh"
  [[ "$output" != *"DRY-RUN-ALL-OK"* ]]
  rm -rf "$work"
}
