#!/usr/bin/env bats
load test_helper

@test "shellcheck passes on all scripts and libs" {
  shopt -s nullglob
  files=("$SCRIPTS_DIR"/*.sh "$LIB_DIR"/*.sh "$REPO_ROOT"/installer/scripts/*.sh)
  if [ ${#files[@]} -eq 0 ]; then skip "no scripts yet"; fi
  run shellcheck -x "${files[@]}"
  [ "$status" -eq 0 ]
}

@test "bash -n parses all scripts and libs" {
  shopt -s nullglob
  files=("$SCRIPTS_DIR"/*.sh "$LIB_DIR"/*.sh "$REPO_ROOT"/installer/scripts/*.sh)
  if [ ${#files[@]} -eq 0 ]; then skip "no scripts yet"; fi
  for f in "${files[@]}"; do
    run bash -n "$f"
    [ "$status" -eq 0 ]
  done
}

@test ".env is gitignored and never tracked" {
  cd "$REPO_ROOT"
  run git ls-files --error-unmatch .env
  [ "$status" -ne 0 ]
  grep -qx ".env" "$REPO_ROOT/.gitignore"
}
