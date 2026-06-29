/**
 * provision-brain-key CLI (production, OpenAI). The thin wiring around the tested
 * orchestrator (installer/src/brain-key). The operator's mint action runs this per client to
 * mint an ISOLATED, rate-limited OpenAI key AND pin it on that client's box in one process,
 * so the minted key never has to be printed or written to disk on this side. The ADMIN key
 * (sk-admin-...) is read from OPENAI_ADMIN_KEY, lives on the operator's OWN box ONLY, and is
 * never printed and never leaves here. On success it prints a NON-secret JSON summary
 * (projectId / serviceAccountId / model / rateLimited) for the caller to record.
 *
 *   mint:   npx tsx scripts/provision-brain-key.ts --slug dana-acme --ip 203.0.113.7 [--model gpt-5.5] [--rpm 200 --tpm 400000]
 *   revoke: npx tsx scripts/provision-brain-key.ts --revoke --project proj_x --service-account svc_y
 */
import { makeOpenAiAdminDeps } from "../src/brain-key/openai-admin-deps.js";
import { makeSshBrainWirer, provisionClientBrain } from "../src/brain-key/wire-box-brain.js";
import { revokeBrainKey } from "../src/brain-key/provision.js";

const ADMIN = process.env.OPENAI_ADMIN_KEY;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function flag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

async function main(): Promise<void> {
  if (!ADMIN) {
    console.error(
      "Set your OpenAI Admin key (OPENAI_ADMIN_KEY=sk-admin-...) so the mint can provision an " +
        "isolated, rate-limited brain for this client. The Admin key lives on the operator box only.",
    );
    process.exit(2);
  }

  const deps = makeOpenAiAdminDeps(ADMIN);

  if (flag("revoke")) {
    const projectId = arg("project");
    const serviceAccountId = arg("service-account");
    if (!projectId || !serviceAccountId) {
      console.error("revoke needs --project and --service-account");
      process.exit(1);
    }
    await revokeBrainKey({ projectId, serviceAccountId }, deps);
    console.log(JSON.stringify({ revoked: true, projectId, serviceAccountId }));
    return;
  }

  const customerSlug = arg("slug");
  const boxIp = arg("ip");
  if (!customerSlug || !boxIp) {
    console.error("usage: --slug <customer-slug> --ip <box-ip> [--model gpt-5.5] [--rpm N --tpm N]");
    process.exit(1);
  }

  const rpm = arg("rpm");
  const tpm = arg("tpm");
  const wireBox = makeSshBrainWirer({
    ssh: process.env.SSH || "ssh",
    sshKey: process.env.SSH_KEY || undefined,
    sshUser: process.env.SSH_USER || "root",
  });

  const result = await provisionClientBrain(
    {
      customerSlug,
      boxIp,
      model: arg("model"),
      rateLimit: rpm || tpm ? { rpm: rpm ? Number(rpm) : undefined, tpm: tpm ? Number(tpm) : undefined } : undefined,
    },
    { brain: deps, wireBox },
  );

  // NON-secret summary only. The minted key is NEVER printed: it went straight onto the box.
  console.log(JSON.stringify({ ok: true, customerSlug, ...result }));
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
