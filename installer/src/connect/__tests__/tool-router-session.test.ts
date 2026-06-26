import { describe, it, expect, vi } from "vitest";
import { ensureToolRouterSession } from "../tool-router-session";
import type { AgentSessionConfig } from "../session-config";

/**
 * ensureToolRouterSession wraps Composio's `toolRouter.create(userId, config)` (the proven
 * call from scripts/create-tool-router-session.ts) behind an injected seam so the provision
 * pipeline can mint a session and get its stable MCP url without the live SDK in a test. The
 * session config MUST be the canonical agentSessionConfig (manageConnections true, workbench
 * off, toolkits + authConfigs pinned), and the url is what gets wired into the box.
 */

function makeApi(session: { sessionId?: string; mcp?: { url?: string | null } }) {
  return {
    toolRouter: {
      create: vi.fn(async (_userId: string, _config: AgentSessionConfig) => session),
    },
  };
}

describe("ensureToolRouterSession", () => {
  it("creates a session for the user and returns its sessionId + mcpUrl", async () => {
    const api = makeApi({ sessionId: "trs_abc", mcp: { url: "https://mcp.composio.dev/trs_abc" } });

    const res = await ensureToolRouterSession(api, {
      userId: "wm-deadbeef",
      toolkits: ["gmail", "slack"],
      authConfigs: { gmail: "ac_tight" },
    });

    expect(res).toEqual({ sessionId: "trs_abc", mcpUrl: "https://mcp.composio.dev/trs_abc" });
    expect(api.toolRouter.create).toHaveBeenCalledTimes(1);
  });

  it("hands Composio the canonical session config (toolkits, pinned authConfigs, manageConnections, no workbench)", async () => {
    const api = makeApi({ sessionId: "trs_x", mcp: { url: "https://m/trs_x" } });

    await ensureToolRouterSession(api, {
      userId: "wm-1",
      toolkits: ["gmail", "notion"],
      authConfigs: { gmail: "ac_tight" },
    });

    const [userId, config] = api.toolRouter.create.mock.calls[0];
    expect(userId).toBe("wm-1");
    expect(config.toolkits).toEqual(["gmail", "notion"]);
    expect(config.authConfigs).toEqual({ gmail: "ac_tight" });
    expect(config.manageConnections).toBe(true);
    expect(config.workbench).toEqual({ enable: false });
  });

  it("throws when Composio returns no mcp.url (do not wire a dead session)", async () => {
    const api = makeApi({ sessionId: "trs_x", mcp: { url: null } });
    await expect(
      ensureToolRouterSession(api, { userId: "wm-1", toolkits: ["gmail"], authConfigs: {} }),
    ).rejects.toThrow(/mcp.*url|no .*url/i);
  });

  it("throws when userId is missing (the multi-tenant isolation key)", async () => {
    const api = makeApi({ sessionId: "trs_x", mcp: { url: "https://m/x" } });
    await expect(
      ensureToolRouterSession(api, { userId: "", toolkits: ["gmail"], authConfigs: {} }),
    ).rejects.toThrow(/userId/i);
  });
});
