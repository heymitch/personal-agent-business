/** GET -> { toolkits: [{slug,name,logo,category,tools}, ...] }. The full
 *  connectable catalog (managed-OAuth apps, with Composio-hosted logos). Cached
 *  hard at the edge (the catalog is effectively static). */
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { listToolkits } from "../lib/composio.js";

export default async function handler(_req: VercelRequest, res: VercelResponse) {
  try {
    const toolkits = await listToolkits();
    res.setHeader("Cache-Control", "s-maxage=3600, stale-while-revalidate=86400");
    return res.status(200).json({ toolkits });
  } catch (e) {
    return res.status(500).json({ error: e instanceof Error ? e.message : String(e) });
  }
}
