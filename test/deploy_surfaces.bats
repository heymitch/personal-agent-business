#!/usr/bin/env bats
load test_helper

# Slice 2: deploy_surfaces.sh pushes the three client-facing surfaces (onboarding,
# landing, operator-console) to the operator's Vercel. The dry-run must NAME all
# three surfaces, construct the per-surface `vercel deploy` calls, and NEVER print
# the Vercel token value. No real Vercel call (vercel shimmed to a no-op recorder).
setup() {
  make_fake_bin vercel jq
  export VERCEL_TOKEN="vt-secret-value"
  export COMPOSIO_API_KEY="ck-secret-value"
  export ONBOARDER_BASE_URL="https://onb.example.com"
}
teardown() { teardown_fake_bin; }

@test "deploy_surfaces --dry-run lists all three surfaces" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"onboarding"* ]]
  [[ "$output" == *"landing"* ]]
  [[ "$output" == *"operator-console"* ]]
}

@test "deploy_surfaces --dry-run constructs the per-surface vercel deploy call" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"vercel deploy"* ]]
  [[ "$output" == *"--prod"* ]]
}

@test "deploy_surfaces --dry-run never prints the vercel token value" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"vt-secret-value"* ]]
}

@test "deploy_surfaces --dry-run never prints the composio key value" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"ck-secret-value"* ]]
}

# Teeth: SURFACES-DEPLOYED is the load-bearing success token. Drop the final
# success path and this disappears; the test FAILS. The token also carries the
# three deployed surface URLs the /deploy-surfaces command greps for downstream.
@test "deploy_surfaces carries the SURFACES-DEPLOYED success token" {
  grep -q "SURFACES-DEPLOYED" "$SCRIPTS_DIR/deploy_surfaces.sh"
}

# Teeth: the success token must report all three surface URLs (the command reads
# the onboarding url back into ONBOARDER_BASE_URL). Mutation-proof: strip any one
# url=... emission and the assertion below catches the missing surface.
@test "deploy_surfaces emits the three surface urls in the success token" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SURFACES-DEPLOYED"* ]]
  [[ "$output" == *"onboarding="* ]]
  [[ "$output" == *"landing="* ]]
  [[ "$output" == *"console="* ]]
}
