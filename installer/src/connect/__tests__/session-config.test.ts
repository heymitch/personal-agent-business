import { describe, it, expect } from "vitest";
import { agentSessionConfig } from "../session-config";

describe("agentSessionConfig", () => {
  it("builds a gmail session pinned to the tight-scope auth config", () => {
    const config = agentSessionConfig({
      toolkits: ["gmail"],
      authConfigs: { gmail: "ac_xAu10jHDGmRm" },
    });
    expect(config.toolkits).toEqual(["gmail"]);
    expect(config.authConfigs).toEqual({ gmail: "ac_xAu10jHDGmRm" });
  });

  it("keeps connection management ON (the in-chat-auth mechanism)", () => {
    const config = agentSessionConfig({ toolkits: ["gmail"], authConfigs: {} });
    expect(config.manageConnections).toBe(true);
  });

  it("keeps the code-execution workbench OFF for client agents", () => {
    const config = agentSessionConfig({ toolkits: ["gmail"], authConfigs: {} });
    expect(config.workbench).toEqual({ enable: false });
  });

  it("requires at least one toolkit", () => {
    expect(() => agentSessionConfig({ toolkits: [], authConfigs: {} })).toThrow(/toolkit/i);
  });
});
