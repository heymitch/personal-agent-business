/**
 * Refresh a Tool Router session to cover the union of a user's ACTIVE Composio
 * connections; the missing inch that makes "connect any app, now or in the
 * future" actually true.
 *
 * Proven live: a session's usable tool surface is bounded by its pinned
 * `toolkits`, so a freshly-connected app is invisible to the running session
 * until its toolkit is added. `toolRouter.create` is NOT idempotent, but
 * `session.update` expands the session in place and keeps the SAME mcp.url, so
 * the agent's box needs no re-wire.
 *
 * Pure: every Composio specific is behind an injected seam. The real adapter
 * lists active connections, ensures the tight/managed auth configs, and
 * reattaches the session by id to update it.
 */
export interface RefreshSdk {
  /** Active (OAuth-completed) toolkit slugs for this Composio user_id. */
  listActiveToolkits(userId: string): Promise<string[]>;
  /** Find-or-create the auth config for a toolkit (tight gmail / managed others). Returns its id. */
  ensureAuthConfig(toolkit: string): Promise<string>;
  /** Expand the existing session (by id) to exactly these toolkits. Keeps the mcp.url stable. */
  updateSession(
    sessionId: string,
    cfg: { toolkits: string[]; authConfigs: Record<string, string> },
  ): Promise<void>;
}

export interface RefreshResult {
  /** The toolkits the session now covers (deduped, first-seen order). */
  toolkits: string[];
  /** False when the user has no active connections (the session was left untouched). */
  updated: boolean;
}

export async function refreshSessionToolkits(
  sdk: RefreshSdk,
  opts: { sessionId: string; userId: string },
): Promise<RefreshResult> {
  if (!opts.sessionId) {
    throw new Error("refreshSessionToolkits: sessionId is required to reattach the session");
  }

  const seen = new Set<string>();
  const toolkits: string[] = [];
  for (const raw of await sdk.listActiveToolkits(opts.userId)) {
    const tk = (raw ?? "").trim().toLowerCase();
    if (tk && !seen.has(tk)) {
      seen.add(tk);
      toolkits.push(tk);
    }
  }

  // Never call update with an empty toolkit set (agentSessionConfig rejects it,
  // and there is nothing to wire for a buyer who connected nothing).
  if (toolkits.length === 0) {
    return { toolkits: [], updated: false };
  }

  const authConfigs: Record<string, string> = {};
  for (const tk of toolkits) {
    authConfigs[tk] = await sdk.ensureAuthConfig(tk);
  }

  await sdk.updateSession(opts.sessionId, { toolkits, authConfigs });
  return { toolkits, updated: true };
}
