#!/usr/bin/env bats
load test_helper

@test "dry_run_all emits the DRY-RUN-ALL-OK token and exits 0" {
  run "$SCRIPTS_DIR/dry_run_all.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN-ALL-OK"* ]]
}

# Teeth: the token is load-bearing. Drop the echo and the token must vanish,
# so any downstream grep for it FAILS. Mirror the script into a temp dir,
# delete the token line, and assert the mutant no longer emits the sentinel.
# Never mutates anything under the real scripts/.
@test "dry_run_all without its token line does NOT emit the sentinel" {
  local work; work="$(mktemp -d "$REPO_ROOT/test/tmp/mut.XXXXXX")"
  grep -v "DRY-RUN-ALL-OK" "$SCRIPTS_DIR/dry_run_all.sh" > "$work/dry_run_all.sh"
  chmod +x "$work/dry_run_all.sh"
  run "$work/dry_run_all.sh"
  [[ "$output" != *"DRY-RUN-ALL-OK"* ]]
  rm -rf "$work"
}
