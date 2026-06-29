#!/usr/bin/env bash
# The dashboard mint action: provision a CLIENT agent on demand (operator-clicked,
# no Stripe gate). It drives the vendored provisioning chain + the SHIPPED Composio
# session engine:
#
#   1. derive the per-PERSON-email user_id  (installer/scripts/mint-userid.ts;
#      the SHIPPED formula, account slug NEVER enters the hash)
#   2. name the box/URL <person-slug>-<account-slug>.<operator-domain>
#      (the account slug is naming only; blank account => omit the segment)
#   3. append a mint-request line to the queue (NOT a Stripe event)
#   4. provision the Hetzner box  (scripts/provision.sh -> PROVISION-OK ip=<ip>)
#   5. open the Cloudflare gate    (scripts/cf_portal.sh -> PORTAL-READY)
#   6. mint an ISOLATED, rate-limited OpenAI brain for this client and pin it on
#      the box  (installer/scripts/provision-brain-key.ts; project customer-<box>)
#   7. create the Tool Router session bound to that user_id and persist
#      userId -> sessionId  (installer/scripts/mint-session.ts; the SHIPPED store)
#   8. surface the client's onboarding link  (/?user=<id>)
#
# Brain key, Hetzner box, Cloudflare gate, and the session all flow through the
# vendored code. Secrets come ONLY from the loaded env; none is printed (the
# minted brain key lands on the box over ssh and is never echoed). Success
# token (mutation-proven): MINT-OK user_id=<id> ip=<ip>.
#
# --dry-run prints the computed per-email id, the /?user=<id> connect URL, the
# <person>-<account> box name, and the would-be queue line; it touches NOTHING.
#
# Usage: mint_client_agent.sh [--dry-run] --email <e> --person-name <n> [--client-account <a>]
# shellcheck source-path=SCRIPTDIR/..
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/../lib/env.sh"
[ -f "$HERE/../.env" ] && load_env "$HERE/../.env" || true

DRY_RUN=0
EMAIL=""
PERSON_NAME=""
CLIENT_ACCOUNT=""
while [ $# -gt 0 ]; do case "$1" in
  --dry-run) DRY_RUN=1; shift;;
  --email) EMAIL="${2:-}"; shift 2;;
  --person-name) PERSON_NAME="${2:-}"; shift 2;;
  --client-account) CLIENT_ACCOUNT="${2:-}"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

usage() { echo "usage: mint_client_agent.sh [--dry-run] --email <e> --person-name <n> [--client-account <a>]" >&2; }
[ -n "$EMAIL" ] || { echo "ERROR: --email is required" >&2; usage; exit 2; }
[ -n "$PERSON_NAME" ] || { echo "ERROR: --person-name is required" >&2; usage; exit 2; }

# slugify: lowercase, spaces/punct -> single dash, trim leading/trailing dashes.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

PERSON_SLUG="$(slugify "$PERSON_NAME")"
ACCOUNT_SLUG=""
[ -n "$CLIENT_ACCOUNT" ] && ACCOUNT_SLUG="$(slugify "$CLIENT_ACCOUNT")"

# Box/URL name: <person>-<account> when an account is given, else just <person>.
# The account slug is NAMING only; it never enters the user_id hash.
if [ -n "$ACCOUNT_SLUG" ]; then
  BOX_NAME="${PERSON_SLUG}-${ACCOUNT_SLUG}"
else
  BOX_NAME="${PERSON_SLUG}"
fi
DOMAIN="${AGENT_DOMAIN:-example.com}"
BOX_FQDN="${BOX_NAME}.${DOMAIN}"

# Per-PERSON-email user_id via the SHIPPED user-id.ts (no slug in the hash).
INSTALLER="$ROOT/installer"
TSX="${TSX:-npx tsx}"
USER_ID="$($TSX "$INSTALLER/scripts/mint-userid.ts" "$EMAIL")"
[ -n "$USER_ID" ] || { echo "ERROR: failed to derive user_id" >&2; exit 1; }

ONB="${ONBOARDER_BASE_URL:-https://onboarding.${DOMAIN}}"
CONNECT_URL="${ONB%/}/?user=${USER_ID}"

