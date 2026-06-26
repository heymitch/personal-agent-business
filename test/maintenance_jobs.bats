#!/usr/bin/env bats
# The two DAILY box-side maintenance jobs (installer/scripts/):
#   hermes-update.sh  -- keep the personal agent current; optional fleet fan-out
#   git-backup.sh     -- push agency state, NEVER secrets
# git-backup is proven against a REAL local bare remote (offline, free): we inspect
# exactly what landed in the pushed tree to prove .env / key material never ship.

load "test_helper.bash"

setup() {
  mkdir -p "$REPO_ROOT/test/tmp"
  WORK="$(mktemp -d "$REPO_ROOT/test/tmp/maint.XXXXXX")"
  export WORK
  HU="$REPO_ROOT/installer/scripts/hermes-update.sh"
  GB="$REPO_ROOT/installer/scripts/git-backup.sh"
}
teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; teardown_fake_bin || true; }

# --- hermes-update.sh -----------------------------------------------------------

@test "hermes-update self-updates the own box and emits its token" {
  make_fake_bin hermes ssh jq
  run "$HU"
  [ "$status" -eq 0 ]
  [[ "$output" == *"self: hermes update"* ]]
  [[ "$output" == *"HERMES-UPDATE-OK count=1"* ]]
}

@test "hermes-update fleet loop visits each non-retired registry box when UPDATE_FLEET=1" {
  make_fake_bin hermes ssh jq
  REG="$WORK/registry.jsonl"
  printf '%s\n' \
    '{"slug":"acme","retired":false}' \
    '{"slug":"beta","retired":false}' \
    '{"slug":"gone","retired":true}' > "$REG"
  export UPDATE_FLEET=1 REGISTRY_FILE="$REG" AGENT_DOMAIN="op.example.com"
  run "$HU"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh-acme.op.example.com"* ]]
  [[ "$output" == *"ssh-beta.op.example.com"* ]]
  [[ "$output" != *"gone"* ]]                       # retired agents are skipped
  [[ "$output" == *"HERMES-UPDATE-OK count=3"* ]]   # self + 2 live boxes
}

# --- git-backup.sh --------------------------------------------------------------

@test "git-backup pushes agency state but NEVER .env or key material" {
  git init -q --bare "$WORK/remote.git"
  mkdir -p "$WORK/state"
  printf 'HETZNER_TOKEN=super-secret-value\n' > "$WORK/state/.env"
  printf -- '-----BEGIN PRIVATE KEY-----\n'   > "$WORK/state/id_ed25519"
  printf '{"slug":"acme"}\n'                  > "$WORK/state/registry.jsonl"
  printf '# agency config\n'                  > "$WORK/state/config.md"

  export BACKUP_DIR="$WORK/state" BACKUP_GIT_REMOTE="$WORK/remote.git"
  run "$GB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT-BACKUP-OK"* ]]

  # Inspect EXACTLY what landed in the pushed commit (the proof).
  tree="$(git --git-dir="$WORK/remote.git" ls-tree -r --name-only main)"
  [[ "$tree" == *"registry.jsonl"* ]]   # agency state IS backed up
  [[ "$tree" == *"config.md"* ]]
  [[ "$tree" != *".env"* ]]             # the secret FILE never shipped
  [[ "$tree" != *"id_ed25519"* ]]
  # and the secret VALUE never reached the remote object store
  run git --git-dir="$WORK/remote.git" grep -I "super-secret-value" main
  [ "$status" -ne 0 ]
}

@test "git-backup is a no-op when nothing changed (idempotent)" {
  git init -q --bare "$WORK/remote.git"
  mkdir -p "$WORK/state"; printf 'x\n' > "$WORK/state/a.md"
  export BACKUP_DIR="$WORK/state" BACKUP_GIT_REMOTE="$WORK/remote.git"
  run "$GB"; [ "$status" -eq 0 ]
  run "$GB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT-BACKUP-OK nothing-to-commit"* ]]
}

@test "git-backup refuses to run without a backup remote" {
  mkdir -p "$WORK/state"
  export BACKUP_DIR="$WORK/state"
  unset BACKUP_GIT_REMOTE || true
  run "$GB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* || "$output" == *"BACKUP_GIT_REMOTE"* ]]
}
