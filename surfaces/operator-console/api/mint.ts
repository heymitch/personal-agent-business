/**
 * POST /api/mint -> forwards the New-agent form to the operator box's /mint, which runs the real
 * on-demand provisioning (mint_client_agent.sh: per-person-email user_id, <person>-<account> box
 * naming, provision + Cloudflare gate + Tool Router session), then records the agent so it appears
 * on the Fleet + Dashboard.
 *
 * The console is a thin password-gated proxy: it holds only MINT_RECEIVER_URL + MINT_SECRET and
 * forwards with the shared secret server-side. Person name + client email are required; client
 * account is OPTIONAL (naming only; it never enters the identity hash). Secrets never reach the
 * browser; a failed mint returns a clean message, never the box's stderr.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const receiver = process.env.MINT_RECEIVER_URL;
  const secret = process.env.MINT_SECRET;
  if (!receiver || !secret) {
    return res.status(500).json({ error: "MINT_RECEIVER_URL / MINT_SECRET not configured" });
  }

  const body = (req.body ?? {}) as {
    personName?: string;
    email?: string;
    clientAccount?: string;
    priceMonthly?: number;
    profile?: string;
    capabilities?: string[];
    needsKit?: boolean;
  };
  const personName = String(body.personName ?? "").trim();
  const email = String(body.email ?? "").trim();
  if (!personName) return res.status(400).json({ error: "personName required" });
  if (!email) return res.status(400).json({ error: "client email required" });
  const price = Number(body.priceMonthly);
  const profile = String(body.profile ?? "").trim();
  const capabilities = Array.isArray(body.capabilities) ? body.capabilities.map(String) : [];

  try {
    const upstream = await fetch(`${receiver.replace(/\/+$/, "")}/mint`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-sim-secret": secret },
      body: JSON.stringify({
        personName,
        email,
        clientAccount: String(body.clientAccount ?? "").trim(),
        priceMonthly: Number.isFinite(price) && price >= 0 ? price : undefined,
        profile,
        capabilities,
        needsKit: body.needsKit === true,
      }),
    });
    const text = await upstream.text();
    if (!upstream.ok) return res.status(upstream.status).json({ error: `receiver ${upstream.status}: ${text}` });
    const data = JSON.parse(text) as { agentName?: string; connectUrl?: string; slug?: string };
    return res.status(200).json({
      ok: true,
      agentName: data.agentName,
      connectUrl: data.connectUrl,
      slug: data.slug,
    });
  } catch (e) {
    return res.status(502).json({ error: e instanceof Error ? e.message : String(e) });
  }
}
