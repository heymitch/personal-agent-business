#!/usr/bin/env bats
# /doctor: a READ-ONLY health check. It reports each component PASS/FAIL, never
# prints a secret value, mutates nothing, and is safe to re-run (idempotent).
# Every probe (ssh/curl) is PATH-shimmed so no test touches a real box or URL.

load "test_helper.bash"

teardown() { teardown_fake_bin; }

# A complete, healthy operator env: all required keys + a reachable box + a
# deployed surface URL. With the probes shimmed to succeed, every check passes.
healthy_env() {
  export HETZNER_TOKEN=h OPENAI_BASE_URL=u BRAIN_MODEL=m AGENTMAIL_API_KEY=a \
         AGENTMAIL_INBOX=i COMPOSIO_API_KEY=c CLOUDFLARE_API_TOKEN=ct \
         CLOUDFLARE_ACCOUNT_ID=ca AGENT_DOMAIN=op.example.com OWNER_EMAIL=o@x.com \
         SLACK_BOT_TOKEN=sb SLACK_APP_TOKEN=sa SLACK_ALLOWED_USERS=U1
  export AGENT_IP="203.0.113.10" ONBOARDER_BASE_URL="https://onb.op.example.com"
}

@test "doctor reports the missing box as a NAMED failure, not a crash" {
  make_fake_bin curl ssh
  export AGENT_IP="" AGENT_DOMAIN="op.example.com"
  run "$SCRIPTS_DIR/doctor.sh"
  [[ "$output" == *"DOCTOR-FAIL"* ]]
  [[ "$output" == *"component=box"* ]]
}

@test "doctor checks all four components by name" {
  make_fake_bin curl ssh
  run "$SCRIPTS_DIR/doctor.sh"
  [[ "$output" == *"keys"* ]]
  [[ "$output" == *"box"* ]]
  [[ "$output" == *"engine"* ]]
  [[ "$output" == *"surfaces"* ]]
}

@test "doctor never prints a secret value" {
  make_fake_bin curl ssh
  export HETZNER_TOKEN="super-secret-hetzner" AGENT_IP="203.0.113.10"
  run "$SCRIPTS_DIR/doctor.sh"
  [[ "$output" != *"super-secret-hetzner"* ]]
}

@test "doctor is read-only and idempotent: two clean runs both emit DOCTOR-OK" {
  make_fake_bin curl ssh
  healthy_env
  run "$SCRIPTS_DIR/doctor.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"DOCTOR-OK"* ]]
  run "$SCRIPTS_DIR/doctor.sh"; [ "$status" -eq 0 ]; [[ "$output" == *"DOCTOR-OK"* ]]
}

# Fix 7: the proxied-Vercel origin pull needs zone SSL mode = Full. doctor runs an ADVISORY
# ssl check that flags when it cannot confirm Full -- but it must NEVER flip the verdict
# (the token may lack Zone Settings:Read), so a healthy run still emits DOCTOR-OK.
@test "doctor runs an advisory SSL-mode check that never flips the verdict" {
  make_fake_bin curl ssh
  healthy_env
  run "$SCRIPTS_DIR/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCTOR-OK"* ]]
  [[ "$output" == *"ssl"* ]]
  [[ "$output" != *"component=ssl"* ]]
}

# Fix 6: a just-created hostname can fail ONLY because the local resolver still holds the
# pre-creation NXDOMAIN. doctor must re-check by bypassing the local cache (Cloudflare DoH
# + curl --resolve) and, if that responds, report a local-cache artifact, NOT a failure.
@test "doctor treats a local-cache-only DNS miss as an artifact, not a surface failure" {
  make_fake_bin ssh   # box/engine probes succeed
  # Custom curl: the local-resolver GET fails, Cloudflare DoH returns an IP, and the pinned
  # --resolve re-check succeeds -> a local DNS cache lag, not an outage.
  cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
args="$*"
if printf '%s' "$args" | grep -q 'cloudflare-dns.com'; then echo '{"Answer":[{"type":1,"data":"104.21.0.1"}]}'; exit 0; fi
if printf '%s' "$args" | grep -q -- '--resolve'; then exit 0; fi
exit 6
SH
  chmod +x "$FAKE_BIN/curl"
  healthy_env
  run "$SCRIPTS_DIR/doctor.sh"
  [[ "$output" == *"[PASS] surfaces"* ]]
  [[ "$output" == *"local-only artifact"* ]]
}
