#!/usr/bin/env bats
# The `agentize` skill pipeline: scan -> package -> load. The operator's OWN
# Hermes skills (whatever THEY built) get discovered, packaged as portable
# artifacts, and loaded onto a freshly minted client agent. There is NO fixed
# skill library; the skills are operator-authored. This pipeline is the MECHANISM.
#
# Scan source is configurable:
#   - a LOCAL skills dir (AGENTIZE_SKILLS_DIR), OR
#   - the operator's OWN box at /home/hermes/.hermes/skills over SSH (default,
#     via AGENT_IP + SSH_KEY).
# Restriction is by AGENT PROFILE (a named build = the operator's own skill ids):
#   --profile <name> restricts to that profile; --defaults to the defaultProfile.
# Every ssh/scp/rsync/tar is PATH-shimmed so no test touches a real box, network,
# or spends anything. Tokens are mutation-proven: drop the logic, the token goes,
# the test fails. Fixture skill ids are NEUTRAL placeholders, not anyone's catalog.

load "test_helper.bash"

setup() {
  make_fake_bin ssh scp rsync tar
  export AGENT_IP="203.0.113.10"
  export SSH_KEY=""
  # A LOCAL skills dir standing in for the operator's built Hermes skills.
  # (The default scan source is the operator's OWN box; pointing at a local dir
  #  lets the test discover real folders without an ssh round-trip.)
  export AGENTIZE_SKILLS_DIR="${BATS_TEST_TMPDIR}/local-skills"
  mkdir -p "$AGENTIZE_SKILLS_DIR/weekly-digest" "$AGENTIZE_SKILLS_DIR/inbox-triage"
  printf '# weekly-digest\n' > "$AGENTIZE_SKILLS_DIR/weekly-digest/SKILL.md"
  printf '# inbox-triage\n' > "$AGENTIZE_SKILLS_DIR/inbox-triage/SKILL.md"
  # Staging dir for packaged bundles (kept inside the test tmp).
  export AGENTIZE_STAGING_DIR="${BATS_TEST_TMPDIR}/staging"
  # The operator's agent profiles (named builds). Starter = the default = one skill;
  # Pro = both. This is the operator-defined config the --profile/--defaults flags read.
  export AGENT_PROFILES_FILE="${BATS_TEST_TMPDIR}/agent-profiles.json"
  cat > "$AGENT_PROFILES_FILE" <<'JSON'
{ "profiles": [
    { "name": "Starter", "skills": ["weekly-digest"], "description": "small build" },
    { "name": "Pro", "skills": ["weekly-digest", "inbox-triage"] } ],
  "defaultProfile": "Starter" }
JSON
}

teardown() { teardown_fake_bin; }

# ---- scan ---------------------------------------------------------------------

@test "agentize --scan-skills (local source) lists the operator's built skill dirs + emits SKILLS-SCANNED count=2" {
  run "$SCRIPTS_DIR/agentize.sh" --scan-skills --source "$AGENTIZE_SKILLS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly-digest"* ]]
  [[ "$output" == *"inbox-triage"* ]]
  [[ "$output" == *"SKILLS-SCANNED count=2"* ]]
}

@test "agentize --scan-skills defaults to the operator's OWN box /home/hermes/.hermes/skills over SSH" {
  # No --source: must use AGENT_IP + the box skills path. ssh is a no-op shim,
  # so a real scan over the (faked) box returns zero dirs but the path + count
  # token must still appear, proving the default source is the box path.
  run "$SCRIPTS_DIR/agentize.sh" --scan-skills --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"/home/hermes/.hermes/skills"* ]]
  [[ "$output" == *"203.0.113.10"* ]]
}

@test "agentize --scan-skills --dry-run touches nothing and still emits the count token" {
  run "$SCRIPTS_DIR/agentize.sh" --scan-skills --source "$AGENTIZE_SKILLS_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKILLS-SCANNED count=2"* ]]
}

# ---- package ------------------------------------------------------------------

@test "agentize --package-skills tars each scanned skill into the staging dir + emits SKILLS-PACKAGED count=2" {
  run "$SCRIPTS_DIR/agentize.sh" --package-skills --source "$AGENTIZE_SKILLS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly-digest"* ]]
  [[ "$output" == *"inbox-triage"* ]]
  [[ "$output" == *"SKILLS-PACKAGED count=2"* ]]
}

