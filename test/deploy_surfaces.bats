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
  # The console proxies the box receiver, so a real deploy needs these set FIRST
  # (the engine emits them). Present here so the all-surfaces real run can deploy
  # the console; individual tests unset them to prove the ordering gate.
  export MINT_RECEIVER_URL="https://receiver.example.com"
  export MINT_SECRET="ms-secret-value"
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

# Ordering teeth: the console is a thin proxy to the box receiver, so it must NOT be
# deployed before that receiver URL is known. With MINT_RECEIVER_URL unset, an
# operational (console-bearing) deploy ERRORS and ships nothing, so the console is
# never live in a "not configured" state.
@test "deploy_surfaces refuses to deploy the console before the receiver URL is known" {
  unset MINT_RECEIVER_URL
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --operational
  [ "$status" -ne 0 ]
  [[ "$output" == *"MINT_RECEIVER_URL"* ]]
  [[ "$output" != *"SURFACES-DEPLOYED"* ]]
}

# Separation teeth: the landing page deploys on its own, independent of the
# operational console+onboarding group, and needs no receiver URL.
@test "deploy_surfaces --landing deploys the landing page alone (no receiver needed)" {
  unset MINT_RECEIVER_URL MINT_SECRET
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --landing
  [ "$status" -eq 0 ]
  [[ "$output" == *"SURFACES-DEPLOYED"* ]]
  [[ "$output" == *"landing="* ]]
  [[ "$output" != *"console="* ]]
  [[ "$output" != *"onboarding="* ]]
}
