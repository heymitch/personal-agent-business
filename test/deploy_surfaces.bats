#!/usr/bin/env bats
load test_helper

# Slice 2: deploy_surfaces.sh pushes the three client-facing surfaces (onboarding,
# landing, operator-console) to the operator's Vercel. The dry-run must NAME all
# three surfaces, construct the per-surface `vercel deploy` calls, and NEVER print
# the Vercel token value. No real Vercel call (vercel shimmed to a no-op recorder).

# A smart Vercel-API curl shim for the live-deploy hardening (fix 2 + fix 4). It touches
# NO network and never resolves a real host:
#   -X POST  .../env             consume the body on stdin, ack {"created":true}
#   -X PATCH .../projects/<id>    ack the ssoProtection disable {"ssoProtection":null}
#   GET      .../env             return the canned env-key list ($VERCEL_ENV_KEYS)
#   (anything else)              {}
# The test controls which keys the env read-back reports via $VERCEL_ENV_KEYS so the
# read-back assertion (fix 4) can be exercised positive AND negative.
write_smart_vercel_curl() {
  cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
args="$*"
if printf '%s' "$args" | grep -q -- '-X POST'; then cat >/dev/null 2>&1 || true; echo '{"created":true}'; exit 0; fi
if printf '%s' "$args" | grep -q -- '-X PATCH'; then echo '{"ssoProtection":null}'; exit 0; fi
if printf '%s' "$args" | grep -q '/env'; then
  printf '{"envs":['
  first=1
  for k in ${VERCEL_ENV_KEYS:-}; do
    [ "$first" -eq 1 ] || printf ','
    printf '{"key":"%s"}' "$k"
    first=0
  done
  printf ']}'
  exit 0
fi
echo '{}'
exit 0
SH
  chmod +x "$FAKE_BIN/curl"
}

setup() {
  make_fake_bin vercel jq
  write_smart_vercel_curl
  export VERCEL_TOKEN="vt-secret-value"
  export COMPOSIO_API_KEY="ck-secret-value"
  export ONBOARDER_BASE_URL="https://onb.example.com"
  # The console proxies the box receiver, so a real deploy needs these set FIRST
  # (the engine emits them). Present here so the all-surfaces real run can deploy
  # the console; individual tests unset them to prove the ordering gate.
  export MINT_RECEIVER_URL="https://receiver.example.com"
  export MINT_SECRET="ms-secret-value"
  # Vercel-API plumbing (fix 2 + fix 4): a project id so the API calls have a target
  # without a real `vercel link`, and the full set of keys the env read-back reports.
  export VERCEL_PROJECT_ID_OVERRIDE="prj_test"
  export VERCEL_ENV_KEYS="COMPOSIO_API_KEY MINT_RECEIVER_URL MINT_SECRET CF_ACCESS_AUTH_DOMAIN CF_ACCESS_AUD OWNER_EMAIL DEFAULT_SKILLS"
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

# Fix 2 teeth: the dry-run must plan to disable Deployment Protection for the ONBOARDING
# project only (ssoProtection=null) so clients can open connect links. The gated console
# must NOT be unprotected.
@test "deploy_surfaces --dry-run plans to disable Deployment Protection for onboarding only" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssoProtection"* ]]
  printf '%s\n' "$output" | grep -i "ssoProtection" | grep -qi "onboarding"
  ! { printf '%s\n' "$output" | grep -i "ssoProtection" | grep -qi "console"; }
}

# Fix 2 teeth: a real (shimmed) operational run disables onboarding Deployment Protection
# and emits ONBOARDING-PUBLIC. Mutation-proof: drop the make_onboarding_public call and
# this token vanishes.
@test "deploy_surfaces disables onboarding Deployment Protection on a real run (ONBOARDING-PUBLIC)" {
  run "$SCRIPTS_DIR/deploy_surfaces.sh" --operational
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONBOARDING-PUBLIC"* ]]
  [[ "$output" == *"SURFACES-DEPLOYED"* ]]
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
