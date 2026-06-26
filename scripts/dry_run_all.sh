#!/usr/bin/env bash
# Exercise the full chain at zero cost: every script's --dry-run, in order.
# It touches no real API, spends no money, and prints no secret value.
#
# Slice 0: there are no provisioning/deploy/mint scripts to chain yet. Later
# slices add their own `--dry-run` calls (provision, cf_portal, deploy_surfaces,
# mint_client_agent) ABOVE the final token line. The token is the contract: the
# agent greps for the EXACT string to confirm the whole preview ran clean.
set -euo pipefail

echo "DRY-RUN-ALL-OK"
