/**
 * POST /api/mint  ->  run the real on-demand provisioning.
 *
 * The operator console's "Mint an agent" button posts { clientAccount,
 * personName, personEmail } here. This shells the vendored mint action
 * (scripts/mint_client_agent.sh), which derives the per-PERSON-email user_id,
 * names the box <person-slug>-<account-slug>, provisions the box + Cloudflare
 * gate, creates the Tool Router session bound to that user_id, persists
 * userId -> sessionId via the SHIPPED session store, and surfaces the client's
 * onboarding link. No Stripe gate in v1 (operator-clicked on a closed call).
 *
 * Person name + email are required; client account is OPTIONAL (naming only;
 * it never enters the identity hash). Secrets are never returned to the client.
 */
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { spawn } from "node:child_process";
import { resolve } from "node:path";

const MINT_SCRIPT = resolve(process.cwd(), "scripts/mint_client_agent.sh");

interface MintResult {
  user_id: string;
  ip: string;
  connectUrl: string;
  box: string;
}

function runMint(args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolveRun) => {
    const child = spawn("bash", [MINT_SCRIPT, ...args], { env: process.env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("close", (code) => resolveRun({ code: code ?? 1, stdout, stderr }));
  });
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });

  const { clientAccount, personName, personEmail } = (req.body ?? {}) as {
    clientAccount?: string;
    personName?: string;
    personEmail?: string;
  };
  if (!personName || !personEmail) {
    return res.status(400).json({ error: "personName and personEmail are required" });
  }

  const args = ["--email", personEmail, "--person-name", personName];
  if (clientAccount && clientAccount.trim()) {
    args.push("--client-account", clientAccount.trim());
  }

  const { code, stdout, stderr } = await runMint(args);

  // The success token (mutation-proven) carries the minted identity + box ip.
  const mintOk = stdout.match(/MINT-OK user_id=(\S+) ip=(\S+)/);
  if (code !== 0 || !mintOk) {
    // Surface a clean failure; never leak env/secret-bearing stderr to the client.
    return res.status(502).json({ error: "Mint failed. Check the operator console logs." });
  }

  const connect = stdout.match(/Onboarding link for .*?: (\S+)/);
  const result: MintResult = {
    user_id: mintOk[1],
    ip: mintOk[2],
    connectUrl: connect ? connect[1] : "",
    box: "",
  };
  return res.status(200).json(result);
}
