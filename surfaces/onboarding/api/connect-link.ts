/** POST { userId, toolkit } -> { redirectUrl }. The page opens redirectUrl so
 *  the buyer OAuths this app on the spot. Connection binds to userId; the agent's
 *  tool-router session (same userId) inherits it. */
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { mintConnectLink } from "../lib/composio.js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const { userId, toolkit } = (req.body ?? {}) as { userId?: string; toolkit?: string };
  if (!userId || !toolkit) return res.status(400).json({ error: "userId and toolkit required" });
  try {
    const redirectUrl = await mintConnectLink(userId, toolkit);
    return res.status(200).json({ redirectUrl });
  } catch (e) {
    return res.status(500).json({ error: e instanceof Error ? e.message : String(e) });
  }
}
