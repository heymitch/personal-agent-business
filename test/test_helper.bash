#!/usr/bin/env bash
# Shared bats helper: locate the repo root and the dirs every test reaches into.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export SCRIPTS_DIR="$REPO_ROOT/scripts"
export LIB_DIR="$REPO_ROOT/lib"

# Make a throwaway PATH-shimmed bin dir and (optionally) drop fake binaries into
# it so no test ever touches a real API or box. Pass the command names to shim:
#   make_fake_bin curl jq ssh
#
# Shim behaviour:
#   - jq is a PASS-THROUGH to the real jq (dry-run paths build their request body
#     with real jq; faking it would defeat the assertion that the body is correct).
#   - every other named command is a no-op recorder: it exits 0, prints nothing,
#     and is therefore safe to "call" from a dry-run that should spend no money.
# A real network/SSH call routed through one of these shims is a silent no-op,
# so a test that accidentally leaves the dry-run guard can never reach a real API.
make_fake_bin() {
  mkdir -p "$REPO_ROOT/test/tmp"
  FAKE_BIN="$(mktemp -d "$REPO_ROOT/test/tmp/fakebin.XXXXXX")"
  export FAKE_BIN
  local cmd real
  for cmd in "$@"; do
    if [ "$cmd" = "jq" ]; then
      # Resolve the real jq BEFORE we shadow it on PATH, then delegate to it.
      real="$(command -v jq || true)"
      [ -n "$real" ] || { echo "make_fake_bin: real jq not found (brew install jq)" >&2; return 1; }
      printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real" > "$FAKE_BIN/jq"
    else
      # No-op recorder: succeeds, emits nothing. Never reaches a real endpoint.
      printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BIN/$cmd"
    fi
    chmod +x "$FAKE_BIN/$cmd"
  done
  export PATH="$FAKE_BIN:$PATH"
}
teardown_fake_bin() { [ -n "${FAKE_BIN:-}" ] && rm -rf "$FAKE_BIN"; }
