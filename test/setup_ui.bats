#!/usr/bin/env bats
load test_helper

# ---------------------------------------------------------------------------
# Smoke tests for setup-ui/server.py
# Uses a temp COCKPIT_DIR so nothing touches the real .env, and a dynamic
# free port (the server picks one and prints SETUP_URL=).
#
# setup_file/teardown_file run once for the whole file (bats >= 1.5).
# setup_file runs in its own subprocess; REPO_ROOT from load is NOT available
# there, so we derive the root from BATS_TEST_DIRNAME.
# ---------------------------------------------------------------------------

setup_file() {
  local _root
  _root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  TEMP_COCKPIT="$(mktemp -d)"
  export TEMP_COCKPIT

  cp "$_root/.env.example" "$TEMP_COCKPIT/.env.example"

  export COCKPIT_DIR="$TEMP_COCKPIT"
  export SETUP_TOKEN="smoke-test-token-xyz"
  # Do NOT set SETUP_PORT -- let the server pick a free port automatically.

  python3 "$_root/setup-ui/server.py" >"$TEMP_COCKPIT/server.log" 2>&1 &
  export SETUP_SERVER_PID=$!

  # Wait up to 8 seconds for the server to print SETUP_URL= to its log.
  local i=0
  local setup_url=""
  while [ "$i" -lt 80 ]; do
    setup_url="$(grep -m1 '^SETUP_URL=' "$TEMP_COCKPIT/server.log" 2>/dev/null || true)"
    if [ -n "$setup_url" ]; then break; fi
    sleep 0.1
    i=$((i + 1))
  done

  # Parse the dynamic port from SETUP_URL=http://127.0.0.1:<port>/...
  TEST_PORT="$(echo "$setup_url" | sed 's|.*://127\.0\.0\.1:\([0-9]*\)/.*|\1|')"
  export TEST_PORT
}

teardown_file() {
  if [ -n "${SETUP_SERVER_PID:-}" ]; then
    kill "$SETUP_SERVER_PID" 2>/dev/null || true
    wait "$SETUP_SERVER_PID" 2>/dev/null || true
  fi
  [ -n "${TEMP_COCKPIT:-}" ] && rm -rf "$TEMP_COCKPIT"
}

setup() {
  rm -f "$TEMP_COCKPIT/.env"
}

@test "server bound to a dynamic free port (SETUP_URL printed)" {
  [ -n "$TEST_PORT" ]
  [ "$TEST_PORT" -gt 0 ]
}

# ---- (a) untokened request returns 403 -- teeth test ----------------------
@test "GET /api/schema without token returns 403" {
  HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:$TEST_PORT/api/schema")"
  [ "$HTTP_CODE" = "403" ]
}

# ---- (b) tokened GET /api/schema returns groups ---------------------------
# Vercel auth is a Claude Code connection (`vercel login`), so VERCEL_TOKEN is no
# longer a collected field. AgentMail stays in the schema but is now OPTIONAL.
@test "GET /api/schema with token returns schema groups for operator keys" {
  OUT="$(curl -s "http://127.0.0.1:$TEST_PORT/api/schema?t=$SETUP_TOKEN")"
  echo "$OUT" | grep -q '"groups"'
  echo "$OUT" | grep -q '"HETZNER_TOKEN"'
  echo "$OUT" | grep -q '"COMPOSIO_API_KEY"'
  echo "$OUT" | grep -q '"AGENTMAIL_API_KEY"'
}

# ---- (c) POST /api/save writes keys to the temp .env ----------------------
@test "POST /api/save writes submitted keys to .env" {
  OUT="$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"AGENT_DOMAIN":"my-agents.com","OWNER_EMAIL":"smoke@example.com"}' \
    "http://127.0.0.1:$TEST_PORT/api/save?t=$SETUP_TOKEN")"
  echo "$OUT" | grep -q '"saved"'
  [ -f "$TEMP_COCKPIT/.env" ]
  grep -q "AGENT_DOMAIN=my-agents.com" "$TEMP_COCKPIT/.env"
  grep -q "OWNER_EMAIL=smoke@example.com" "$TEMP_COCKPIT/.env"
}

# ---- secret-no-reserve: after saving a secret, schema does NOT echo it ----
@test "GET /api/schema does not return raw secret value after save" {
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"HETZNER_TOKEN":"super-secret-hunter2"}' \
    "http://127.0.0.1:$TEST_PORT/api/save?t=$SETUP_TOKEN" >/dev/null

  OUT="$(curl -s "http://127.0.0.1:$TEST_PORT/api/schema?t=$SETUP_TOKEN")"
  if echo "$OUT" | grep -q "super-secret-hunter2"; then
    echo "FAIL: raw secret leaked into schema response" >&2
    return 1
  fi
  echo "$OUT" | grep -q '"is_set": true\|"is_set":true'
}

# ---- injection guard: unknown keys are rejected, not written --------------
@test "POST /api/save rejects unknown keys" {
  OUT="$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"EVIL_KEY":"injected","AGENT_DOMAIN":"safe.com"}' \
    "http://127.0.0.1:$TEST_PORT/api/save?t=$SETUP_TOKEN")"
  echo "$OUT" | grep -q '"rejected"'
  echo "$OUT" | grep -q "EVIL_KEY"
  if [ -f "$TEMP_COCKPIT/.env" ]; then
    if grep -q "EVIL_KEY" "$TEMP_COCKPIT/.env"; then
      echo "FAIL: EVIL_KEY was written to .env" >&2
      return 1
    fi
  fi
}

# ---- required check flags blank operator keys -----------------------------
@test "POST /api/save reports blank operator keys in missing_required" {
  OUT="$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"AGENT_DOMAIN":"my-agents.com"}' \
    "http://127.0.0.1:$TEST_PORT/api/save?t=$SETUP_TOKEN")"
  echo "$OUT" | grep -q '"missing_required"'
  if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'HETZNER_TOKEN' in d.get('missing_required',[]) else 1)"; then
    : # pass
  else
    echo "FAIL: HETZNER_TOKEN not flagged as missing when blank" >&2
    return 1
  fi
}

# ---- SSH keypair generation -----------------------------------------------
@test "POST /api/generate-ssh without token returns 403" {
  HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://127.0.0.1:$TEST_PORT/api/generate-ssh")"
  [ "$HTTP_CODE" = "403" ]
}

@test "POST /api/generate-ssh writes SSH_PUBKEY, never returns private key material" {
  local FAKE_SSH_DIR
  FAKE_SSH_DIR="$(mktemp -d)"
  HOME="$FAKE_SSH_DIR" OUT="$(curl -s -X POST \
    "http://127.0.0.1:$TEST_PORT/api/generate-ssh?t=$SETUP_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{}')"

  echo "$OUT" | grep -q '"ok": true\|"ok":true'
  echo "$OUT" | grep -q '"path"'
  echo "$OUT" | grep -q '"fingerprint"'

  [ -f "$TEMP_COCKPIT/.env" ]
  grep -q "^SSH_PUBKEY=" "$TEMP_COCKPIT/.env"

  if echo "$OUT" | grep -q -- "-----BEGIN"; then
    echo "FAIL: private key material leaked into response" >&2
    rm -rf "$FAKE_SSH_DIR"
    return 1
  fi

  rm -rf "$FAKE_SSH_DIR"
}