# The queue line is a mint REQUEST (on-demand, operator-clicked), NOT a Stripe
# event. The receiver/processor reads email + person-slug + account-slug; the id
# is reproduced from email downstream, so the binding stays single-sourced.
QUEUE="${CHECKOUT_QUEUE:-$INSTALLER/receiver/checkout-queue.jsonl}"
queue_line() {
  printf '{"at":"%s","source":"operator-mint","email":"%s","personSlug":"%s","accountSlug":"%s","box":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EMAIL" "$PERSON_SLUG" "$ACCOUNT_SLUG" "$BOX_NAME"
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN mint_client_agent for ${EMAIL}"
  echo "user_id=${USER_ID}"
  echo "box=${BOX_NAME}  fqdn=${BOX_FQDN}"
  echo "connect_url=${CONNECT_URL}"
  echo "queue<-${QUEUE}: $(queue_line)"
  echo "would: provision.sh; cf_portal.sh; provision-brain-key (mint isolated brain for customer-${BOX_NAME}, pin on box); mint-session (create+persist userId->sessionId)"
  exit 0
fi

# --- REAL on-demand mint --------------------------------------------------------
require_env HETZNER_TOKEN COMPOSIO_API_KEY

# This CLIENT box needs an ISOLATED, rate-limited brain, which the factory mints with
# the OpenAI Admin key. Check it BEFORE provisioning so a missing key fails clean (no
# half-provisioned, brainless client). The own-box path connects a model by OAuth and
# does not run this script; only the per-client mint does.
if [ -z "${OPENAI_ADMIN_KEY:-}" ]; then
  echo "ERROR: OPENAI_ADMIN_KEY is not set. Set your OpenAI Admin key (sk-admin-...) so the mint" \
    "can provision an isolated, rate-limited brain for this client." >&2
  exit 2
fi

mkdir -p "$(dirname "$QUEUE")"
queue_line >> "$QUEUE"; printf '\n' >> "$QUEUE"

# 1. Provision the box (named for this person/account). MINT_FAKE_IP short-circuits
#    the box IP in tests so no real Hetzner box is ever created.
if [ -n "${MINT_FAKE_IP:-}" ]; then
  IP="$MINT_FAKE_IP"
else
  PROV_OUT="$(AGENT_NAME="$BOX_NAME" "$HERE/provision.sh")"
  IP="$(printf '%s\n' "$PROV_OUT" | sed -n 's/.*PROVISION-OK .*ip=\([0-9.]*\).*/\1/p' | head -1)"
  [ -n "$IP" ] || { echo "ERROR: provision did not return an ip" >&2; exit 1; }
  # 2. Open the Cloudflare gate for this box name.
  AGENT_NAME="$BOX_NAME" "$HERE/cf_portal.sh" >/dev/null || true
fi

# 3. Mint an ISOLATED, rate-limited OpenAI brain for THIS client and pin it on the box
#    (provider openai-api, base_url https://api.openai.com/v1). customerSlug is BOX_NAME,
#    so the project is customer-<BOX_NAME> and the dashboard's per-client spend (keyed on
#    customer-<slug>) ties out. The Admin key stays HERE; only the minted service-account
#    key lands on the box, over ssh, and is NEVER printed. On failure the box is up but
#    brainless and the minted key is rolled back, so re-running is safe.
: "${BRAIN_KEY_CMD:=$TSX $INSTALLER/scripts/provision-brain-key.ts}"
brain_args=(--slug "$BOX_NAME" --ip "$IP")
[ -n "${BRAIN_RPM:-}" ] && brain_args+=(--rpm "$BRAIN_RPM")
[ -n "${BRAIN_TPM:-}" ] && brain_args+=(--tpm "$BRAIN_TPM")
[ -n "${OPENAI_BRAIN_MODEL:-}" ] && brain_args+=(--model "$OPENAI_BRAIN_MODEL")
# shellcheck disable=SC2086
BRAIN_OUT="$($BRAIN_KEY_CMD "${brain_args[@]}")" || {
  echo "ERROR: failed to mint/wire the client brain key (box is brainless; re-run after fixing" \
    "OPENAI_ADMIN_KEY or box reachability)." >&2
  exit 1
}
# Surface ONLY the non-secret refs so the receiver can record the project for offboarding.
BRAIN_PROJECT="$(printf '%s' "$BRAIN_OUT" | sed -n 's/.*"projectId":"\([^"]*\)".*/\1/p')"
BRAIN_SA="$(printf '%s' "$BRAIN_OUT" | sed -n 's/.*"serviceAccountId":"\([^"]*\)".*/\1/p')"

# 4. Create the Tool Router session bound to the per-email user_id and persist
#    userId -> sessionId (the SHIPPED engine; GR2: create once here, expand later).
$TSX "$INSTALLER/scripts/mint-session.ts" "$USER_ID" >/dev/null

echo "Onboarding link for ${PERSON_NAME}: ${CONNECT_URL}"
echo "BRAIN-OK project=${BRAIN_PROJECT} service_account=${BRAIN_SA}"
echo "MINT-OK user_id=${USER_ID} ip=${IP}"
