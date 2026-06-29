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

  # The brain-mint step (provision-brain-key) talks to OpenAI + ssh, so shim it: a
  # recorder that captures its args and prints a NON-secret summary JSON exactly like
  # the real CLI (so the mint script's BRAIN-OK parse works). No real key is ever minted.
  BRAIN_REC="$REPO_ROOT/test/tmp/brain-rec-$$.txt"
  export BRAIN_REC
  rm -f "$BRAIN_REC"
  cat > "$FAKE_BIN/fake-brain" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BRAIN_REC"
echo '{"ok":true,"customerSlug":"x","projectId":"proj_fake","serviceAccountId":"svc_fake","model":"gpt-5.5","rateLimited":true}'
EOF
  chmod +x "$FAKE_BIN/fake-brain"
  export BRAIN_KEY_CMD="$FAKE_BIN/fake-brain"
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
  # the per-client brain was minted + pinned, and only the non-secret refs surfaced
  [[ "$output" == *"BRAIN-OK project=proj_fake service_account=svc_fake"* ]]
  # the userId -> sessionId binding was persisted via the SHIPPED session store
  [ -f "$store" ]
  run grep -F "trs_faked_123" "$store"
  [ "$status" -eq 0 ]
  run grep -oE 'wm-[0-9a-f]{24}' "$store"
  [ "$status" -eq 0 ]
}

@test "mint mints an ISOLATED brain for the per-account slug and pins it on the box ip" {
  # The brain step must run with customerSlug = the box slug (so the project becomes
  # customer-<slug> and the dashboard ties out) and the provisioned box ip.
  export MINT_FAKE_IP="203.0.113.55"
  export MINT_FAKE_SESSION_ID="trs_faked_123"
  run "$SCRIPTS_DIR/mint_client_agent.sh" \
    --email "client@x.com" --client-account "acme" --person-name "Dana"
  [ "$status" -eq 0 ]
  # the brain-mint CLI was invoked with the per-client slug + box ip
  run grep -F -- "--slug dana-acme" "$BRAIN_REC"
  [ "$status" -eq 0 ]
  run grep -F -- "--ip 203.0.113.55" "$BRAIN_REC"
  [ "$status" -eq 0 ]
}

@test "mint never prints the admin key while minting the brain" {
  export MINT_FAKE_IP="203.0.113.55"
  export MINT_FAKE_SESSION_ID="trs_faked_123"
  run "$SCRIPTS_DIR/mint_client_agent.sh" \
    --email "client@x.com" --client-account "acme" --person-name "Dana"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sk-admin-fake"* ]]
}

@test "mint fails clean with a clear message when OPENAI_ADMIN_KEY is unset (no half-provisioned client)" {
  unset OPENAI_ADMIN_KEY
  export MINT_FAKE_IP="203.0.113.55"   # would short-circuit provisioning IF we got that far
  run "$SCRIPTS_DIR/mint_client_agent.sh" \
    --email "client@x.com" --client-account "acme" --person-name "Dana"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OPENAI_ADMIN_KEY"* ]]
  [[ "$output" == *"Admin key"* ]]
  # the brain step was never reached (no box, no mint)
  [ ! -s "$BRAIN_REC" ]
}
