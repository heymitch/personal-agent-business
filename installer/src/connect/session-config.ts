/**
 * The canonical Tool Router session config for a personal agent.
 *
 * Composio's current architecture: Tool Router SESSIONS are the MCP servers.
 * `toolRouter.create(userId, config)` returns a session whose `mcp.url` is
 * stable (sessions persist server-side and are reattachable by id via
 * `toolRouter.use(id)`, verified live, same URL). The old dashboard
 * "MCP servers" product is legacy and gone from the new dashboard nav.
 *
 * Contract this helper pins:
 * - `manageConnections: true`: the session exposes COMPOSIO_MANAGE_CONNECTIONS,
 *   which is the in-chat-auth mechanism (the agent mints connect links itself).
 * - `workbench.enable: false`: never ship Composio's code-execution sandbox to
 *   a client agent; the agent has its own runtime.
 * - `authConfigs` pins each toolkit to OUR auth config (e.g. the tight-scope
 *   Gmail config) so clients never see the broad managed consent screen.
 */
export interface AgentSessionConfig {
  toolkits: string[];
  authConfigs: Record<string, string>;
  manageConnections: true;
  workbench: { enable: false };
}

export function agentSessionConfig(opts: {
  toolkits: string[];
  authConfigs: Record<string, string>;
}): AgentSessionConfig {
  if (opts.toolkits.length === 0) {
    throw new Error("agentSessionConfig: at least one toolkit is required");
  }
  return {
    toolkits: opts.toolkits,
    authConfigs: opts.authConfigs,
    manageConnections: true,
    workbench: { enable: false },
  };
}
