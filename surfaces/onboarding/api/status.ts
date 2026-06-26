/** GET ?userId=... -> { connected: ["gmail", ...] }. The page polls this to
 *  tick the checklist as each OAuth completes. */
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { connectedToolkits } from "../lib/composio.js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const userId = (req.query.userId as string) || "";
  if (!userId) return res.status(400).json({ error: "userId required" });
  try {
    return res.status(200).json({ connected: await connectedToolkits(userId) });
  } catch (e) {
    return res.status(500).json({ error: e instanceof Error ? e.message : String(e) });
  }
}
