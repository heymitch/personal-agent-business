#!/usr/bin/env bats
# Assert the Slice 3 guardrails GR1-GR5 hold in the VENDORED engine, and that the
# engine carries ZERO rooster values. These are static greps over the shipped
# source: they re-walk none of the proven dead-ends, they only PROVE the shipped
# code stayed on the right side of each.

load "test_helper.bash"

ENGINE="$REPO_ROOT/installer"

@test "GR1: the instant path is the receiver ping, and the only Composio webhook is expiry" {
  # The receiver's instant path is POST /refresh-session (the onboarding page
  # pings it on a new connect). The /composio-webhook companion exists ONLY for
  # connected_account.expired; Composio does not fire on a NEW connection.
  grep -q "/refresh-session" "$ENGINE/receiver/server.ts"
  grep -qF "connected_account.expired" "$ENGINE/receiver/server.ts"
  # No code subscribes a 'connection.completed' Composio webhook (literal match,
  # so the handle-connection-completed.js IMPORT path does not count).
  run grep -RnF "connection.completed" "$ENGINE/receiver"
  [ "$status" -ne 0 ]
}

@test "GR2: later apps expand the pin via session.update, never a second toolRouter.create" {
  # The refresh path updates an existing session in place (stable mcp.url).
  grep -q "updateSession" "$ENGINE/src/connect/refresh-session.ts"
  grep -q "toolRouter" "$ENGINE/src/connect/refresh-session-sdk.ts"
  grep -q "\.update(" "$ENGINE/src/connect/refresh-session-sdk.ts"
  # The refresh adapter must NOT create a session; create is a one-time provision act.
  run grep -n "toolRouter.create" "$ENGINE/src/connect/refresh-session-sdk.ts"
  [ "$status" -ne 0 ]
}

@test "GR3: a connection is verified with session.search, never the (always-4) tool list" {
  # The management/verify pattern reads connected accounts / searches, it does not
  # equate 'connected' with the meta tool list. Prove the engine reads ACTIVE
  # connected accounts to decide the toolkit union.
  grep -q "connectedAccounts.list" "$ENGINE/src/connect/refresh-session-sdk.ts"
  grep -q 'status === "ACTIVE"' "$ENGINE/src/connect/refresh-session-sdk.ts"
}

@test "GR4: the receiver/reconcile read their OWN provision env, NOT the agent's ~/.hermes/.env" {
  # Secrets come from process.env (+ an optional PROVISION_ENV_FILE the deploy sets
  # to the receiver's own file). No CODE LINE reads the agent's ~/.hermes/.env
  # (mentions in comments documenting the rule are allowed; an actual readFile is not).
  run grep -RnE "readFileSync\([^)]*\.hermes" "$ENGINE/receiver" "$ENGINE/scripts"
  [ "$status" -ne 0 ]
  grep -q "PROVISION_ENV_FILE" "$ENGINE/scripts/reconcile-sessions.ts"
  grep -q "process.env" "$ENGINE/receiver/server.ts"
}

@test "GR5: Gmail is pinned to the tight read+send config, never the broad default" {
  grep -q "gmail.readonly" "$ENGINE/src/connect/gmail-auth-config.ts"
  grep -q "gmail.send" "$ENGINE/src/connect/gmail-auth-config.ts"
  # The broad full-mailbox scope must NOT be in the actual SCOPES array (only the
  # cautionary comment names it). Assert it is absent from the TIGHT_GMAIL_SCOPES lines.
  run grep -nE '^\s*"https://mail.google.com/"' "$ENGINE/src/connect/gmail-auth-config.ts"
  [ "$status" -ne 0 ]
}

@test "ZERO rooster: no rooster IP/host/domain/account path leaks into the vendored engine" {
  # The de-tenanting contract: the shipped engine has zero rooster-specific values.
  run grep -RniE "rooster|ship30|/home/hermes/wingman" "$ENGINE/src" "$ENGINE/receiver" "$ENGINE/scripts" "$ENGINE/systemd"
  [ "$status" -ne 0 ]
}

@test "systemd units ship as de-tenanted TEMPLATES (placeholders, not concrete rooster paths)" {
  grep -q "__INSTALLER_ROOT__" "$ENGINE/systemd/reconcile-sessions.service"
  grep -q "__SERVICE_USER__" "$ENGINE/systemd/reconcile-sessions.service"
  # No concrete absolute home path baked into the shipped unit.
  run grep -nE "/home/[a-z]+/wingman" "$ENGINE/systemd/reconcile-sessions.service"
  [ "$status" -ne 0 ]
}
