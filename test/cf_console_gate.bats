#!/usr/bin/env bats
load test_helper

# cf_console_gate.sh stands up the SAME Cloudflare Access email gate the client
# surfaces use, for the operator console: a self_hosted Access app + an allow-policy
# keyed to OWNER_EMAIL. No tunnel (the console is on Vercel). The dry-run must show
# the Access app + email policy, name the console host, and NEVER print the token.
# No real Cloudflare call (curl shimmed to a no-op; jq passes through).
setup() {
  make_fake_bin curl jq
  export CLOUDFLARE_API_TOKEN="ck-secret-value"
  export CLOUDFLARE_ACCOUNT_ID="acct"
  export AGENT_DOMAIN="op.example.com"
  export OWNER_EMAIL="op@x.com"
}
teardown() { teardown_fake_bin; }

@test "cf_console_gate --dry-run gates the console host with a self_hosted Access app" {
  run "$SCRIPTS_DIR/cf_console_gate.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"console.op.example.com"* ]]
  [[ "$output" == *"access/apps"* ]]
  [[ "$output" == *"self_hosted"* ]]
}

@test "cf_console_gate --dry-run allows ONLY the operator email (no static password)" {
  run "$SCRIPTS_DIR/cf_console_gate.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow email=op@x.com"* ]]
}

@test "cf_console_gate --dry-run never prints the API token value" {
  run "$SCRIPTS_DIR/cf_console_gate.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"ck-secret-value"* ]]
}

# Teeth: the script must hand back the env the console middleware verifies against.
@test "cf_console_gate emits the CONSOLE-GATE-READY token + the CF Access env keys" {
  grep -q "CONSOLE-GATE-READY" "$SCRIPTS_DIR/cf_console_gate.sh"
  grep -q "CF_ACCESS_AUTH_DOMAIN=" "$SCRIPTS_DIR/cf_console_gate.sh"
  grep -q "CF_ACCESS_AUD=" "$SCRIPTS_DIR/cf_console_gate.sh"
}
