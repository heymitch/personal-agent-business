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

# ---- the Cloudflare Access email gate (no static password) -------------------
@test "console is gated by the Cloudflare Access email gate, keyed to the operator email" {
  [ -f "$CONSOLE/middleware.js" ]
  # Verifies the Cloudflare Access JWT against the operator's team, app aud, and email.
  grep -q 'CF_ACCESS_AUTH_DOMAIN' "$CONSOLE/middleware.js"
  grep -q 'CF_ACCESS_AUD' "$CONSOLE/middleware.js"
  grep -q 'OWNER_EMAIL' "$CONSOLE/middleware.js"
  grep -qi 'cf-access-jwt-assertion' "$CONSOLE/middleware.js"
}

@test "console no longer ships the static password wall" {
  [ ! -f "$CONSOLE/login.html" ]
  [ ! -f "$CONSOLE/api/login.ts" ]
  [ ! -f "$CONSOLE/api/logout.ts" ]
  # No trace of the old shared-password gate anywhere in the console.
  run grep -RniE --exclude-dir=node_modules --exclude-dir=.vercel \
    'PAO_PASSWORD_HASH|pao_session|SESSION_SECRET' "$CONSOLE"
  [ "$status" -ne 0 ]
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
