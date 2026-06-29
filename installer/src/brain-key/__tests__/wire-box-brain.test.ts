import { describe, it, expect, vi } from "vitest";
import {
  buildBoxBrainScript,
  wireBoxBrain,
  provisionClientBrain,
  OPENAI_BRAIN_BASE_URL,
} from "../wire-box-brain";
import type { BrainKeyDeps } from "../types";

function brainDeps(overrides: Partial<BrainKeyDeps> = {}): BrainKeyDeps & {
  createProject: ReturnType<typeof vi.fn>;
  createServiceAccount: ReturnType<typeof vi.fn>;
  setRateLimit: ReturnType<typeof vi.fn>;
  deleteServiceAccount: ReturnType<typeof vi.fn>;
} {
  return {
    createProject: vi.fn().mockResolvedValue({ projectId: "proj_1" }),
    createServiceAccount: vi.fn().mockResolvedValue({ key: "sk-svcacct-SECRET", serviceAccountId: "svc_1" }),
    setRateLimit: vi.fn().mockResolvedValue(undefined),
    deleteServiceAccount: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as never;
}

describe("buildBoxBrainScript", () => {
  it("pins provider openai-api + the explicit OpenAI base_url (the footgun) + model, and writes the key via a printf builtin", () => {
    const s = buildBoxBrainScript("sk-svcacct-SECRET", "gpt-5.5");
    expect(s).toContain("hermes config set model.provider openai-api");
    expect(s).toContain(`hermes config set model.base_url ${OPENAI_BRAIN_BASE_URL}`);
    expect(s).toContain("https://api.openai.com/v1");
    expect(s).toContain("hermes config set model.default 'gpt-5.5'");
    // key written by a shell builtin (printf), never via a command argv
    expect(s).toContain("printf 'OPENAI_API_KEY=%s\\n' 'sk-svcacct-SECRET'");
  });
});

describe("wireBoxBrain", () => {
  it("hands the box-side script (with the key + base_url) to the injected runner for that box ip", async () => {
    const runScript = vi.fn().mockResolvedValue(undefined);
    await wireBoxBrain({ boxIp: "203.0.113.7", brainKey: "sk-svcacct-SECRET", model: "gpt-5.5" }, { runScript });
    expect(runScript).toHaveBeenCalledTimes(1);
    const [ip, script] = runScript.mock.calls[0];
    expect(ip).toBe("203.0.113.7");
    expect(script).toContain("sk-svcacct-SECRET");
    expect(script).toContain("https://api.openai.com/v1");
  });
});

describe("provisionClientBrain", () => {
  it("mints the isolated key THEN puts that exact key on the client box, and returns the refs", async () => {
    const d = brainDeps();
    const wireBox = vi.fn().mockResolvedValue(undefined);
    const out = await provisionClientBrain({ customerSlug: "dana-acme", boxIp: "203.0.113.7" }, { brain: d, wireBox });

    // the project ties to the dashboard slug: customer-<slug>
    expect(d.createProject).toHaveBeenCalledWith("customer-dana-acme");
    // the minted key is what lands on the box (not the admin key)
    expect(wireBox).toHaveBeenCalledWith("203.0.113.7", "sk-svcacct-SECRET", "gpt-5.5");
    expect(out).toEqual({ projectId: "proj_1", serviceAccountId: "svc_1", model: "gpt-5.5", rateLimited: true });
  });

  it("mints (project -> service account) BEFORE wiring the box", async () => {
    const order: string[] = [];
    const d = brainDeps({
      createProject: vi.fn().mockImplementation(async () => (order.push("project"), { projectId: "proj_1" })),
      createServiceAccount: vi
        .fn()
        .mockImplementation(async () => (order.push("sa"), { key: "sk-svcacct-SECRET", serviceAccountId: "svc_1" })),
    });
    const wireBox = vi.fn().mockImplementation(async () => void order.push("wire"));
    await provisionClientBrain({ customerSlug: "x", boxIp: "1.2.3.4" }, { brain: d, wireBox });
    expect(order).toEqual(["project", "sa", "wire"]);
  });

  it("rolls back the minted key (deletes the service account) when wiring the box fails, and surfaces the wiring error", async () => {
    const d = brainDeps();
    const wireBox = vi.fn().mockRejectedValue(new Error("ssh: box unreachable"));
    await expect(
      provisionClientBrain({ customerSlug: "x", boxIp: "1.2.3.4" }, { brain: d, wireBox }),
    ).rejects.toThrow(/box unreachable/);
    // no orphaned OpenAI project: the just-minted service account is deleted
    expect(d.deleteServiceAccount).toHaveBeenCalledWith("proj_1", "svc_1");
  });

  it("still wires + returns the key when the rate-limit guard fails (flagged rateLimited=false)", async () => {
    const d = brainDeps({ setRateLimit: vi.fn().mockRejectedValue(new Error("rl down")) });
    const wireBox = vi.fn().mockResolvedValue(undefined);
    const out = await provisionClientBrain({ customerSlug: "x", boxIp: "1.2.3.4" }, { brain: d, wireBox });
    expect(wireBox).toHaveBeenCalledWith("1.2.3.4", "sk-svcacct-SECRET", "gpt-5.5");
    expect(out.rateLimited).toBe(false);
    expect(d.deleteServiceAccount).not.toHaveBeenCalled(); // a wired box is NOT rolled back
  });
});
