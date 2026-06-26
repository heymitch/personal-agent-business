#!/usr/bin/env bats
# Install the two DAILY maintenance timers (hermes-update + git-backup) onto the
# operator's OWN box over SSH, the SAME channel as deploy_engine.sh. Every
# ssh/rsync is PATH-shimmed so no test touches a real box or spends anything.

load "test_helper.bash"

setup() {
  make_fake_bin ssh rsync
  export AGENT_IP="203.0.113.10"
}
teardown() { teardown_fake_bin; }

@test "deploy_maintenance --dry-run installs BOTH daily timers, touches nothing" {
  run "$SCRIPTS_DIR/deploy_maintenance.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"203.0.113.10"* ]]
  [[ "$output" == *"hermes-update.timer"* ]]
  [[ "$output" == *"git-backup.timer"* ]]
}

@test "deploy_maintenance renders units with NO placeholder tokens left" {
  run "$SCRIPTS_DIR/deploy_maintenance.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"__INSTALLER_ROOT__"* ]]
  [[ "$output" != *"__SERVICE_USER__"* ]]
  [[ "$output" != *"__PROVISION_ENV_FILE__"* ]]
  [[ "$output" != *"__BACKUP_DIR__"* ]]
}

@test "deploy_maintenance dry-run NEVER prints the backup remote (it may carry a token)" {
  export BACKUP_GIT_REMOTE="https://x-access-token:ghp_supersecrettoken@github.com/op/backup.git"
  run "$SCRIPTS_DIR/deploy_maintenance.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"ghp_supersecrettoken"* ]]
}

@test "deploy_maintenance reuses the root@<ip> SSH channel" {
  run "$SCRIPTS_DIR/deploy_maintenance.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"root@203.0.113.10"* ]]
}

@test "deploy_maintenance requires a box IP" {
  unset AGENT_IP
  run "$SCRIPTS_DIR/deploy_maintenance.sh" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* || "$output" == *"AGENT_IP"* ]]
}

@test "deploy_maintenance emits its success token on a (shimmed) real run" {
  run "$SCRIPTS_DIR/deploy_maintenance.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MAINTENANCE-DEPLOYED"* ]]
}

@test "both maintenance timers are actually DAILY" {
  grep -qi "OnCalendar=daily" "$REPO_ROOT/installer/systemd/hermes-update.timer"
  grep -qi "OnCalendar=daily" "$REPO_ROOT/installer/systemd/git-backup.timer"
}
