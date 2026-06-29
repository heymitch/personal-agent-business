import type { BrainKeyDeps } from "./types";

/**
 * The real OpenAI org-API adapter behind BrainKeyDeps. The Admin key (sk-admin-...)
 * authorizes every call and lives on the operator's OWN box only; it is never passed to a
 * client box and never printed. All calls hit https://api.openai.com/v1/organization:
 *
 *   POST   /projects                                  -> create the per-customer project
 *   POST   /projects/{id}/service_accounts            -> mint the key (api_key.value, ONCE)
 *   GET    /projects/{id}/rate_limits                 -> resolve the row to update
 *   POST   /projects/{id}/rate_limits/{rlId}          -> apply the runaway guard
 *   DELETE /projects/{id}/service_accounts/{saId}     -> revoke one customer on offboarding
 *
 * `fetchImpl` is injectable so the adapter itself is testable without a network.
 */
export const OPENAI_ORG_BASE = "https://api.openai.com/v1/organization";

type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export function makeOpenAiAdminDeps(adminKey: string, fetchImpl: FetchLike = globalThis.fetch): BrainKeyDeps {
  if (!adminKey) throw new Error("makeOpenAiAdminDeps: an OpenAI Admin key is required");

  const api = async (method: string, path: string, body?: unknown): Promise<any> => {
    const res = await fetchImpl(`${OPENAI_ORG_BASE}${path}`, {
      method,
      headers: { Authorization: `Bearer ${adminKey}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`OpenAI Admin ${method} ${path} -> ${res.status} ${await res.text()}`);
    return res.status === 204 ? {} : res.json();
  };

  return {
    async createProject(name) {
      const d = await api("POST", "/projects", { name });
      return { projectId: d.id };
    },
    async createServiceAccount(projectId, name) {
      const d = await api("POST", `/projects/${projectId}/service_accounts`, { name });
      // The key is returned ONCE here as api_key.value.
      return { key: d.api_key.value, serviceAccountId: d.id };
    },
    async setRateLimit(projectId, limits) {
      // Rate limits are per-model and updated by id; resolve then update (best-effort).
      const list = await api("GET", `/projects/${projectId}/rate_limits`);
      const rl = (list.data ?? [])[0];
      if (!rl) throw new Error("no rate_limit row to update");
      const payload: Record<string, number> = {};
      if (limits.rpm != null) payload.max_requests_per_1_minute = limits.rpm;
      if (limits.tpm != null) payload.max_tokens_per_1_minute = limits.tpm;
      await api("POST", `/projects/${projectId}/rate_limits/${rl.id}`, payload);
    },
    async deleteServiceAccount(projectId, serviceAccountId) {
      await api("DELETE", `/projects/${projectId}/service_accounts/${serviceAccountId}`);
    },
  };
}
