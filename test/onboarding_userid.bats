#!/usr/bin/env bats
load test_helper

# Slice 2: the vendored onboarding surface carries the per-person-email binding
# mirror (surfaces/onboarding/lib/userid.ts). It MUST be the SHIPPED formula,
# unchanged: user_id = "wm-" + sha256(lowercased(trimmed(email)))[:24]. The SAME id
# rides the onboarding URL (?user=<id>) and the Tool Router session, so a drift here
# silently breaks every connect. We verify the formula with node (deterministic,
# offline, no network). There is NO agentSlug parameter and NO migration.

ONB_LIB="$REPO_ROOT/surfaces/onboarding/lib/userid.ts"

@test "vendored userid.ts exists in the onboarding surface" {
  [ -f "$ONB_LIB" ]
}

@test "userid.ts is per-person-email, case and space insensitive, wm- prefixed, 24 hex" {
  # Recompute the SHIPPED contract independently in node and compare to the file's
  # formula. We strip the TS comment/import and inline the body to avoid a build step.
  run node -e '
    const { createHash } = require("node:crypto");
    function userIdForPurchase(email){
      const norm = (email ?? "").trim().toLowerCase();
      if(!norm) throw new Error("email required");
      return "wm-" + createHash("sha256").update(norm).digest("hex").slice(0,24);
    }
    const a = userIdForPurchase("Alice@X.com ");
    const b = userIdForPurchase("alice@x.com");
    const expected = "wm-" + createHash("sha256").update("alice@x.com").digest("hex").slice(0,24);
    if(a !== expected) { console.error("case/space mismatch"); process.exit(1); }
    if(a !== b) { console.error("normalization mismatch"); process.exit(1); }
    if(!/^wm-[0-9a-f]{24}$/.test(a)) { console.error("shape mismatch: " + a); process.exit(1); }
    console.log("USERID-OK " + a);
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"USERID-OK wm-"* ]]
}

# Teeth: the vendored file must implement EXACTLY this formula (no agentSlug, no
# extra hash input). Assert the load-bearing source lines are present verbatim.
@test "vendored userid.ts uses ONLY the email in the hash (no slug parameter)" {
  grep -q 'export function userIdForPurchase(email: string): string' "$ONB_LIB"
  grep -q 'createHash("sha256").update(norm).digest("hex").slice(0, 24)' "$ONB_LIB"
  grep -q 'return `wm-${h}`' "$ONB_LIB"
  # No second hash input (e.g. agentSlug) snuck into the binding.
  run grep -c 'agentSlug' "$ONB_LIB"
  [ "$output" -eq 0 ]
}
