#!/usr/bin/env bats
# set_box_env.sh upserts ONE key into the box's provision env file over the SAME SSH
# channel as deploy_engine.sh, so an operator can ADD or ROTATE a key on a LIVE box
# without a full re-deploy and without disturbing any other line.
#
# The ssh shim here is a FAKE BOX: it records every ssh ARG line (to prove the value
# never rides the command line) and then runs the remote upsert command LOCALLY against
# the test's BOX_ENV_FILE (so we can assert the on-box result). The piped value flows
# straight through stdin to the remote script's $(cat). No real box, no network.

load "test_helper.bash"

setup() {
  mkdir -p "$REPO_ROOT/test/tmp"
  FAKE_BIN="$(mktemp -d "$REPO_ROOT/test/tmp/fakebin.XXXXXX")"
  export FAKE_BIN
  SSH_REC="$REPO_ROOT/test/tmp/sbe-ssh-$$.txt"
  BOX_ENV_FILE="$REPO_ROOT/test/tmp/sbe-boxenv-$$"
  export SSH_REC BOX_ENV_FILE
  rm -f "$SSH_REC" "$BOX_ENV_FILE"
  cat > "$FAKE_BIN/ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSH_REC"
cmd="\${@: -1}"
sh -c "\$cmd"
SH
  chmod +x "$FAKE_BIN/ssh"
  export PATH="$FAKE_BIN:$PATH"
  export AGENT_IP="203.0.113.10"
}

teardown() {
  [ -n "${FAKE_BIN:-}" ] && rm -rf "$FAKE_BIN"
  rm -f "$SSH_REC" "$BOX_ENV_FILE"
}

@test "set_box_env requires a KEY_NAME" {
  run "$SCRIPTS_DIR/set_box_env.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qiE "usage|required"
}

@test "set_box_env --dry-run prints the plan, reads no value, fires no ssh" {
  export OPENAI_ADMIN_KEY="sk-sentinel-dry"
  run "$SCRIPTS_DIR/set_box_env.sh" --dry-run OPENAI_ADMIN_KEY
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "key=OPENAI_ADMIN_KEY"
  # no ssh was fired...
  [ ! -s "$SSH_REC" ]
  # ...and the value never appeared in the plan.
  run grep -qF "sk-sentinel-dry" <<< "$output"
  [ "$status" -ne 0 ]
}

@test "set_box_env appends the key when absent (other lines untouched)" {
  printf 'FOO=1\nBAR=2\n' > "$BOX_ENV_FILE"
  export OPENAI_ADMIN_KEY="sk-sentinel-append"
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "BOX-ENV-SET key=OPENAI_ADMIN_KEY"
  grep -qx 'FOO=1' "$BOX_ENV_FILE"
  grep -qx 'BAR=2' "$BOX_ENV_FILE"
  grep -qx 'OPENAI_ADMIN_KEY=sk-sentinel-append' "$BOX_ENV_FILE"
  run grep -c '^OPENAI_ADMIN_KEY=' "$BOX_ENV_FILE"
  [ "$output" -eq 1 ]
}

@test "set_box_env replaces the key when present (no duplicate, other lines untouched)" {
  printf 'FOO=1\nOPENAI_ADMIN_KEY=sk-OLD-value\nBAR=2\n' > "$BOX_ENV_FILE"
  export OPENAI_ADMIN_KEY="sk-sentinel-new"
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -eq 0 ]
  grep -qx 'OPENAI_ADMIN_KEY=sk-sentinel-new' "$BOX_ENV_FILE"
  # the old value is gone...
  run grep -qF 'sk-OLD-value' "$BOX_ENV_FILE"
  [ "$status" -ne 0 ]
  # ...exactly one key line remains...
  run grep -c '^OPENAI_ADMIN_KEY=' "$BOX_ENV_FILE"
  [ "$output" -eq 1 ]
  # ...and the sibling lines are intact.
  grep -qx 'FOO=1' "$BOX_ENV_FILE"
  grep -qx 'BAR=2' "$BOX_ENV_FILE"
}

@test "set_box_env is idempotent (running twice == running once)" {
  printf 'FOO=1\n' > "$BOX_ENV_FILE"
  export OPENAI_ADMIN_KEY="sk-sentinel-idem"
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -eq 0 ]
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -eq 0 ]
  run grep -c '^OPENAI_ADMIN_KEY=' "$BOX_ENV_FILE"
  [ "$output" -eq 1 ]
  grep -qx 'OPENAI_ADMIN_KEY=sk-sentinel-idem' "$BOX_ENV_FILE"
  grep -qx 'FOO=1' "$BOX_ENV_FILE"
}

@test "set_box_env never exposes the value on stdout or in the ssh args" {
  printf 'FOO=1\n' > "$BOX_ENV_FILE"
  export OPENAI_ADMIN_KEY="sk-sentinel-secret-123"
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -eq 0 ]
  out="$output"
  # the value never printed to stdout (only the non-secret token did)...
  run grep -qF "sk-sentinel-secret-123" <<< "$out"
  [ "$status" -ne 0 ]
  # ...and the value never rode the ssh command line (it went over stdin only).
  run grep -qF "sk-sentinel-secret-123" "$SSH_REC"
  [ "$status" -ne 0 ]
  # the value DID land in the box env (it travelled over stdin).
  grep -qx 'OPENAI_ADMIN_KEY=sk-sentinel-secret-123' "$BOX_ENV_FILE"
}

@test "set_box_env fails clean when AGENT_IP is unset (no ssh fired)" {
  unset AGENT_IP
  export OPENAI_ADMIN_KEY="sk-sentinel-noip"
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF "AGENT_IP"
  [ ! -s "$SSH_REC" ]
}

@test "set_box_env fails clean when the key is missing/empty in local .env (no ssh fired)" {
  unset OPENAI_ADMIN_KEY
  run "$SCRIPTS_DIR/set_box_env.sh" OPENAI_ADMIN_KEY
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF "OPENAI_ADMIN_KEY"
  [ ! -s "$SSH_REC" ]
}
