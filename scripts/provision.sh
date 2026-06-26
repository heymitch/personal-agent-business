#!/usr/bin/env bash
# Create the buyer's always-on Hetzner box with cloud-init.sh as user_data.
# De-tenanted from PAO provision.sh: Hetzner-only, no DO branch, no cosmetics/
# connect-panel injection, no per-client slug or tailnet clobber. One API call.
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

require_env HETZNER_TOKEN AGENT_NAME

NAME="$AGENT_NAME"
SIZE="${HETZNER_SIZE:-cpx21}"        # 3 vCPU / 4GB AMD; US needs the cpx line
REGION="${HETZNER_REGION:-ash}"      # ash=Ashburn US
CURL="${CURL:-curl}"
command -v jq >/dev/null || { echo "jq required (brew install jq)" >&2; exit 2; }

# SSH pubkey: explicit, else auto-detect ed25519 then rsa.
if [ -z "${SSH_PUBKEY:-}" ]; then
  for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$k" ] && { SSH_PUBKEY="$(cat "$k")"; break; }
  done
fi
[ -n "${SSH_PUBKEY:-}" ] || echo "WARN: no SSH pubkey; you won't be able to SSH in (set SSH_PUBKEY)" >&2

# --- SSH key registration ---------------------------------------------------
# Register the pubkey with Hetzner so the server trusts it at first boot.
# Skipped in dry-run mode. Handles the "uniqueness_error" case where the key
# is already registered by matching on type+material (Hetzner strips comments).
KEY_ID=""
KEY_IDS_JSON="[]"
ensure_ssh_key() {
  [ -n "${SSH_PUBKEY:-}" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  local resp
  resp="$($CURL -sS -X POST https://api.hetzner.cloud/v1/ssh_keys \
    -H "Authorization: Bearer $HETZNER_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(jq -nc --arg n "$AGENT_NAME" --arg k "$SSH_PUBKEY" \
      '{name:$n,public_key:$k}')")"
  if echo "$resp" | jq -e '.error.code == "uniqueness_error"' >/dev/null 2>&1; then
    # Key already registered, look it up by type+material (Hetzner strips comments)
    KEY_MATERIAL="$(printf '%s' "$SSH_PUBKEY" | awk '{print $1, $2}')"
    local list_resp
    list_resp="$($CURL -sS -H "Authorization: Bearer $HETZNER_TOKEN" \
      https://api.hetzner.cloud/v1/ssh_keys)"
    KEY_ID="$(printf '%s' "$list_resp" | jq -r \
      --arg mat "$KEY_MATERIAL" \
      '.ssh_keys[] | select((.public_key | split(" ")[:2] | join(" ")) == $mat) | .id')"
  else
    KEY_ID="$(echo "$resp" | jq -r '.ssh_key.id // empty')"
  fi
  if [ -n "$KEY_ID" ]; then KEY_IDS_JSON="[$KEY_ID]"; fi
}
ensure_ssh_key

# cloud-init.sh IS the user_data verbatim (already-rendered student bootstrap).
# Defaults to scripts/cloud-init.sh; CLOUD_INIT_FILE overrides it (tests inject a
# temp stub so they never touch the real file). Checked at runtime, not parse time.
CLOUD_INIT_FILE="${CLOUD_INIT_FILE:-$HERE/cloud-init.sh}"
if [ ! -f "$CLOUD_INIT_FILE" ]; then
  echo "ERROR: $CLOUD_INIT_FILE not found (run Task 4 to generate it, or set CLOUD_INIT_FILE)" >&2
  exit 1
fi
USER_DATA="$(cat "$CLOUD_INIT_FILE")"

BODY="$(jq -nc --arg n "$NAME" --arg t "$SIZE" --arg l "$REGION" --arg u "$USER_DATA" \
  --argjson k "$KEY_IDS_JSON" \
  '{name:$n, server_type:$t, location:$l, image:"ubuntu-24.04", user_data:$u, ssh_keys:$k, start_after_create:true}')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN POST https://api.hetzner.cloud/v1/servers"
  # Print the SAME jq-computed BODY the real call sends, compact, with user_data
  # collapsed to a length descriptor so the (non-secret) cloud-init isn't dumped.
  # The token is never a field in BODY, so it cannot appear here. Test assertions
  # bind to these REAL values: a broken HETZNER_SIZE/jq would surface immediately.
  echo "$BODY" | jq -c '.user_data |= (length | tostring + " bytes")'
  exit 0
fi

resp="$($CURL -sS -X POST https://api.hetzner.cloud/v1/servers \
  -H "Authorization: Bearer $HETZNER_TOKEN" \
  -H "Content-Type: application/json" -d "$BODY")"
if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
  echo "Hetzner error: $(echo "$resp" | jq -c '.error')" >&2; exit 1
fi
id="$(echo "$resp" | jq -r '.server.id')"
ip="$(echo "$resp" | jq -r '.server.public_net.ipv4.ip')"
echo "PROVISION-OK id=$id ip=$ip"

# Persist the box IP so "open my agent" works without the buyer typing anything.
# PROVISION_ENV_FILE overrides the default path (used in tests to avoid touching the real .env).
ENV_FILE="${PROVISION_ENV_FILE:-$HERE/../.env}"
if [ -f "$ENV_FILE" ]; then
  if grep -q "^AGENT_IP=" "$ENV_FILE"; then
    # Update existing line in-place.
    sed -i.bak "s|^AGENT_IP=.*|AGENT_IP=$ip|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    printf '\nAGENT_IP=%s\n' "$ip" >> "$ENV_FILE"
  fi
else
  printf 'AGENT_IP=%s\n' "$ip" > "$ENV_FILE"
fi

echo "Cloud-init runs async (~4-8 min). Watch: ssh root@$ip 'tail -f /var/log/wingman-provision.log' (look for WINGMAN-PROVISION-DONE)"
