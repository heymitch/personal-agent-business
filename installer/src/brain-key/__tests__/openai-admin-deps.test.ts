import { describe, it, expect, vi } from "vitest";
import { makeOpenAiAdminDeps, OPENAI_ORG_BASE } from "../openai-admin-deps";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

describe("makeOpenAiAdminDeps (real OpenAI org-API adapter)", () => {
  it("requires an admin key", () => {
    expect(() => makeOpenAiAdminDeps("")).toThrow(/Admin key/i);
  });

  it("creates a project via POST /v1/organization/projects with the Admin key in the header", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(jsonResponse({ id: "proj_123" }));
    const deps = makeOpenAiAdminDeps("sk-admin-SECRET", fetchImpl);
    const r = await deps.createProject("customer-acme");
    expect(r).toEqual({ projectId: "proj_123" });
    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe(`${OPENAI_ORG_BASE}/projects`);
    expect(OPENAI_ORG_BASE).toBe("https://api.openai.com/v1/organization");
    expect(init.method).toBe("POST");
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer sk-admin-SECRET");
    expect(init.body).toBe(JSON.stringify({ name: "customer-acme" }));
  });

  it("mints the service-account key from api_key.value (the key OpenAI returns once)", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(jsonResponse({ id: "svc_9", api_key: { value: "sk-svcacct-MINTED" } }));
    const deps = makeOpenAiAdminDeps("sk-admin-SECRET", fetchImpl);
    const r = await deps.createServiceAccount("proj_123", "agent-acme");
    expect(r).toEqual({ key: "sk-svcacct-MINTED", serviceAccountId: "svc_9" });
    const [url] = fetchImpl.mock.calls[0];
    expect(url).toBe(`${OPENAI_ORG_BASE}/projects/proj_123/service_accounts`);
  });

  it("resolves then updates the rate-limit row (rpm/tpm -> OpenAI per-minute fields)", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse({ data: [{ id: "rl_1" }] })) // GET list
      .mockResolvedValueOnce(jsonResponse({}, 200)); // POST update
    const deps = makeOpenAiAdminDeps("sk-admin-SECRET", fetchImpl);
    await deps.setRateLimit("proj_123", { rpm: 200, tpm: 400000 });
    const [listUrl, listInit] = fetchImpl.mock.calls[0];
    expect(listUrl).toBe(`${OPENAI_ORG_BASE}/projects/proj_123/rate_limits`);
    expect(listInit.method).toBe("GET");
    const [updUrl, updInit] = fetchImpl.mock.calls[1];
    expect(updUrl).toBe(`${OPENAI_ORG_BASE}/projects/proj_123/rate_limits/rl_1`);
    expect(updInit.body).toBe(
      JSON.stringify({ max_requests_per_1_minute: 200, max_tokens_per_1_minute: 400000 }),
    );
  });

  it("deletes a service account via DELETE (offboarding revoke)", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    const deps = makeOpenAiAdminDeps("sk-admin-SECRET", fetchImpl);
    await deps.deleteServiceAccount("proj_123", "svc_9");
    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe(`${OPENAI_ORG_BASE}/projects/proj_123/service_accounts/svc_9`);
    expect(init.method).toBe("DELETE");
  });

  it("throws with the status + body when the org API rejects the Admin key", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("forbidden", { status: 403 }));
    const deps = makeOpenAiAdminDeps("sk-admin-SECRET", fetchImpl);
    await expect(deps.createProject("customer-x")).rejects.toThrow(/403/);
  });
});
