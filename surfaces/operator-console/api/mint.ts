/**
 * POST /api/mint  ->  501 not-wired-yet  (Slice 2 STUB).
 *
 * The operator console's "Mint an agent" button posts { clientAccount, personName,
 * personEmail } here. In Slice 2 this is a deliberate STUB: it validates the shape
 * and returns 501 so the UI shows a clear "not connected yet" notice. It does NOT
 * provision anything and does NOT fake a result.
 *
 * Slice 3 replaces this body with the real call into scripts/mint_client_agent.sh
 * (which drives the packaged installer). Until then, no provisioning happens here.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";

export default function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });

  const { personName, personEmail } = (req.body ?? {}) as {
    clientAccount?: string;
    personName?: string;
    personEmail?: string;
  };
  // Person name + email are required; client account is OPTIONAL (may be blank).
  if (!personName || !personEmail) {
    return res.status(400).json({ error: "personName and personEmail are required" });
  }

  // STUB: minting is not wired until Slice 3. Return 501 so the console shows the
  // "not yet connected" notice instead of pretending an agent was created.
  return res.status(501).json({
    error: "Minting is not connected yet. The real provisioning call wires up in Slice 3.",
    wired: false,
  });
}
