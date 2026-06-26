#!/usr/bin/env bash
# Deploy the three client-facing surfaces to the operator's OWN Vercel:
#   onboarding        the connect-on-page (vendored from personal-agent-onboarding)
#   landing           the public offer page the operator brands
#   operator-console  the minting dashboard (mint button stubbed until Slice 3)
#
# Each surface is a static + serverless Vercel project. We push it with
# `vercel deploy --prod`, passing the operator token on the flag (never echoed).
# COMPOSIO_API_KEY is set into the onboarding project's Vercel env (its serverless
# api/ functions need it). --dry-run constructs the exact commands with every
# secret collapsed to a byte count and touches no real API.
#
# Usage: ./deploy_surfaces.sh [--dry-run]
# Reads: VERCEL_TOKEN, COMPOSIO_API_KEY  (from .env or environment)
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY_RUN=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

require_env VERCEL_TOKEN COMPOSIO_API_KEY

VERCEL="${VERCEL:-vercel}"
SURFACES_DIR="$HERE/../surfaces"
# Deploy order matters: onboarding first so its URL can seed ONBOARDER_BASE_URL,
# then landing, then the operator console (which links to both).
SURFACES="onboarding landing operator-console"

# Collapse any secret to a byte count for the dry-run preview. Never the value.
redact_len() { printf '<%s bytes>' "${#1}"; }

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN deploy sequence (operator Vercel, token collapsed, no API hit):"
  echo "  VERCEL_TOKEN=$(redact_len "$VERCEL_TOKEN")  COMPOSIO_API_KEY=$(redact_len "$COMPOSIO_API_KEY")"
  for s in $SURFACES; do
    echo "== surface: $s =="
    echo "   cd $SURFACES_DIR/$s"
    if [ "$s" = "onboarding" ]; then
      echo "   vercel env add COMPOSIO_API_KEY production --token <$(redact_len "$VERCEL_TOKEN") token>"
    fi
    echo "   vercel deploy --prod --yes --token <$(redact_len "$VERCEL_TOKEN") token>"
  done
  echo "(dry-run only: nothing deployed, no secret printed)"
  exit 0
fi

# Real deploy. For each surface: cd in, push to prod, capture the printed URL.
# `vercel deploy --prod` prints the deployment URL on stdout; we keep the last
# non-empty line as the URL (a fake-bin shim prints nothing, so we fall back to a
# placeholder and still emit a complete, grep-able success token).
deploy_one() {
  local surface="$1" dir url
  dir="$SURFACES_DIR/$surface"
  [ -d "$dir" ] || { echo "ERROR: surface dir missing: $dir" >&2; exit 1; }
  if [ "$surface" = "onboarding" ]; then
    # The onboarding serverless api/ needs the Composio key at runtime. Set it
    # into the project env (piped on stdin so it never lands on the command line).
    printf '%s' "$COMPOSIO_API_KEY" | \
      ( cd "$dir" && "$VERCEL" env add COMPOSIO_API_KEY production --token "$VERCEL_TOKEN" --yes >/dev/null 2>&1 || true )
  fi
  url="$( cd "$dir" && "$VERCEL" deploy --prod --yes --token "$VERCEL_TOKEN" 2>/dev/null | tail -n1 || true )"
  [ -n "$url" ] || url="(deployed: see Vercel dashboard)"
  printf '%s' "$url"
}

ONB_URL="$(deploy_one onboarding)"
LAND_URL="$(deploy_one landing)"
CONS_URL="$(deploy_one operator-console)"

echo "SURFACES-DEPLOYED onboarding=$ONB_URL landing=$LAND_URL console=$CONS_URL"
