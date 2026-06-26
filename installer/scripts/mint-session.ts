/**
 * Create (or, in a shimmed test, simulate) the Composio Tool Router session for a
 * freshly minted CLIENT agent, then PERSIST `userId -> sessionId` via the SHIPPED
 * session store. This is the provision-hook the mint action drives: the agent
 * inherits exactly the connections the person makes on the onboarding page,
 * because both sides key off the SAME per-email user_id.
 *
 * Guardrails honoured:
 *  - GR2: a session is created ONCE at provision (toolRouter.create); later apps
 *    expand it via session.update (the receiver / reconcile path), never a second
 *    create. This script is the one-time create + persist.
 *  - The store is the SHIPPED flat { userId: sessionId } map (one session per
 *    userId), so the receiver can later reattach by id.
 *
 * Secrets come ONLY from env (COMPOSIO_API_KEY). In tests, MINT_FAKE_SESSION_ID
 * short-circuits the real Composio call so nothing external is touched and no
 * money is spent; the persist path is still exercised end-to-end.
 *
 * Usage:  tsx scripts/mint-session.ts <userId> [toolkit ...]
 *   env:  SESSION_STORE_FILE (where to persist), COMPOSIO_API_KEY (real create),
 *         MINT_FAKE_SESSION_ID (test short-circuit).
 */
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { makeSessionStore } from "../src/connect/session-store";

const userId = (process.argv[2] ?? "").trim();
if (!userId) {
  console.error("mint-session: a userId is required");
  process.exit(2);
}
const toolkits = process.argv.slice(3).filter(Boolean);

const here = dirname(fileURLToPath(import.meta.url));
const storeFile = process.env.SESSION_STORE_FILE ?? resolve(here, "../receiver/session-store.json");

async function resolveSessionId(): Promise<string> {
  // Test / dry path: never touch Composio, never spend; persist the supplied id.
  const fake = process.env.MINT_FAKE_SESSION_ID;
  if (fake) return fake;

  // Real path: create the Tool Router session ONCE (GR2) bound to this user_id.
  const apiKey = process.env.COMPOSIO_API_KEY ?? "";
  if (!apiKey) {
    throw new Error("mint-session: COMPOSIO_API_KEY not set (and no MINT_FAKE_SESSION_ID)");
  }
  if (toolkits.length === 0) {
    // A person who connected nothing yet has no toolkits to pin; the onboarding
    // page + receiver expand the session on first connect. Nothing to create now.
    throw new Error("mint-session: no toolkits to pin; defer to the onboarding/receiver path");
  }
  // Lazy import so the engine deps are only loaded on the real path.
  const { Composio } = await import("@composio/core");
  const { ensureToolRouterSession } = await import("../src/connect/tool-router-session");
  const composio = new Composio({ apiKey }) as unknown as Parameters<typeof ensureToolRouterSession>[0];
  const session = await ensureToolRouterSession(composio, { userId, toolkits });
  // The box wiring consumes mcp.url out of band; we surface it for the caller.
  console.log(`[mint-session] mcp.url=${session.mcpUrl}`);
  return session.sessionId;
}

const sessionId = await resolveSessionId();
await makeSessionStore(storeFile).put(userId, sessionId);
console.log(`[mint-session] persisted ${userId} -> ${sessionId} in ${storeFile}`);
process.stdout.write(`SESSION-PERSISTED user_id=${userId} session_id=${sessionId}\n`);
