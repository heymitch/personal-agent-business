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

# Recording shims: capture every ssh invocation (one per line) and the rsync args so a
# re-deploy-safety test can assert the exclude set and the stop-before-start ordering.
# Overwrites the no-op ssh/rsync setup() made; scoped to the calling test because bats
# reruns setup() before every test. The rec paths are baked into each shim.
record_ssh_rsync() {
  SSH_REC="$REPO_ROOT/test/tmp/de-ssh-rec-$$.txt"
  RSYNC_REC="$REPO_ROOT/test/tmp/de-rsync-rec-$$.txt"
  export SSH_REC RSYNC_REC
  rm -f "$SSH_REC" "$RSYNC_REC"
  cat > "$FAKE_BIN/ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSH_REC"
exit 0
SH
  cat > "$FAKE_BIN/rsync" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RSYNC_REC"
exit 0
SH
  chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/rsync"
}

# Re-deploy safety (bug 1): the --delete rsync must NEVER delete the box provision env.
# Losing /home/hermes/personal-agent-engine/.env re-keys every client on the box.
@test "deploy_engine rsync excludes the box provision env (.env / .env.*) so a re-deploy keeps operator keys" {
  record_ssh_rsync
  run "$SCRIPTS_DIR/deploy_engine.sh"
  [ "$status" -eq 0 ]
  grep -qF -- '--exclude .env' "$RSYNC_REC"
  grep -qF -- '--exclude .env.*' "$RSYNC_REC"
}

# Re-deploy safety (bug 1, existing-client state): the client REGISTRY + mint QUEUE +
# activity/status logs are *.jsonl the box writes; a re-deploy must not wipe the
# operator's EXISTING clients. The userId->sessionId store stays excluded too.
@test "deploy_engine rsync preserves existing-client state (registry/queue jsonl + session-store) under --delete" {
  record_ssh_rsync
  run "$SCRIPTS_DIR/deploy_engine.sh"
  [ "$status" -eq 0 ]
  grep -qF -- '--exclude receiver/*.jsonl' "$RSYNC_REC"
  grep -qF -- 'receiver/session-store' "$RSYNC_REC"
}

# Re-deploy safety (bug 2): a re-deploy must STOP the old receiver and free port 8788
# BEFORE starting the new one, so the NEW code actually takes over (not silent stale
# code) and exactly ONE receiver runs. The [r] bracket keeps pkill from self-matching.
@test "deploy_engine restarts the receiver CLEAN: stop-then-start, frees 8788, exactly one start" {
  record_ssh_rsync
  run "$SCRIPTS_DIR/deploy_engine.sh"
  [ "$status" -eq 0 ]
  # the stop step frees the port...
  grep -qF '8788' "$SSH_REC"
  # ...and the stop (pkill) is issued strictly BEFORE the start (nohup).
  stop_line="$(grep -n 'pkill' "$SSH_REC" | head -1 | cut -d: -f1)"
  start_line="$(grep -n 'nohup' "$SSH_REC" | head -1 | cut -d: -f1)"
  [ -n "$stop_line" ]
  [ -n "$start_line" ]
  [ "$stop_line" -lt "$start_line" ]
  # exactly ONE receiver is started (re-running must not leave two).
  run grep -c 'nohup' "$SSH_REC"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

# The --dry-run preview must SHOW the state-preserving excludes and the clean-restart
# step so an operator can confirm a re-deploy is safe before running it.
@test "deploy_engine --dry-run prints the state-preserving excludes and the clean-restart step" {
  run "$SCRIPTS_DIR/deploy_engine.sh" --dry-run
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF -- '--exclude .env'
  printf '%s\n' "$output" | grep -qF -- 'receiver/*.jsonl'
  printf '%s\n' "$output" | grep -qiF 'stop the old receiver'
  printf '%s\n' "$output" | grep -qF '8788'
}
