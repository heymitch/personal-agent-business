/**
 * GET /api/config -> non-secret console config for the New-agent form. Returns the operator's AGENT
 * PROFILES (named builds: a NAME + the operator's own skill ids + an optional description) and the
 * default profile. Read from the console's own Vercel env (AGENT_PROFILES, a JSON string set by
 * deploy_surfaces.sh from config/agent-profiles.json); no box round-trip, no secret. The New-agent
 * form renders a profile picker from this; "pick a profile" = a default build.
 *
 * When no profiles are configured yet, this returns an empty list and a null default; the form shows
 * a "define them in setup" state instead of a broken empty picker.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { parseAgentProfiles } from "../lib/agent-profiles.js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "GET") return res.status(405).json({ error: "GET only" });
  const config = parseAgentProfiles(process.env.AGENT_PROFILES);
  return res.status(200).json({ profiles: config.profiles, defaultProfile: config.defaultProfile ?? null });
}
