/**
 * POST /api/logout -- clears the operator session cookie. The Edge middleware then redirects any
 * further request to the login page.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    res.setHeader("allow", "POST");
    return res.status(405).json({ error: "method_not_allowed" });
  }
  res.setHeader("set-cookie", "pao_session=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax");
  return res.status(200).json({ ok: true });
}
