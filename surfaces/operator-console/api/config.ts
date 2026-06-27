/**
 * GET /api/config -> non-secret console config for the New-agent picker. Returns the operator's
 * DEFAULT_SKILLS: the capability ids EVERY newly minted client agent ships with by default. Read
 * from the console's own Vercel env (set by deploy_surfaces.sh); no box round-trip, no secret. The
 * picker pre-checks these, and the receiver applies them as a floor at mint time.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET only" });
  const defaultSkills = String(process.env.DEFAULT_SKILLS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return res.status(200).json({ defaultSkills });
}
