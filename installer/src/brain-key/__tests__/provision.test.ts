import { describe, it, expect, vi } from "vitest";
import { mintBrainKey, revokeBrainKey, DEFAULT_RATE_LIMIT } from "../provision";
import type { BrainKeyDeps } from "../types";

function deps(overrides: Partial<BrainKeyDeps> = {}): BrainKeyDeps & {
  createProject: ReturnType<typeof vi.fn>;
  createServiceAccount: ReturnType<typeof vi.fn>;
  setRateLimit: ReturnType<typeof vi.fn>;
  deleteServiceAccount: ReturnType<typeof vi.fn>;
} {
  return {
    createProject: vi.fn().mockResolvedValue({ projectId: "proj_1" }),
    createServiceAccount: vi
      .fn()
      .mockResolvedValue({ key: "sk-svcacct-XYZ", serviceAccountId: "svc_1" }),
    setRateLimit: vi.fn().mockResolvedValue(undefined),
    deleteServiceAccount: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as never;
}

describe("mintBrainKey", () => {
  it("mints an isolated OpenAI key for a customer and returns the box-side config", async () => {
    const d = deps();
    const r = await mintBrainKey({ customerSlug: "acme-co" }, d);
    expect(r).toEqual({
      provider: "openai",
      envVar: "OPENAI_API_KEY",
      key: "sk-svcacct-XYZ",
      model: "gpt-5.5",
      projectId: "proj_1",
      serviceAccountId: "svc_1",
      rateLimited: true,
    });
  });

  it("creates the project BEFORE the service account (the SA needs the project id)", async () => {
    const order: string[] = [];
    const d = deps({
      createProject: vi.fn().mockImplementation(async () => (order.push("project"), { projectId: "proj_1" })),
      createServiceAccount: vi
        .fn()
        .mockImplementation(async () => (order.push("sa"), { key: "sk-svcacct-XYZ", serviceAccountId: "svc_1" })),
    });
    await mintBrainKey({ customerSlug: "x" }, d);
    expect(order).toEqual(["project", "sa"]);
  });

  it("names the project and service account for the customer slug", async () => {
    const d = deps();
    await mintBrainKey({ customerSlug: "acme-co" }, d);
    expect(d.createProject).toHaveBeenCalledWith("customer-acme-co");
    expect(d.createServiceAccount).toHaveBeenCalledWith("proj_1", "agent-acme-co");
  });

  it("applies the DEFAULT rate-limit guard (rpm 200 / tpm 400k) when none is requested", async () => {
    const d = deps();
    await mintBrainKey({ customerSlug: "x" }, d);
    expect(d.setRateLimit).toHaveBeenCalledWith("proj_1", DEFAULT_RATE_LIMIT);
    expect(DEFAULT_RATE_LIMIT).toEqual({ rpm: 200, tpm: 400_000 });
  });

  it("applies the rate-limit guard with the requested caps", async () => {
    const d = deps();
    await mintBrainKey({ customerSlug: "x", rateLimit: { rpm: 200, tpm: 400000 } }, d);
    expect(d.setRateLimit).toHaveBeenCalledWith("proj_1", { rpm: 200, tpm: 400000 });
  });

  it("never loses a minted key if the rate-limit call fails (key is irreversible; guard is best-effort)", async () => {
    const d = deps({ setRateLimit: vi.fn().mockRejectedValue(new Error("rate limit api down")) });
    const r = await mintBrainKey({ customerSlug: "x" }, d);
    expect(r.key).toBe("sk-svcacct-XYZ");
    expect(r.rateLimited).toBe(false); // flagged so the operator can retry the guard
  });

  it("propagates a project-create failure without minting a key", async () => {
    const d = deps({ createProject: vi.fn().mockRejectedValue(new Error("admin key invalid")) });
    await expect(mintBrainKey({ customerSlug: "x" }, d)).rejects.toThrow(/admin key invalid/);
    expect(d.createServiceAccount).not.toHaveBeenCalled();
  });

  it("allows overriding the model (e.g. gpt-5.5-pro for a premium tier)", async () => {
    const d = deps();
    const r = await mintBrainKey({ customerSlug: "x", model: "gpt-5.5-pro" }, d);
    expect(r.model).toBe("gpt-5.5-pro");
  });
});

describe("revokeBrainKey", () => {
  it("deletes the service account to kill one customer (no fleet effect)", async () => {
    const d = deps();
    await revokeBrainKey({ projectId: "proj_1", serviceAccountId: "svc_1" }, d);
    expect(d.deleteServiceAccount).toHaveBeenCalledWith("proj_1", "svc_1");
  });
});
