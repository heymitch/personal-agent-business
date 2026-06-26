/**
 * Map a Slack identity to the Composio `user_id` (the multi-tenant isolation
 * key: one operator Composio account, connections isolated per user). The id
 * must be deterministic so the same Slack human always resolves to the same
 * Composio connections.
 */
export function composioUserId(opts: { teamId: string; slackUserId: string }): string {
  if (!opts.teamId) throw new Error("composioUserId: teamId is required");
  if (!opts.slackUserId) throw new Error("composioUserId: slackUserId is required");
  return `slack-${opts.teamId}-${opts.slackUserId}`;
}

/**
 * THE BINDING: derive the Composio `user_id` from a purchase (the buyer's
 * email). This SAME id must flow to BOTH (a) the onboarding page URL
 * (`/?user=<id>`, where the buyer OAuths their apps) and (b) the agent's
 * Tool Router session (created with `--user <id>`). Match them and the agent
 * inherits every connection the buyer made on the page. Mirror of
 * `onboarding/lib/userid.ts`; keep the two byte-for-byte identical.
 *
 * Deterministic (same email -> same id always), URL-safe, and no PII in the URL
 * (it is a hash, not the raw email).
 */
import { createHash } from "node:crypto";

export function userIdForPurchase(email: string): string {
  const norm = (email ?? "").trim().toLowerCase();
  if (!norm) throw new Error("userIdForPurchase: email is required");
  const h = createHash("sha256").update(norm).digest("hex").slice(0, 24);
  return `wm-${h}`;
}
