#!/usr/bin/env bash
# Exercise the full chain at zero cost: every script's --dry-run, in order.
# It touches no real API, spends no money, and prints no secret value. The token
# at the end is the contract: the agent greps for the EXACT string to confirm the
# whole preview ran clean.
#
# The money/infra-touching scripts (provision, cf_portal, cf_ssh) have a --dry-run
# API path. The SSH-only scripts (install_connector/configure_box/move_up) need a
# live box IP, so they are arg-validated here via their no-args usage guard.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== provision.sh --dry-run =="
"$HERE/provision.sh" --dry-run

echo "== cf_portal.sh --dry-run =="
"$HERE/cf_portal.sh" --dry-run

echo "== cf_ssh.sh --dry-run =="
"$HERE/cf_ssh.sh" --dry-run

# install_connector / configure_box / move_up have no --dry-run API path. They are
# arg-validated via their no-args usage guard. This MUST be teethy: capture the
# output, then assert "usage" with a form that EXITS NON-ZERO when the guard is
# missing. A bare `grep -q ... && echo` would be the LHS of `&&`, which errexit
# exempts, so a dropped guard would slip through. The explicit `|| { ...; exit 1; }`
# makes a regression abort dry_run_all.sh.
for s in install_connector.sh configure_box.sh move_up.sh; do
  echo "== $s (arg check) =="
  out="$( { "$HERE/$s" 2>&1 || true; } )"
  printf '%s\n' "$out" | grep -q "usage" \
    || { echo "FAIL: $s did not print its usage/arg guard" >&2; exit 1; }
  echo "  usage-guarded OK"
done

echo "DRY-RUN-ALL-OK"
