/**
 * GET /api/fleet -> the operator box's /fleet (recorded agents + live status/freshness).
 * Read-only proxy: the shared secret stays server-side, the box keeps every other key. The browser
 * only ever sees the aggregated fleet JSON.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET only" });
  const receiver = process.env.MINT_RECEIVER_URL;
  const secret = process.env.MINT_SECRET;
  if (!receiver || !secret) {
    return res.status(500).json({ error: "MINT_RECEIVER_URL / MINT_SECRET not configured" });
  }
  try {
    const upstream = await fetch(`${receiver.replace(/\/+$/, "")}/fleet`, {
      headers: { "x-sim-secret": secret },
    });
    const text = await upstream.text();
    if (!upstream.ok) return res.status(upstream.status).json({ error: `receiver ${upstream.status}: ${text}` });
    return res.status(200).json(JSON.parse(text));
  } catch (e) {
    return res.status(502).json({ error: e instanceof Error ? e.message : String(e) });
  }
}
