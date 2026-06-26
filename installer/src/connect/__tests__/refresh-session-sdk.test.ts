import { describe, it, expect, vi } from "vitest";
import { makeRefreshSdk, type ComposioRefreshSubset } from "../refresh-session-sdk";
import { TIGHT_GMAIL_AUTH_CONFIG_NAME } from "../gmail-auth-config";

function fakeComposio(over: Partial<ComposioRefreshSubset> = {}): ComposioRefreshSubset {
  const updateSpy = vi.fn(async () => ({}));
  return {
    connectedAccounts: {
      list: vi.fn(async () => ({
        items: [
          { status: "ACTIVE", toolkit: { slug: "gmail" } },
          { status: "INITIATED", toolkit: { slug: "slack" } }, // not active -> dropped
          { status: "ACTIVE", toolkitSlug: "github" },
        ],
      })),
    },
    authConfigs: {
      list: vi.fn(async () => ({ items: [] as Array<{ id: string; name: string }> })),
      create: vi.fn(async (_slug: string, body: any) => ({ id: `ac_${body.name}` })),
    },
    toolRouter: {
      use: vi.fn(async () => ({ update: updateSpy })),
    },
    ...over,
  } as ComposioRefreshSubset;
}

describe("makeRefreshSdk", () => {
  it("listActiveToolkits returns only ACTIVE connections' slugs", async () => {
    const sdk = makeRefreshSdk(fakeComposio());
    expect(await sdk.listActiveToolkits("wm-x")).toEqual(["gmail", "github"]);
  });

  it("ensureAuthConfig pins GMAIL to the tight-scope config", async () => {
    const composio = fakeComposio();
    const sdk = makeRefreshSdk(composio);
    const id = await sdk.ensureAuthConfig("gmail");
    expect(composio.authConfigs.create).toHaveBeenCalledWith(
      "gmail",
      expect.objectContaining({ name: TIGHT_GMAIL_AUTH_CONFIG_NAME }),
    );
    expect(id).toBe(`ac_${TIGHT_GMAIL_AUTH_CONFIG_NAME}`);
  });

  it("ensureAuthConfig uses a default-managed config for non-gmail apps", async () => {
    const composio = fakeComposio();
    const sdk = makeRefreshSdk(composio);
    const id = await sdk.ensureAuthConfig("github");
    expect(composio.authConfigs.create).toHaveBeenCalledWith(
      "github",
      expect.objectContaining({ name: "github-default-managed" }),
    );
    expect(id).toBe("ac_github-default-managed");
  });

  it("updateSession reattaches by id then updates with a manageConnections session config", async () => {
    const composio = fakeComposio();
    const sdk = makeRefreshSdk(composio);
    await sdk.updateSession("trs_42", { toolkits: ["gmail", "github"], authConfigs: { gmail: "a", github: "b" } });
    expect(composio.toolRouter.use).toHaveBeenCalledWith("trs_42");
    const session = await (composio.toolRouter.use as any).mock.results[0].value;
    expect(session.update).toHaveBeenCalledWith(
      expect.objectContaining({
        toolkits: ["gmail", "github"],
        authConfigs: { gmail: "a", github: "b" },
        manageConnections: true,
      }),
    );
  });
});
