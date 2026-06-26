import type { RefreshResult } from "./refresh-session";

/**
 * The brain of the Composio `connection.completed` flow: when a buyer OAuths a
 * new app after provisioning, expand their agent's session to cover it; the
 * missing inch that makes "connect any app in the future" real. Pure: the store
 * and the refresh are injected (real wiring = makeSessionStore + makeRefreshSdk).
 */
export interface ConnectionEvent {
  /** The Composio user_id the connection bound to (= userIdForPurchase(email)). */
  userId?: string;
  toolkit?: string;
  type?: string;
}

export interface ConnectionHandlerDeps {
  store: { get(userId: string): Promise<string | null> };
  refresh(sessionId: string, userId: string): Promise<RefreshResult>;
}

export type HandlerOutcome =
  | { status: "refreshed"; toolkits: string[] }
  | { status: "noop" }
  | { status: "no-session" }
  | { status: "ignored" };

export async function handleConnectionCompleted(
  deps: ConnectionHandlerDeps,
  event: ConnectionEvent,
): Promise<HandlerOutcome> {
  const userId = (event.userId ?? "").trim();
  if (!userId) return { status: "ignored" }; // can't act; never throw the webhook

  const sessionId = await deps.store.get(userId);
  if (!sessionId) return { status: "no-session" }; // not provisioned yet; onboarding path owns first wire

  const result = await deps.refresh(sessionId, userId);
  return result.updated ? { status: "refreshed", toolkits: result.toolkits } : { status: "noop" };
}