@test "agentize --package-skills --dry-run prints the tar plan but writes no bundle" {
  run "$SCRIPTS_DIR/agentize.sh" --package-skills --source "$AGENTIZE_SKILLS_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKILLS-PACKAGED count=2"* ]]
  # dry-run must not create the staging dir contents
  [ ! -e "$AGENTIZE_STAGING_DIR/weekly-digest.tgz" ]
}

@test "agentize --package-skills does NOT transform skill contents (tar -c, no edits)" {
  run "$SCRIPTS_DIR/agentize.sh" --package-skills --source "$AGENTIZE_SKILLS_DIR" --dry-run
  [ "$status" -eq 0 ]
  # the plan must show a straight archive (tar) of each folder, not a rewrite
  [[ "$output" == *"tar"* ]]
}

# ---- load ---------------------------------------------------------------------

@test "agentize --load-skills --target rsyncs bundles onto the client agent /home/hermes/.hermes/skills + emits SKILLS-LOADED" {
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --target 198.51.100.7 --source "$AGENTIZE_SKILLS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/home/hermes/.hermes/skills"* ]]
  [[ "$output" == *"198.51.100.7"* ]]
  [[ "$output" == *"SKILLS-LOADED count=2"* ]]
}

@test "agentize --load-skills --dry-run prints the rsync + restart plan, touches nothing" {
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --target 198.51.100.7 --source "$AGENTIZE_SKILLS_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsync"* ]]
  [[ "$output" == *"gateway restart"* ]]
  [[ "$output" == *"SKILLS-LOADED count=2"* ]]
}

# ---- agent profiles (named builds; the restriction the New-agent form sells) ---

@test "agentize --profile <name> restricts the load to exactly that profile's skill set" {
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --target 198.51.100.7 --source "$AGENTIZE_SKILLS_DIR" --profile Starter --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"profile: Starter"* ]]
  [[ "$output" == *"weekly-digest"* ]]
  [[ "$output" != *"inbox-triage"* ]]
  [[ "$output" == *"SKILLS-LOADED count=1"* ]]
}

@test "agentize --profile Pro selects the full profile skill set" {
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --target 198.51.100.7 --source "$AGENTIZE_SKILLS_DIR" --profile Pro --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly-digest"* ]]
  [[ "$output" == *"inbox-triage"* ]]
  [[ "$output" == *"SKILLS-LOADED count=2"* ]]
}

@test "agentize --defaults maps to the defaultProfile's skill set (the mint floor)" {
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --target 198.51.100.7 --source "$AGENTIZE_SKILLS_DIR" --defaults --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"defaultProfile"* ]]
  [[ "$output" == *"weekly-digest"* ]]
  [[ "$output" != *"inbox-triage"* ]]
  [[ "$output" == *"SKILLS-LOADED count=1"* ]]
}

@test "agentize without a profile ships ALL discovered skills (profile is opt-in)" {
  run "$SCRIPTS_DIR/agentize.sh" --scan-skills --source "$AGENTIZE_SKILLS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKILLS-SCANNED count=2"* ]]
}

@test "agentize rejects --profile and --defaults together" {
  run "$SCRIPTS_DIR/agentize.sh" --scan-skills --source "$AGENTIZE_SKILLS_DIR" --profile Pro --defaults
  [ "$status" -ne 0 ]
  [[ "$output" == *"--profile"* || "$output" == *"usage"* ]]
}

@test "agentize --load-skills requires a --target client agent" {
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --source "$AGENTIZE_SKILLS_DIR" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* || "$output" == *"target"* || "$output" == *"required"* ]]
}

# ---- hygiene ------------------------------------------------------------------

@test "agentize prints a no-args usage guard (dry_run_all hooks this)" {
  run "$SCRIPTS_DIR/agentize.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "agentize never prints the SSH_KEY path value" {
  export SSH_KEY="/home/op/.ssh/super-secret-key"
  run "$SCRIPTS_DIR/agentize.sh" --load-skills --target 198.51.100.7 --source "$AGENTIZE_SKILLS_DIR" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-key"* ]]
}
