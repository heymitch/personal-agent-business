#!/usr/bin/env bats
# Deploy the minting engine (receiver + reconcile timer) onto the operator's OWN
# box over SSH. This is the operator standing up THEIR OWN rooster: one box hosts
# their personal agent AND their minting engine. No separate infra. The SSH
# channel is the SAME one configure_box.sh / move_up.sh use (root@<ip>, su - hermes).
# Every ssh/scp/rsync is PATH-shimmed so no test touches a real box.

load "test_helper.bash"

setup() {
  make_fake_bin ssh scp rsync
  export AGENT_IP="203.0.113.10"
}

teardown() { teardown_fake_bin; }

@test "deploy_engine --dry-run prints the SSH install plan and the timer enable, touches nothing" {
  run "$SCRIPTS_DIR/deploy_engine.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"203.0.113.10"* ]]
  [[ "$output" == *"reconcile-sessions.timer"* ]]
  [[ "$output" == *"receiver"* ]]
}

@test "deploy_engine --dry-run renders the systemd units with NO placeholder tokens left" {
  run "$SCRIPTS_DIR/deploy_engine.sh" --dry-run
  [ "$status" -eq 0 ]
  # The shipped unit templates carry __INSTALLER_ROOT__ / __SERVICE_USER__ tokens;
  # the rendered, deployed copy must have substituted ALL of them.
  [[ "$output" != *"__INSTALLER_ROOT__"* ]]
  [[ "$output" != *"__SERVICE_USER__"* ]]
  [[ "$output" != *"__PROVISION_ENV_FILE__"* ]]
}

@test "deploy_engine reuses the same SSH channel as configure_box (root@<ip>)" {
  run "$SCRIPTS_DIR/deploy_engine.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"root@203.0.113.10"* ]]
}

@test "deploy_engine requires a box IP" {
  unset AGENT_IP
  run "$SCRIPTS_DIR/deploy_engine.sh" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* || "$output" == *"AGENT_IP"* || "$output" == *"required"* ]]
}

@test "deploy_engine emits its success token on a (shimmed) real run" {
  run "$SCRIPTS_DIR/deploy_engine.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENGINE-DEPLOYED"* ]]
}

# Ordering teeth: the engine deploy captures the receiver URL so /setup can wire the
# console's MINT_RECEIVER_URL AFTER the receiver exists (never before).
@test "deploy_engine emits RECEIVER-URL so the console is wired only after the engine" {
  run "$SCRIPTS_DIR/deploy_engine.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECEIVER-URL="* ]]
  run "$SCRIPTS_DIR/deploy_engine.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RECEIVER-URL="* ]]
}

# Live-deploy hardening fix 1: the box installs with `npm ci --omit=dev` and then
# starts the receiver via `tsx receiver/server.ts`. If tsx is a devDependency it is
# absent under --omit=dev and the receiver crashes on start. tsx MUST be a runtime
# dependency so it survives the prod-only install on the box.
@test "engine package.json ships tsx as a RUNTIME dependency (survives npm ci --omit=dev)" {
  run node -e '
    const p = require(process.argv[1]);
    if (!(p.dependencies && p.dependencies.tsx)) { console.error("tsx not in dependencies"); process.exit(1); }
    if (p.devDependencies && p.devDependencies.tsx) { console.error("tsx still in devDependencies"); process.exit(1); }
    console.log("tsx-runtime-ok");
  ' "$REPO_ROOT/installer/package.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tsx-runtime-ok"* ]]
}

@test "engine lockfile resolves tsx as a production (non-dev) package" {
  run node -e '
    const l = require(process.argv[1]);
    const root = l.packages[""];
    const node = l.packages["node_modules/tsx"];
    if (!(root.dependencies && root.dependencies.tsx)) { console.error("tsx not a root dependency in lockfile"); process.exit(1); }
    if (node && node.dev === true) { console.error("tsx node is dev-flagged"); process.exit(1); }
    console.log("tsx-lock-ok");
  ' "$REPO_ROOT/installer/package-lock.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tsx-lock-ok"* ]]
}
