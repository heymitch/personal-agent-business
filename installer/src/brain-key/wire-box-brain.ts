import { execFile } from "node:child_process";
import { mintBrainKey, revokeBrainKey } from "./provision";
import type { BrainKeyDeps } from "./types";

/**
 * Pin a CLIENT box's brain to a minted, isolated OpenAI key. The provider is openai-api
 * with an EXPLICIT base_url (an OpenAI key cannot infer the endpoint: the proven footgun),
 * so we always set https://api.openai.com/v1. The key lands ONLY in ~/.hermes/.env on the
 * box and is written with a printf builtin so it never appears in any process argv.
 */
export const OPENAI_BRAIN_BASE_URL = "https://api.openai.com/v1";

/** Single-quote a value for safe embedding in a POSIX shell script (no argv exposure). */
function shSingleQuote(v: string): string {
  return `'${String(v).replace(/'/g, `'\\''`)}'`;
}

/**
 * The box-side script (run as the hermes user). Idempotent: it replaces OPENAI_API_KEY in
 * place, pins the brain to openai-api + base_url + model, and restarts the gateway. The key
 * and model are embedded as single-quoted literals; the whole script travels on ssh stdin.
 */
export function buildBoxBrainScript(brainKey: string, model: string): string {
  return [
    "set -e",
    'ENV="$HOME/.hermes/.env"',
    'mkdir -p "$(dirname "$ENV")"',
    'touch "$ENV"; chmod 600 "$ENV"',
    // idempotent key replace; printf is a builtin so the value never hits an execve argv
    'T="$(mktemp)"; grep -v "^OPENAI_API_KEY=" "$ENV" > "$T" 2>/dev/null || true',
    `printf 'OPENAI_API_KEY=%s\\n' ${shSingleQuote(brainKey)} >> "$T"; mv "$T" "$ENV"`,
    'export PATH="$HOME/.local/bin:$PATH"',
    "hermes config set model.provider openai-api",
    `hermes config set model.default ${shSingleQuote(model)}`,
    `hermes config set model.base_url ${OPENAI_BRAIN_BASE_URL}`,
    "hermes gateway restart >/dev/null 2>&1 || true",
    "echo BRAIN-WIRED",
  ].join("\n");
}

export interface WireBoxBrainRequest {
  boxIp: string;
  brainKey: string;
  model: string;
}

/** Wire one box's brain by handing the box-side script to an injected runner (ssh in prod). */
export async function wireBoxBrain(
  req: WireBoxBrainRequest,
  deps: { runScript: (boxIp: string, script: string) => Promise<void> },
): Promise<void> {
  await deps.runScript(req.boxIp, buildBoxBrainScript(req.brainKey, req.model));
}

/**
 * The real ssh runner: the secret-bearing script travels ONLY on ssh stdin (carried in a
 * local env var into a printf, never in argv on either host), exactly like the box-config
 * step. The box runs it as the hermes user.
 */
export function makeSshBrainWirer(
  opts: { ssh?: string; sshKey?: string; sshUser?: string } = {},
): (boxIp: string, brainKey: string, model: string) => Promise<void> {
  const ssh = opts.ssh ?? "ssh";
  const sshUser = opts.sshUser ?? "root";
  const runScript = (boxIp: string, script: string): Promise<void> => {
    const target = `${sshUser}@${boxIp}`;
    const sshArgs = ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15"];
    if (opts.sshKey) sshArgs.push("-i", opts.sshKey);
    // Run the script as hermes on the box; the script itself rides stdin via the env var.
    const remote = `${ssh} ${sshArgs.join(" ")} ${target} "su - hermes -c 'bash -s'"`;
    const child = execFile(
      "/bin/sh",
      ["-c", `printf %s "$BRAIN_WIRE_SCRIPT" | ${remote}`],
      { maxBuffer: 8 * 1024 * 1024, env: { ...process.env, BRAIN_WIRE_SCRIPT: script } },
    );
    return new Promise<void>((resolveP, rejectP) => {
      child.on("error", rejectP);
      child.on("close", (code) =>
        code === 0 ? resolveP() : rejectP(new Error(`brain wire exited ${code} on ${boxIp}`)),
      );
    });
  };
  return (boxIp, brainKey, model) => wireBoxBrain({ boxIp, brainKey, model }, { runScript });
}

export interface ProvisionClientBrainRequest {
  /** Same slug the box + dashboard use: the project becomes customer-<slug>, so spend ties out. */
  customerSlug: string;
  boxIp: string;
  model?: string;
  rateLimit?: { rpm?: number; tpm?: number };
}

export interface ProvisionClientBrainResult {
  projectId: string;
  serviceAccountId: string;
  model: string;
  rateLimited: boolean;
}

/**
 * Mint an isolated brain for one client and pin it on their box. Fail-soft + no half-mint:
 * if wiring the box fails, the just-minted key is rolled back (the service account is
 * deleted) so we never orphan an OpenAI project, then the original error is surfaced.
 */
export async function provisionClientBrain(
  req: ProvisionClientBrainRequest,
  deps: { brain: BrainKeyDeps; wireBox: (boxIp: string, brainKey: string, model: string) => Promise<void> },
): Promise<ProvisionClientBrainResult> {
  const minted = await mintBrainKey(
    { customerSlug: req.customerSlug, model: req.model, rateLimit: req.rateLimit },
    deps.brain,
  );
  try {
    await deps.wireBox(req.boxIp, minted.key, minted.model);
  } catch (wireErr) {
    try {
      await revokeBrainKey(
        { projectId: minted.projectId, serviceAccountId: minted.serviceAccountId },
        deps.brain,
      );
    } catch {
      // Best-effort rollback; surface the ORIGINAL wiring failure below.
    }
    throw wireErr;
  }
  return {
    projectId: minted.projectId,
    serviceAccountId: minted.serviceAccountId,
    model: minted.model,
    rateLimited: minted.rateLimited,
  };
}
