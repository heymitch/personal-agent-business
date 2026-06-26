/**
 * Real `@composio/core` adapter behind the RefreshSdk seam. Reuses the
 * tight-scope Gmail auth config (so a refreshed session keeps the same read+send
 * Gmail consent, never the broad default), and reattaches the session by id to
 * update it in place.
 */
import { ensureTightGmailAuthConfig } from "./gmail-auth-config";
import { agentSessionConfig } from "./session-config";
import type { RefreshSdk } from "./refresh-session";

/** The slice of a `@composio/core` Composio instance this adapter uses. */
export interface ComposioRefreshSubset {
  connectedAccounts: {
    list(query: { userIds: string[] }): Promise<{
      items?: Array<{ status: string; toolkit?: { slug?: string }; toolkitSlug?: string }>;
    }>;
  };
  authConfigs: {
    list(params: { toolkit: string }): Promise<{ items: Array<{ id: string; name: string }> }>;
    create(
      toolkit: string,
      options: { type: "use_composio_managed_auth"; name: string; credentials?: { scopes: string[] } },
    ): Promise<{ id: string }>;
  };
  toolRouter: {
    use(sessionId: string): Promise<{ update(config: unknown): Promise<unknown> }>;
  };
}

async function ensureManagedAuthConfig(sdk: ComposioRefreshSubset, slug: string): Promise<string> {
  const name = `${slug}-default-managed`;
  const { items } = await sdk.authConfigs.list({ toolkit: slug });
  const found = items.find((c) => c.name === name);
  if (found) return found.id;
  const created = await sdk.authConfigs.create(slug, { type: "use_composio_managed_auth", name });
  return created.id;
}

export function makeRefreshSdk(sdk: ComposioRefreshSubset): RefreshSdk {
  return {
    async listActiveToolkits(userId) {
      const res = await sdk.connectedAccounts.list({ userIds: [userId] });
      return (res.items ?? [])
        .filter((a) => a.status === "ACTIVE")
        .map((a) => a.toolkit?.slug ?? a.toolkitSlug ?? "");
    },

    async ensureAuthConfig(toolkit) {
      // Gmail gets the tight read+send config (never the broad managed default);
      // every other app uses Composio's default-managed auth config.
      if (toolkit === "gmail") {
        const { id } = await ensureTightGmailAuthConfig(sdk.authConfigs);
        return id;
      }
      return ensureManagedAuthConfig(sdk, toolkit);
    },

    async updateSession(sessionId, cfg) {
      const session = await sdk.toolRouter.use(sessionId);
      await session.update(agentSessionConfig(cfg));
    },
  };
}
