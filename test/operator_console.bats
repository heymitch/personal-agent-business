#!/usr/bin/env bats
# The vendored operator console: the real 3-tab management dashboard (Dashboard spend/ROI, New
# agent mint, Fleet), a password-gated thin proxy to the box receiver. These tests pin the SHAPE
# (the three tabs, the password wall, the receiver-proxy wiring) and the SANITIZATION (no client
# tenant data, no operator branding, no em dashes) so a regression or a leak fails the suite.
load test_helper

setup() { CONSOLE="$REPO_ROOT/surfaces/operator-console"; export CONSOLE; }

# ---- structure: exactly the three tabs the dashboard ships -------------------
@test "console index.html ships the three tabs (Dashboard, New agent, Fleet)" {
  grep -q 'data-tab="dashboard"' "$CONSOLE/index.html"
  grep -q 'data-tab="mint"' "$CONSOLE/index.html"
  grep -q 'data-tab="fleet"' "$CONSOLE/index.html"
}

@test "console index.html does NOT ship the operator-only Configure tab (3 tabs, not 4)" {
  run grep -q 'data-tab="config"' "$CONSOLE/index.html"
  [ "$status" -ne 0 ]
}

# ---- the password wall -------------------------------------------------------
@test "console ships the Edge-middleware password wall + login page" {
  [ -f "$CONSOLE/middleware.js" ]
  [ -f "$CONSOLE/login.html" ]
  grep -q 'pao_session' "$CONSOLE/middleware.js"
  grep -q 'Response.redirect' "$CONSOLE/middleware.js"
  grep -q 'PAO_PASSWORD_HASH' "$CONSOLE/api/login.ts"
}

# ---- thin proxy to the box receiver -----------------------------------------
@test "console api proxies forward to the box receiver via MINT_RECEIVER_URL" {
  grep -q 'MINT_RECEIVER_URL' "$CONSOLE/api/fleet.ts"
  grep -q 'MINT_RECEIVER_URL' "$CONSOLE/api/dashboard.ts"
  grep -q 'MINT_RECEIVER_URL' "$CONSOLE/api/mint.ts"
  # the secret is held server-side and presented to the receiver, never to the browser
  grep -q 'x-sim-secret' "$CONSOLE/api/fleet.ts"
}

@test "console mint proxy posts the per-person-email mint contract (personName + email)" {
  grep -q 'personName' "$CONSOLE/api/mint.ts"
  grep -q '/mint' "$CONSOLE/api/mint.ts"
}

# ---- sanitization: PRIVATE -> PUBLIC, airtight -------------------------------
# node_modules is gitignored (never shipped) but present locally for tsc; exclude it from the
# leak sweep so we only scan the committed, vendored console source.
@test "console carries NO client tenant data or operator branding" {
  run grep -RniE --exclude-dir=node_modules --exclude-dir=.vercel \
    'colin|devin|tristan|heymitch|ship30|wingman|prj_[A-Za-z0-9]|team_[A-Za-z0-9]' "$CONSOLE"
  [ "$status" -ne 0 ]
}

@test "console carries NO em dashes" {
  # Build the em dash from its UTF-8 bytes so this test file itself contains no literal em dash.
  local em; em="$(printf '\xe2\x80\x94')"
  run grep -RnF --exclude-dir=node_modules --exclude-dir=.vercel "$em" "$CONSOLE"
  [ "$status" -ne 0 ]
}

@test "console is branded personal-agent, not the operator's private repo" {
  grep -q 'Personal Agent' "$CONSOLE/index.html"
  grep -q '~/personal-agent-business' "$CONSOLE/index.html"
  run grep -q 'personal-agent-operator' "$CONSOLE/index.html"
  [ "$status" -ne 0 ]
}
