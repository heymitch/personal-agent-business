#!/usr/bin/env bash
# Shared bats helper: locate the repo root and the dirs every test reaches into.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export SCRIPTS_DIR="$REPO_ROOT/scripts"
export LIB_DIR="$REPO_ROOT/lib"

# Make a throwaway PATH-shimmed bin dir for fake curl/ssh/jq/cloudflared.
make_fake_bin() {
  mkdir -p "$REPO_ROOT/test/tmp"
  FAKE_BIN="$(mktemp -d "$REPO_ROOT/test/tmp/fakebin.XXXXXX")"
  export FAKE_BIN
  export PATH="$FAKE_BIN:$PATH"
}
teardown_fake_bin() { [ -n "${FAKE_BIN:-}" ] && rm -rf "$FAKE_BIN"; }
