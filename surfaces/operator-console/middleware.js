// Vercel Edge Middleware -- gates the operator console behind Cloudflare Access, keyed to the
// operator's email. This is the SAME Cloudflare Access email gate the client agent surfaces use
// (cf_portal.sh stands up a self_hosted Access app + an allow-email policy); there is NO static
// password and NO shared secret to type.
//
// Cloudflare Access sits in front of the console's gated hostname and, on a valid login, injects a
// signed RS256 JWT (the `Cf-Access-Jwt-Assertion` header and the `CF_Authorization` cookie). We
// verify that JWT against the operator's Access team keys, confirm it was issued for THIS app (aud),
// and confirm the authenticated identity is OWNER_EMAIL. No valid Access token -> 403. This also
// closes the raw *.vercel.app bypass: a request that did not pass through Cloudflare Access carries
// no token and is denied.
//
// Env (set into the console's Vercel project by deploy_surfaces.sh; produced by cf_console_gate.sh):
//   CF_ACCESS_AUTH_DOMAIN  e.g. myteam.cloudflareaccess.com (the Access team auth domain)
//   CF_ACCESS_AUD          the Access application Audience (AUD) tag for the console app
//   OWNER_EMAIL            the only identity allowed through (defense in depth on the Access policy)
// Fails CLOSED: if any of these is unset, every request is denied.
export const config = {
  matcher: ['/((?!favicon).*)'],
};

function b64urlToBytes(s) {
  const norm = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = norm.length % 4 ? 4 - (norm.length % 4) : 0;
  const bin = atob(norm + '='.repeat(pad));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function b64urlToJson(s) {
  return JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));
}

// Cache the team's signing keys in module scope (refreshed hourly) so we do not refetch per request.
let certsCache = { domain: '', keys: null, at: 0 };
async function authKeys(authDomain) {
  const now = Date.now();
  if (certsCache.keys && certsCache.domain === authDomain && now - certsCache.at < 3600000) {
    return certsCache.keys;
  }
  const res = await fetch(`https://${authDomain}/cdn-cgi/access/certs`);
  if (!res.ok) return null;
  const body = await res.json();
  certsCache = { domain: authDomain, keys: body.keys || [], at: now };
  return certsCache.keys;
}

async function verifyAccessJwt(token, authDomain, aud, ownerEmail) {
  if (!token) return false;
  const parts = token.split('.');
  if (parts.length !== 3) return false;
  let header, payload;
  try {
    header = b64urlToJson(parts[0]);
    payload = b64urlToJson(parts[1]);
  } catch {
    return false;
  }
  if (header.alg !== 'RS256') return false;
  if (payload.exp && Date.now() / 1000 > payload.exp) return false;
  // Audience: Access sets aud to this app's AUD tag (string or array).
  const auds = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!auds.includes(aud)) return false;
  // Identity: only the operator's own email passes.
  if (String(payload.email || '').toLowerCase() !== String(ownerEmail).toLowerCase()) return false;
  const keys = await authKeys(authDomain);
  if (!keys || !keys.length) return false;
  const jwk = keys.find((k) => k.kid === header.kid) || keys[0];
  if (!jwk) return false;
  try {
    const key = await crypto.subtle.importKey(
      'jwk',
      { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    const data = new TextEncoder().encode(parts[0] + '.' + parts[1]);
    return await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlToBytes(parts[2]), data);
  } catch {
    return false;
  }
}

function getToken(request) {
  const hdr = request.headers.get('cf-access-jwt-assertion');
  if (hdr) return hdr;
  const cookie = request.headers.get('cookie') || '';
  const m = cookie.split(';').map((s) => s.trim()).find((s) => s.startsWith('CF_Authorization='));
  return m ? decodeURIComponent(m.slice('CF_Authorization='.length)) : null;
}

export default async function middleware(request) {
  const authDomain = process.env.CF_ACCESS_AUTH_DOMAIN;
  const aud = process.env.CF_ACCESS_AUD;
  const ownerEmail = process.env.OWNER_EMAIL;
  if (!authDomain || !aud || !ownerEmail) {
    return new Response('Console auth not configured (Cloudflare Access).', { status: 403 });
  }
  if (await verifyAccessJwt(getToken(request), authDomain, aud, ownerEmail)) return; // pass through
  return new Response('Forbidden: open the console from its Cloudflare Access gated address.', { status: 403 });
}
