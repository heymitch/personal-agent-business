import type { BrainKeyDeps, BrainKeyRequest, BrainKeyResult } from "./types";

/** Never mint an ungated key. Applied unless the caller overrides via req.rateLimit. */
export const DEFAULT_RATE_LIMIT = { rpm: 200, tpm: 400_000 };

/**
 * Mint an isolated OpenAI key for one customer (the per-client brain, production path).
 * Order matters: project first (the service account needs its id), then the service
 * account (which returns the key ONCE, so we capture it), then the rate-limit guard.
 * The guard is best-effort: the key is the irreversible artifact, so a guard failure is
 * flagged (rateLimited=false) and the key is still returned rather than orphaned.
 */
export async function mintBrainKey(req: BrainKeyRequest, deps: BrainKeyDeps): Promise<BrainKeyResult> {
  const { projectId } = await deps.createProject(`customer-${req.customerSlug}`);
  const { key, serviceAccountId } = await deps.createServiceAccount(projectId, `agent-${req.customerSlug}`);

  // Always apply a guard (default unless overridden). Best-effort: the key is already
  // minted, so a guard failure is flagged, never thrown (an orphaned key is worse).
  let rateLimited = false;
  try {
    await deps.setRateLimit(projectId, req.rateLimit ?? DEFAULT_RATE_LIMIT);
    rateLimited = true;
  } catch {
    rateLimited = false;
  }

  return {
    provider: "openai",
    envVar: "OPENAI_API_KEY",
    key,
    model: req.model ?? "gpt-5.5",
    projectId,
    serviceAccountId,
    rateLimited,
  };
}

/** Revoke one customer's brain on offboarding: delete the service account, nobody else affected. */
export async function revokeBrainKey(
  ref: { projectId: string; serviceAccountId: string },
  deps: Pick<BrainKeyDeps, "deleteServiceAccount">,
): Promise<void> {
  await deps.deleteServiceAccount(ref.projectId, ref.serviceAccountId);
}
