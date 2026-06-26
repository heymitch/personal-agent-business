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

echo "== deploy_surfaces.sh --dry-run =="
"$HERE/deploy_surfaces.sh" --dry-run

echo "== mint_client_agent.sh --dry-run =="
# The on-demand mint action. Dry-run derives the per-email user_id (via the
# vendored user-id.ts), the <person>-<account> box name, and the connect URL.
# It touches no API and spends nothing; sample args drive the preview.
"$HERE/mint_client_agent.sh" --dry-run --email "preview@example.com" --person-name "Preview" --client-account "demo" >/dev/null

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

# deploy_engine needs a live box IP (AGENT_IP). With none set, even --dry-run must
# print its usage guard rather than touch anything. Same teethy form as above.
echo "== deploy_engine.sh (arg check, no AGENT_IP) =="
out="$( { env -u AGENT_IP "$HERE/deploy_engine.sh" --dry-run 2>&1 || true; } )"
printf '%s\n' "$out" | grep -q "usage" \
  || { echo "FAIL: deploy_engine.sh did not print its usage/arg guard" >&2; exit 1; }
echo "  usage-guarded OK"

# deploy_maintenance installs the two DAILY timers and likewise needs a live box
# IP. With none set, even --dry-run must print its usage guard. Same teethy form.
echo "== deploy_maintenance.sh (arg check, no AGENT_IP) =="
out="$( { env -u AGENT_IP "$HERE/deploy_maintenance.sh" --dry-run 2>&1 || true; } )"
printf '%s\n' "$out" | grep -q "usage" \
  || { echo "FAIL: deploy_maintenance.sh did not print its usage/arg guard" >&2; exit 1; }
echo "  usage-guarded OK"

# agentize --scan-skills defaults to the operator's OWN box (AGENT_IP). With none
# set it must error rather than touch anything; pointing it at the in-repo
# operator-skills/ template dir gives a clean, network-free dry-run preview that
# still emits the SKILLS-SCANNED token. Teethy: a missing token aborts.
echo "== agentize.sh --scan-skills --dry-run (operator-skills template source) =="
out="$( { "$HERE/agentize.sh" --scan-skills --source "$HERE/../operator-skills" --dry-run 2>&1 || true; } )"
printf '%s\n' "$out" | grep -q "SKILLS-SCANNED count=" \
  || { echo "FAIL: agentize.sh --scan-skills did not emit its SKILLS-SCANNED token" >&2; exit 1; }
echo "  scan-preview OK"

echo "DRY-RUN-ALL-OK"
