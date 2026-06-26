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
         VERCEL_TOKEN=v SLACK_BOT_TOKEN=sb SLACK_APP_TOKEN=sa SLACK_ALLOWED_USERS=U1
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
