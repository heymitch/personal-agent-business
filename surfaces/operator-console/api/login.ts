/**
 * POST /api/login -- verifies the operator password and sets an HMAC-signed session cookie the Edge
 * middleware checks. node:crypto is fine here (this runs on the @vercel/node serverless runtime, not
 * the Edge runtime). The password is never stored; only its sha256 hash is compared.
 * Env: PAO_PASSWORD_HASH (sha256 hex of the password), SESSION_SECRET (32+ byte hex).
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";
import crypto from "node:crypto";

const COOKIE_NAME = "pao_session";
const SESSION_DAYS = 7;
const MAX_ATTEMPTS = 8;
const WINDOW_MS = 60_000;
const attempts = new Map<string, number[]>();

function rateLimited(ip: string): boolean {
  const now = Date.now();
  const list = (attempts.get(ip) || []).filter((t) => now - t < WINDOW_MS);
  list.push(now);
  attempts.set(ip, list);
  return list.length > MAX_ATTEMPTS;
}

function timingSafeEqualStr(a: string, b: string): boolean {
  // Copy into fresh ArrayBuffer-backed Uint8Arrays so timingSafeEqual's typed signature is satisfied
  // (Buffer's backing buffer is ArrayBufferLike, which the strict @types/node rejects).
  const ab = new Uint8Array(Buffer.from(a, "utf8"));
  const bb = new Uint8Array(Buffer.from(b, "utf8"));
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    res.setHeader("allow", "POST");
    return res.status(405).json({ error: "method_not_allowed" });
  }
  const fwd = req.headers["x-forwarded-for"];
  const ip =
    (Array.isArray(fwd) ? fwd[0] : fwd)?.split(",")[0]?.trim() ||
    req.socket?.remoteAddress ||
    "unknown";
  if (rateLimited(ip)) return res.status(429).json({ error: "rate_limited" });

  const hash = process.env.PAO_PASSWORD_HASH;
  const secret = process.env.SESSION_SECRET;
  if (!hash || !secret) return res.status(500).json({ error: "auth_not_configured" });

  const body = (req.body ?? {}) as { password?: unknown };
  const password = body.password;
  if (!password || typeof password !== "string") {
    return res.status(400).json({ error: "password_required" });
  }

  const candidate = crypto.createHash("sha256").update(password).digest("hex");
  if (!timingSafeEqualStr(candidate, hash)) {
    return res.status(401).json({ error: "invalid_password" });
  }

  const exp = Date.now() + SESSION_DAYS * 86400_000;
  const sig = crypto.createHmac("sha256", secret).update(String(exp)).digest("hex");
  res.setHeader(
    "set-cookie",
    `${COOKIE_NAME}=${exp}.${sig}; Max-Age=${SESSION_DAYS * 86400}; Path=/; HttpOnly; Secure; SameSite=Lax`,
  );
  return res.status(200).json({ ok: true });
}
