import { describe, it, expect, vi } from "vitest";
import { refreshSessionToolkits, type RefreshSdk } from "../refresh-session";

function fakeSdk(overrides: Partial<RefreshSdk> = {}): RefreshSdk {
  return {
    listActiveToolkits: vi.fn(async () => ["gmail", "github"]),
    ensureAuthConfig: vi.fn(async (tk: string) => `ac_${tk}`),
    updateSession: vi.fn(async () => {}),
    ...overrides,
  };
}

describe("refreshSessionToolkits", () => {
  it("expands the session to the union of the user's active toolkits", async () => {
    const sdk = fakeSdk();
    const out = await refreshSessionToolkits(sdk, { sessionId: "trs_1", userId: "wm-x" });

    expect(sdk.updateSession).toHaveBeenCalledTimes(1);
    expect(sdk.updateSession).toHaveBeenCalledWith("trs_1", {
      toolkits: ["gmail", "github"],
      authConfigs: { gmail: "ac_gmail", github: "ac_github" },
    });
    expect(out).toEqual({ toolkits: ["gmail", "github"], updated: true });
  });

  it("ensures one auth config per toolkit (tight gmail / managed others is the SDK's job)", async () => {
    const sdk = fakeSdk();
    await refreshSessionToolkits(sdk, { sessionId: "trs_1", userId: "wm-x" });
    expect(sdk.ensureAuthConfig).toHaveBeenCalledWith("gmail");
    expect(sdk.ensureAuthConfig).toHaveBeenCalledWith("github");
    expect((sdk.ensureAuthConfig as any).mock.calls.length).toBe(2);
  });

  it("dedupes toolkits and drops blanks", async () => {
    const sdk = fakeSdk({
      listActiveToolkits: vi.fn(async () => ["gmail", "gmail", "", "github"]),
    });
    const out = await refreshSessionToolkits(sdk, { sessionId: "trs_1", userId: "wm-x" });
    expect(out.toolkits).toEqual(["gmail", "github"]);
    expect(sdk.updateSession).toHaveBeenCalledWith(
      "trs_1",
      expect.objectContaining({ toolkits: ["gmail", "github"] }),
    );
  });

  it("is a no-op when the user has no active connections (never updates an empty session)", async () => {
    const sdk = fakeSdk({ listActiveToolkits: vi.fn(async () => []) });
    const out = await refreshSessionToolkits(sdk, { sessionId: "trs_1", userId: "wm-x" });
    expect(sdk.updateSession).not.toHaveBeenCalled();
    expect(out).toEqual({ toolkits: [], updated: false });
  });

  it("requires a sessionId (can't refresh what we can't reattach)", async () => {
    const sdk = fakeSdk();
    await expect(
      refreshSessionToolkits(sdk, { sessionId: "", userId: "wm-x" }),
    ).rejects.toThrow(/sessionId/i);
  });
});
