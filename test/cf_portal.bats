#!/usr/bin/env bats
load test_helper

# Slice 1: cf_portal.sh dry-run must show the ingress host-header rule. A missing
# httpHostHeader:localhost rule is the 502 footgun, so the dry-run body has to carry
# localhost:9119 + httpHostHeader. No real Cloudflare call (curl shimmed to no-op).
setup() {
  make_fake_bin curl jq
  export CLOUDFLARE_API_TOKEN="ck-secret-value"
  export CLOUDFLARE_ACCOUNT_ID="acct"
  export AGENT_DOMAIN="op.example.com"
  export OWNER_EMAIL="op@x.com"
  export AGENT_NAME="op-agent"
}
teardown() { teardown_fake_bin; }

@test "cf_portal --dry-run includes ingress target localhost:9119" {
  run "$SCRIPTS_DIR/cf_portal.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'localhost:9119'* ]]
}

@test "cf_portal --dry-run includes the httpHostHeader 502 fix" {
  run "$SCRIPTS_DIR/cf_portal.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'httpHostHeader'* ]]
}

@test "cf_portal --dry-run never prints the API token value" {
  run "$SCRIPTS_DIR/cf_portal.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"ck-secret-value"* ]]
}

# Teeth: PORTAL-READY is the load-bearing success token.
@test "cf_portal carries the PORTAL-READY token" {
  grep -q "PORTAL-READY" "$SCRIPTS_DIR/cf_portal.sh"
}
