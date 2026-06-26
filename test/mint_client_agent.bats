#!/usr/bin/env bats
# The dashboard mint action: provision a CLIENT agent through the vendored
# provisioning chain + the SHIPPED Composio session engine. Every external call
# (curl/ssh/Hetzner/Composio/Vercel/the OpenAI admin mint) is PATH-shimmed to a
# no-op so no test spends money or touches a real box/API. The assertions bind to
# the CONSTRUCTED values: the per-EMAIL user_id, the <person>-<account> box name,
# the /?user= connect URL, the persisted session.

load "test_helper.bash"

setup() {
  # tsx is the real binary (it runs the vendored user-id.ts to derive the id);
  # curl/ssh/scp/cloudflared/vercel are no-op shims. jq passes through.
  make_fake_bin curl ssh scp cloudflared vercel jq
  export COMPOSIO_API_KEY="ck-fake"
  export ONBOARDER_BASE_URL="https://onb.example.com"
  export AGENT_DOMAIN="op.example.com"
  export HETZNER_TOKEN="fake-token-987654321"
  export OPENAI_ADMIN_KEY="sk-admin-fake"
  export CLOUDFLARE_API_TOKEN="cf-fake" CLOUDFLARE_ACCOUNT_ID="acct-fake" OWNER_EMAIL="op@x.com"
}

teardown() { teardown_fake_bin; }

@test "mint --dry-run computes per-email user_id + connect URL + slug-named box, spends nothing" {
  run "$SCRIPTS_DIR/mint_client_agent.sh" --dry-run \
    --email "client@x.com" --client-account "acme" --person-name "Dana"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wm-"* ]]
  [[ "$output" == *"/?user=wm-"* ]]
  [[ "$output" == *"dana-acme"* ]]            # slug names the box/URL only
}

@test "mint derives the per-email user_id from the SHIPPED user-id.ts (no slug in the hash)" {
  # The same email under DIFFERENT accounts must yield the SAME user_id.
  run "$SCRIPTS_DIR/mint_client_agent.sh" --dry-run \
    --email "Dana@X.com" --client-account "acme" --person-name "Dana"
  [ "$status" -eq 0 ]
  id_a="$(printf '%s\n' "$output" | grep -oE 'wm-[0-9a-f]{24}' | head -1)"

  run "$SCRIPTS_DIR/mint_client_agent.sh" --dry-run \
    --email "dana@x.com " --client-account "beta" --person-name "Dana"
  [ "$status" -eq 0 ]
  id_b="$(printf '%s\n' "$output" | grep -oE 'wm-[0-9a-f]{24}' | head -1)"

  [ -n "$id_a" ]
  [ "$id_a" = "$id_b" ]                         # account slug never enters the hash
}

@test "mint omits the account segment when --client-account is blank" {
  run "$SCRIPTS_DIR/mint_client_agent.sh" --dry-run \
    --email "dana@x.com" --person-name "Dana"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dana"* ]]
  [[ "$output" != *"dana-."* ]]                # no dangling separator when account omitted
}

@test "mint --dry-run never prints a secret value" {
  run "$SCRIPTS_DIR/mint_client_agent.sh" --dry-run \
    --email "client@x.com" --client-account "acme" --person-name "Dana"
  [ "$status" -eq 0 ]
  [[ "$output" != *"fake-token-987654321"* ]]
  [[ "$output" != *"ck-fake"* ]]
  [[ "$output" != *"sk-admin-fake"* ]]
}

@test "mint requires --email and --person-name" {
  run "$SCRIPTS_DIR/mint_client_agent.sh" --dry-run --client-account "acme"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* || "$output" == *"required"* ]]
}

@test "mint (full run, all externals shimmed) emits MINT-OK + persists userId->sessionId" {
  # No --dry-run: the provisioning chain runs end-to-end against PATH-shimmed
  # binaries, so nothing real is touched. The session store is redirected to a
  # temp file we then assert on.
  store="$REPO_ROOT/test/tmp/mint-store-$$.json"
  rm -f "$store"
  export SESSION_STORE_FILE="$store"
  export MINT_FAKE_IP="203.0.113.55"           # the shimmed provision returns this
  export MINT_FAKE_SESSION_ID="trs_faked_123"  # the shimmed session create returns this
  run "$SCRIPTS_DIR/mint_client_agent.sh" \
    --email "client@x.com" --client-account "acme" --person-name "Dana"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MINT-OK"* ]]
  [[ "$output" == *"user_id=wm-"* ]]
  [[ "$output" == *"ip=203.0.113.55"* ]]
  # the userId -> sessionId binding was persisted via the SHIPPED session store
  [ -f "$store" ]
  run grep -F "trs_faked_123" "$store"
  [ "$status" -eq 0 ]
  run grep -oE 'wm-[0-9a-f]{24}' "$store"
  [ "$status" -eq 0 ]
}
