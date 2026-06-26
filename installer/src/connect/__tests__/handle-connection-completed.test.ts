import { describe, it, expect, vi } from "vitest";
import { handleConnectionCompleted, type ConnectionHandlerDeps } from "../handle-connection-completed";

function deps(over: Partial<ConnectionHandlerDeps> = {}): ConnectionHandlerDeps {
  return {
    store: { get: vi.fn(async (u: string) => (u === "wm-known" ? "trs_known" : null)) },
    refresh: vi.fn(async () => ({ toolkits: ["gmail", "github"], updated: true })),
    ...over,
  };
}

describe("handleConnectionCompleted", () => {
  it("refreshes the user's session to the union when the user has one", async () => {
    const d = deps();
    const out = await handleConnectionCompleted(d, { userId: "wm-known", toolkit: "github" });
    expect(d.refresh).toHaveBeenCalledWith("trs_known", "wm-known");
    expect(out).toEqual({ status: "refreshed", toolkits: ["gmail", "github"] });
  });

  it("does nothing when the user has no provisioned session yet (onboarding-time path owns that)", async () => {
    const d = deps();
    const out = await handleConnectionCompleted(d, { userId: "wm-stranger", toolkit: "github" });
    expect(d.refresh).not.toHaveBeenCalled();
    expect(out).toEqual({ status: "no-session" });
  });

  it("ignores an event with no userId (can't act, must not throw the webhook)", async () => {
    const d = deps();
    const out = await handleConnectionCompleted(d, { toolkit: "github" });
    expect(d.refresh).not.toHaveBeenCalled();
    expect(out).toEqual({ status: "ignored" });
  });

  it("reports a no-op when the refresh changed nothing", async () => {
    const d = deps({ refresh: vi.fn(async () => ({ toolkits: [], updated: false })) });
    const out = await handleConnectionCompleted(d, { userId: "wm-known" });
    expect(out).toEqual({ status: "noop" });
  });
});
