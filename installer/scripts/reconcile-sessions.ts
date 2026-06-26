/**
 * Reconcile cron (the backstop doorbell). For every provisioned user we have a
 * session for, expand their Tool Router session to the union of their ACTIVE
 * Composio connections. Catches connects made ANYWHERE (in-Slack via
 * MANAGE_CONNECTIONS, etc.), not just via the onboarding page. Idempotent;
 * keeps each agent's wired mcp.url stable (session.update in place).
 *
 * Run on a timer:  npx tsx scripts/reconcile-sessions.ts
 *
 * Secrets come ONLY from env. The optional PROVISION_ENV_FILE fallback points at
 * the receiver's OWN provision env file on the box (GR4: NOT the agent's
 * ~/.hermes/.env). There is no hardcoded box path here.
 */
import { Composio } from "@composio/core";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { makeRefreshSdk, type ComposioRefreshSubset } from "../src/connect/refresh-session-sdk";
import { refreshSessionToolkits } from "../src/connect/refresh-session";

function envVal(name: string): string {
  if (process.env[name]) return process.env[name] as string;
  // Optional fallback: the receiver's OWN provision env file (GR4), supplied via
  // PROVISION_ENV_FILE. No hardcoded path; absent var means "env-only".
  const p = process.env.PROVISION_ENV_FILE ?? "";
  if (!p) return "";
  try {
    const l = readFileSync(p, "utf8")
      .split("\n")
      .find((x) => x.startsWith(`${name}=`));
    return l ? l.slice(name.length + 1).trim().replace(/^['"]|['"]$/g, "") : "";
  } catch {
    return "";
  }
}

const apiKey = envVal("COMPOSIO_API_KEY");
if (!apiKey) {
  console.error("[reconcile] no COMPOSIO_API_KEY; nothing to do");
  process.exit(0);
}
const here = dirname(fileURLToPath(import.meta.url));
const storeFile = process.env.SESSION_STORE_FILE ?? resolve(here, "../receiver/session-store.json");

// The store is a flat { userId: sessionId } JSON map (makeSessionStore's format).
const map: Record<string, string> = existsSync(storeFile)
  ? JSON.parse(readFileSync(storeFile, "utf8") || "{}")
  : {};
const users = Object.keys(map);
console.log(`[reconcile] ${users.length} provisioned user(s) from ${storeFile}`);

const sdk = makeRefreshSdk(new Composio({ apiKey }) as unknown as ComposioRefreshSubset);
let refreshed = 0;
for (const userId of users) {
  try {
    const out = await refreshSessionToolkits(sdk, { sessionId: map[userId], userId });
    if (out.updated) {
      refreshed++;
      console.log(`[reconcile] ${userId} -> [${out.toolkits.join(", ")}]`);
    }
  } catch (e) {
    console.error(`[reconcile] ${userId} FAILED: ${(e as Error).message}`);
  }
}
console.log(`[reconcile] done; ${refreshed}/${users.length} sessions refreshed`);
