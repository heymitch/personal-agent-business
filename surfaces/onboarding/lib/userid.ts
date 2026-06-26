/**
 * THE BINDING (mirror of installer/src/connect/user-id.ts, keep identical).
 * Derive the Composio `user_id` from the buyer's email. The SAME id must be in
 * BOTH the onboarding page URL (`/?user=<id>`) and the agent's Tool Router
 * session (`--user <id>`). Match them and the agent inherits the buyer's
 * on-page connections. Deterministic, URL-safe, hashed (no PII in the URL).
 */
import { createHash } from "node:crypto";

export function userIdForPurchase(email: string): string {
  const norm = (email ?? "").trim().toLowerCase();
  if (!norm) throw new Error("userIdForPurchase: email is required");
  const h = createHash("sha256").update(norm).digest("hex").slice(0, 24);
  return `wm-${h}`;
}
