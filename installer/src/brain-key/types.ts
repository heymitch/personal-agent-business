/**
 * Per-customer brain-key provisioning (production path, OpenAI). Like the rest of the
 * installer, everything that touches the network is injected, so the orchestrator is pure
 * and testable. The Admin key that authorizes these calls lives on the operator's OWN box
 * ONLY and is never passed to a client box; the client box gets only the minted
 * service-account key.
 */
export interface BrainKeyRequest {
  /** DNS-safe customer slug (the SAME slug the box + dashboard use, so the project ties out). */
  customerSlug: string;
  /** Box brain model. Defaults to gpt-5.5. */
  model?: string;
  /** Optional per-customer rate-limit guard. */
  rateLimit?: { rpm?: number; tpm?: number };
}

export interface BrainKeyResult {
  provider: "openai";
  /** The env var the box sets to this key. */
  envVar: "OPENAI_API_KEY";
  /** The minted service-account key (sk-svcacct-...). Returned by OpenAI exactly once. */
  key: string;
  model: string;
  projectId: string;
  serviceAccountId: string;
  /** False when the rate-limit guard could not be applied (key still valid; retry the guard). */
  rateLimited: boolean;
}

export interface BrainKeyDeps {
  /** POST /v1/organization/projects -> the per-customer project. */
  createProject(name: string): Promise<{ projectId: string }>;
  /** POST /v1/organization/projects/{id}/service_accounts -> the key (once) + id. */
  createServiceAccount(projectId: string, name: string): Promise<{ key: string; serviceAccountId: string }>;
  /** POST .../rate_limits -> runaway guard. Best-effort; failure must not lose the key. */
  setRateLimit(projectId: string, limits: { rpm?: number; tpm?: number }): Promise<void>;
  /** DELETE .../service_accounts/{id} -> revoke one customer on offboarding. */
  deleteServiceAccount(projectId: string, serviceAccountId: string): Promise<void>;
}
