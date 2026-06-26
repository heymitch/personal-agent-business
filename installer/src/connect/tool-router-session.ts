import { agentSessionConfig, type AgentSessionConfig } from "./session-config";

/**
 * Create the Composio Tool Router session for one agent owner and return its stable MCP url.
 *
 * Composio's current architecture (verified live, see session-config.ts): a Tool Router
 * SESSION is the MCP server. `toolRouter.create(userId, config)` returns a session whose
 * `mcp.url` is stable and reattachable. The pipeline mints one per provisioned agent, keyed by
 * the buyer's `user_id` (so the agent inherits exactly the connections that buyer made on the
 * onboarding page), then wires the url into the box.
 *
 * The Composio SDK is injected as a narrow seam (just `toolRouter.create`) so this is pure and
 * testable. The real adapter passes a `@composio/core` Composio instance.
 */
export interface ToolRouterApi {
  toolRouter: {
    create(
      userId: string,
      config: AgentSessionConfig,
    ): Promise<{ sessionId?: string; mcp?: { url?: string | null } }>;
  };
}

export interface ToolRouterSession {
  sessionId: string;
  mcpUrl: string;
}

export async function ensureToolRouterSession(
  api: ToolRouterApi,
  opts: { userId: string; toolkits: string[]; authConfigs?: Record<string, string> },
): Promise<ToolRouterSession> {
  if (!opts.userId) throw new Error("ensureToolRouterSession: userId is required");

  // agentSessionConfig enforces >=1 toolkit and pins manageConnections/workbench. A buyer who
  // picked only web-only capabilities has no toolkits, so the CALLER must skip wiring entirely
  // rather than mint an empty session.
  const config = agentSessionConfig({
    toolkits: opts.toolkits,
    authConfigs: opts.authConfigs ?? {},
  });

  const session = await api.toolRouter.create(opts.userId, config);
  const mcpUrl = session.mcp?.url;
  if (!mcpUrl) {
    throw new Error("ensureToolRouterSession: Composio returned no mcp.url for the session");
  }
  if (!session.sessionId) {
    throw new Error("ensureToolRouterSession: Composio returned no sessionId for the session");
  }
  return { sessionId: session.sessionId, mcpUrl };
}
