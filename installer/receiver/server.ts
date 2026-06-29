/**
 * Operator receiver (the minting engine's box-side endpoint). Runs ON the
 * operator's OWN box, installed over SSH. It does two jobs:
 *
 * 1. The Composio session engine (the NEWER on-demand mint + refresh/reconcile
 *    engine, kept intact):
 *      POST /refresh-session  { userId }   -> expand that user's existing Tool
 *                                             Router session to the union of their
 *                                             ACTIVE connections (same mcp.url).
 *      POST/GET /composio-webhook          -> Composio fires
 *                                             connected_account.expired; we refresh
 *                                             (the refresh drops the inactive toolkit).
 *
 * 2. The console's read/mint surface (vendored from the operator console; the
 *    console is a thin password-gated proxy that forwards these with x-sim-secret):
 *      GET  /fleet      -> the agent registry + per-agent status/freshness.
 *      GET  /dashboard  -> spend / revenue / ROI / value-created aggregate.
 *      POST /mint       -> the on-demand mint action (runs mint_client_agent.sh).
 *
 * Secrets come ONLY from process.env (COMPOSIO_API_KEY, SIM_SECRET,
 * SESSION_STORE_FILE, and the best-effort OPENAI_ADMIN_KEY / HETZNER_TOKEN read
 * tokens). On the box, systemd loads those from the receiver's own provision env
 * file (NOT the agent's ~/.hermes/.env).
 *
 * Run:  SIM_SECRET=... COMPOSIO_API_KEY=... npx tsx receiver/server.ts
 */
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Composio } from "@composio/core";
import { makeSessionStore } from "../src/connect/session-store.js";
import { makeRefreshSdk, type ComposioRefreshSubset } from "../src/connect/refresh-session-sdk.js";
import { refreshSessionToolkits } from "../src/connect/refresh-session.js";
import { handleConnectionCompleted } from "../src/connect/handle-connection-completed.js";
import { makeAgentRegistry } from "../src/registry/agent-registry.js";
import { aggregateDashboard } from "../src/dashboard/aggregate.js";
import { rollupTeams, teamOf } from "../src/dashboard/teams.js";
import { makeActivityLog } from "../src/activity/activity-log.js";
import { aggregateActivity, ATTRIBUTION_WEIGHT, VALUE_PER_ACTION } from "../src/activity/aggregate.js";
import { parseAgentProfiles, resolveMintSkills } from "../src/registry/agent-profiles.js";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.SIM_PORT ?? 8788);
const SECRET = process.env.SIM_SECRET ?? "dev-secret"; // default warns if unset; set before exposing
const COMPOSIO_API_KEY = process.env.COMPOSIO_API_KEY ?? "";
const SESSION_STORE_FILE = process.env.SESSION_STORE_FILE ?? join(here, "session-store.json");

// Console data files (box-local state; the console proxies read these via /fleet + /dashboard).
const REGISTRY_FILE = process.env.REGISTRY_FILE ?? join(here, "registry.jsonl");
const ACTIVITY_FILE = process.env.ACTIVITY_FILE ?? join(here, "activity.jsonl");
// Per-agent freshness snapshot (Hermes version + last self-update), written on a timer so /fleet
// stays fast. Last line per slug wins; a missing file is just "unknown freshness".
const STATUS_FILE = process.env.STATUS_FILE ?? join(here, "status.jsonl");
// The on-demand mint action: the console POSTs /mint, which shells this. It derives the
// per-person-email user_id, names the box <person>-<account>, provisions + gates + sessions.
const MINT_SCRIPT = process.env.MINT_SCRIPT ?? join(here, "../../scripts/mint_client_agent.sh");

if (!process.env.SIM_SECRET) {
  console.warn("[receiver] SIM_SECRET unset; using 'dev-secret'. Set one before exposing this.");
}

// refreshDeps is null when COMPOSIO_API_KEY is unset, which makes the connect routes 503 loudly
// instead of pretending to refresh.
const _composio = COMPOSIO_API_KEY ? new Composio({ apiKey: COMPOSIO_API_KEY }) : null;
const refreshDeps = _composio
  ? {
      store: makeSessionStore(SESSION_STORE_FILE),
      refresh: (sessionId: string, userId: string) =>
        refreshSessionToolkits(
          makeRefreshSdk(_composio as unknown as ComposioRefreshSubset),
          { sessionId, userId },
        ),
    }
  : null;

const registry = makeAgentRegistry(REGISTRY_FILE);
const activityLog = makeActivityLog(ACTIVITY_FILE);

function bad(res: import("node:http").ServerResponse, code: number, error: string): void {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify({ error }));
}

function authed(req: import("node:http").IncomingMessage): boolean {
  return (req.headers["x-sim-secret"] ?? "") === SECRET;
}

// slugify mirrors mint_client_agent.sh: lowercase, non-alnum -> single dash, trim dashes. Used to
// reproduce the box slug for the registry record (the script names the box <person>-<account>).
function slugify(s: string): string {
  return String(s ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

// Latest freshness row per slug, read per request so a timer-written file is always current.
function latestStatusBySlug(): Record<string, { hermesVersion?: string; updatedAt?: string; commitsBehind?: number }> {
  if (!existsSync(STATUS_FILE)) return {};
  const out: Record<string, { hermesVersion?: string; updatedAt?: string; commitsBehind?: number }> = {};
  for (const line of readFileSync(STATUS_FILE, "utf8").split("\n")) {
    const t = line.trim();
    if (!t) continue;
    try {
      const r = JSON.parse(t) as { slug?: string; hermesVersion?: string; updatedAt?: string; commitsBehind?: number };
      if (r && typeof r.slug === "string")
        out[r.slug] = { hermesVersion: r.hermesVersion, updatedAt: r.updatedAt, commitsBehind: r.commitsBehind };
    } catch {
      /* skip */
    }
  }
  return out;
}

// Attribution weights, re-read per request so the operator can tune them (weights.json of
// { capability: weight }) without a restart. Merged over the shipped defaults (empty by default;
// the operator's capability ids are their own, so there is no built-in catalog).
function attributionWeights(): Record<string, number> {
  const f = process.env.ATTRIBUTION_FILE ?? join(here, "weights.json");
  try {
    const override = existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as Record<string, number>) : {};
    return { ...ATTRIBUTION_WEIGHT, ...override };
  } catch {
    return { ...ATTRIBUTION_WEIGHT };
  }
}

// Per-action dollar rates, re-read per request so the operator can tune them (rates.json of
// { capability: usdPerAction }) without a restart. Merged over the shipped defaults (empty by
// default: the operator's skill/capability ids are their own, so there is no built-in rate card).
function valuePerAction(): Record<string, number> {
  const f = process.env.RATES_FILE ?? join(here, "rates.json");
  try {
    const override = existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as Record<string, number>) : {};
    return { ...VALUE_PER_ACTION, ...override };
  } catch {
    return { ...VALUE_PER_ACTION };
  }
}

// Per-team flat retainers ({ team: monthlyUsd }), re-read per request so the operator can re-price
// without a restart. Empty by default; an unlisted team falls back to summed per-seat prices.
function teamRetainers(): Record<string, number> {
  const f = process.env.RETAINERS_FILE ?? join(here, "retainers.json");
  try {
    return existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as Record<string, number>) : {};
  } catch {
    return {};
  }
}

/**
 * Month-to-date OpenAI usage per client (slug): spend (USD) AND tokens. We mint a project named
 * `customer-<slug>` per client, so both are directly attributable by project_id. Best-effort: any
 * failure returns empty maps so the dashboard still shows revenue + box cost. The admin key stays
 * on this box. A seeded tokens file (TOKENS_FILE, { slug: tokens }) backs slugs with no usage yet.
 */
async function openaiUsageBySlug(): Promise<{ spend: Record<string, number>; tokens: Record<string, number> }> {
  const seeded: Record<string, number> = (() => {
    const f = process.env.TOKENS_FILE ?? join(here, "tokens.json");
    try {
      return existsSync(f) ? (JSON.parse(readFileSync(f, "utf8")) as Record<string, number>) : {};
    } catch {
      return {};
    }
  })();
  const key = process.env.OPENAI_ADMIN_KEY;
  if (!key) return { spend: {}, tokens: { ...seeded } };
  try {
    const headers = { Authorization: `Bearer ${key}` };
    const projRes = await fetch("https://api.openai.com/v1/organization/projects?limit=100", { headers });
    if (!projRes.ok) return { spend: {}, tokens: { ...seeded } };
    const projects = ((await projRes.json()) as { data?: Array<{ id?: string; name?: string }> }).data ?? [];
    const slugByProject: Record<string, string> = {};
    for (const p of projects) {
      if (p.id && typeof p.name === "string" && p.name.startsWith("customer-")) {
        slugByProject[p.id] = p.name.slice("customer-".length);
      }
    }
    const now = new Date();
    const monthStart = Math.floor(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1) / 1000);
    const q = `start_time=${monthStart}&group_by[]=project_id&limit=180`;
    const spend: Record<string, number> = {};
    const tokens: Record<string, number> = { ...seeded };

    const costRes = await fetch(`https://api.openai.com/v1/organization/costs?${q}`, { headers });
    if (costRes.ok) {
      const buckets = ((await costRes.json()) as {
        data?: Array<{ results?: Array<{ project_id?: string; amount?: { value?: number } }> }>;
      }).data ?? [];
      for (const b of buckets) {
        for (const r of b.results ?? []) {
          const slug = r.project_id ? slugByProject[r.project_id] : undefined;
          if (slug) spend[slug] = (spend[slug] ?? 0) + (r.amount?.value ?? 0);
        }
      }
    }

    const usageRes = await fetch(`https://api.openai.com/v1/organization/usage/completions?${q}`, { headers });
    if (usageRes.ok) {
      const buckets = ((await usageRes.json()) as {
        data?: Array<{ results?: Array<{ project_id?: string; input_tokens?: number; output_tokens?: number }> }>;
      }).data ?? [];
      for (const b of buckets) {
        for (const r of b.results ?? []) {
          const slug = r.project_id ? slugByProject[r.project_id] : undefined;
          const t = (r.input_tokens ?? 0) + (r.output_tokens ?? 0);
          if (slug && t > 0) tokens[slug] = t; // real usage overrides the seed
        }
      }
    }
    return { spend, tokens };
  } catch {
    return { spend: {}, tokens: { ...seeded } };
  }
}

/**
 * Best-effort live box status per agent, keyed by slug. The cloud-host token stays HERE on the box
 * and never reaches the console web app. A missing token or any error returns an empty map, so
 * /fleet still serves the registry metadata (status falls back to "unknown").
 */
async function hostStatusBySlug(): Promise<Record<string, { status: string; ip: string }>> {
  const token = process.env.HETZNER_TOKEN ?? "";
  if (!token) return {};
  try {
    const res = await fetch("https://api.hetzner.cloud/v1/servers", {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return {};
    const body = (await res.json()) as {
      servers?: Array<{ name?: string; status?: string; public_net?: { ipv4?: { ip?: string } } }>;
    };
    const map: Record<string, { status: string; ip: string }> = {};
    for (const s of body.servers ?? []) {
      if (s.name) map[s.name] = { status: s.status ?? "unknown", ip: s.public_net?.ipv4?.ip ?? "" };
    }
    return map;
  } catch {
    return {};
  }
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

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");

  // Liveness.
  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, refresh: refreshDeps !== null }));
    return;
  }

  // The instant path: the onboarding page pings this on a new connect (GR1).
  if (req.method === "POST" && url.pathname === "/refresh-session") {
    if (!authed(req)) return bad(res, 401, "bad sim secret");
    if (!refreshDeps) return bad(res, 503, "COMPOSIO_API_KEY not set on receiver");
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      let body: { userId?: string };
      try {
        body = JSON.parse(raw || "{}");
      } catch {
        res.writeHead(400, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "bad json" }));
        return;
      }
      handleConnectionCompleted(refreshDeps, { userId: body.userId })
        .then((out) => {
          console.log(`[refresh-session] ${body.userId ?? "?"} -> ${JSON.stringify(out)}`);
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify(out));
        })
        .catch((e) => {
          res.writeHead(500, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: e instanceof Error ? e.message : "refresh error" }));
        });
    });
    return;
  }

  // Companion path: Composio's expiry webhook. Composio does NOT fire on a NEW
  // connection (GR1); it DOES fire connected_account.expired, on which we refresh
  // the user's session (the refresh naturally drops the now-inactive toolkit).
  // Always 200 + log so a webhook delivery is never retried into a storm.
  if (url.pathname === "/composio-webhook") {
    if (req.method === "GET") {
      // challenge/verification handshake
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(url.searchParams.get("challenge") ?? "ok");
      return;
    }
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      try {
        appendFileSync(
          join(here, "composio-webhook.log"),
          JSON.stringify({ at: new Date().toISOString(), body: raw }) + "\n",
        );
      } catch {
        // logging is best-effort; never fail the webhook on a disk hiccup
      }
      let userId: string | undefined;
      try {
        const b: {
          data?: {
            connectedAccount?: { user_id?: string };
            user_id?: string;
            connection?: { user_id?: string };
          };
          userId?: string;
          user_id?: string;
        } = JSON.parse(raw || "{}");
        userId =
          b?.data?.connectedAccount?.user_id ??
          b?.data?.user_id ??
          b?.data?.connection?.user_id ??
          b?.userId ??
          b?.user_id;
      } catch {
        // unparseable body: nothing to act on, still 200 below
      }
      if (userId && refreshDeps) {
        handleConnectionCompleted(refreshDeps, { userId })
          .then((o) => console.log(`[composio-webhook] ${userId} -> ${JSON.stringify(o)}`))
          .catch((e) => console.log(`[composio-webhook] ${userId} refresh err: ${e?.message}`));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
    return;
  }

  // Fleet tab data: every recorded agent + best-effort live status + freshness. Authed by the
  // shared secret (the console's server-side proxy holds it; status falls back to "unknown").
  if (req.method === "GET" && url.pathname === "/fleet") {
    if (!authed(req)) return bad(res, 401, "bad sim secret");
    Promise.all([registry.list(), hostStatusBySlug()])
      .then(([agents, status]) => {
        const fresh = latestStatusBySlug();
        const fleet = agents.map((a) => ({
          ...a,
          status: status[a.slug]?.status ?? "unknown",
          ip: status[a.slug]?.ip ?? "",
          hermesVersion: fresh[a.slug]?.hermesVersion,
          updatedAt: fresh[a.slug]?.updatedAt,
          commitsBehind: fresh[a.slug]?.commitsBehind,
        }));
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ fleet }));
      })
      .catch((e) => bad(res, 500, e instanceof Error ? e.message : "fleet error"));
    return;
  }

  // Dashboard tab data: per-client spend (OpenAI + box) + revenue + ROI + value-created. Authed by
  // the shared secret. All keys (OpenAI admin, cloud host) stay here on the box.
  if (req.method === "GET" && url.pathname === "/dashboard") {
    if (!authed(req)) return bad(res, 401, "bad sim secret");
    Promise.all([registry.list(), hostStatusBySlug(), openaiUsageBySlug(), activityLog.list()])
      .then(([agents, status, usage, activity]) => {
        const withStatus = agents.map((a) => ({ ...a, status: status[a.slug]?.status ?? "unknown" }));
        const data = aggregateDashboard({
          agents: withStatus,
          openaiSpendBySlug: usage.spend,
          boxMonthlyUsd: Number(process.env.BOX_MONTHLY_USD ?? 8),
        });
        const act = aggregateActivity({
          actions: activity,
          valuePerAction: valuePerAction(),
          attributionWeight: attributionWeights(),
        });
        // Merge value-created + ROT (Return on Tokens = value per million tokens) into each client.
        const clients = data.clients.map((c) => {
          const valueCreated = act.valueBySlug[c.slug] ?? 0; // raw: human + agent together
          const attributedValue = act.attributedBySlug[c.slug] ?? 0; // agent's weighted share
          const tokens = Number(usage.tokens[c.slug]) || 0;
          const mtok = tokens / 1_000_000;
          return {
            ...c,
            team: teamOf(c.email), // server-authoritative grouping (console mirrors this)
            valueCreated,
            attributedValue,
            tokens,
            rawRoi: c.totalCost > 0 ? valueCreated / c.totalCost : 0, // raw return multiple (x cost)
            rot: mtok > 0 ? attributedValue / mtok : 0, // WEIGHTED Return on Tokens ($/Mtok)
            costPerMtok: mtok > 0 ? (c.openaiSpend ?? 0) / mtok : 0,
          };
        });
        // Team P&L: revenue is a flat retainer per team (unlimited seats), not per-seat price.
        const { teams, revenue } = rollupTeams({ clients, retainerByTeam: teamRetainers() });
        const totalTokens = Object.values(usage.tokens).reduce((a, b) => a + (Number(b) || 0), 0);
        const fleetMtok = totalTokens / 1_000_000;
        const out = {
          clients,
          teams,
          totals: {
            ...data.totals,
            revenue, // team-retainer revenue (flat per team), overrides the per-seat sum
            roi: revenue - data.totals.totalCost, // operator profit (revenue - cost)
            valueCreated: act.totalValue,
            attributedValue: act.totalAttributedValue,
            actions: act.totalActions,
            tokens: totalTokens,
            rawRoi: data.totals.totalCost > 0 ? act.totalValue / data.totals.totalCost : 0,
            rot: fleetMtok > 0 ? act.totalAttributedValue / fleetMtok : 0, // weighted
            costPerMtok: fleetMtok > 0 ? data.totals.openaiSpend / fleetMtok : 0,
          },
          byCapability: act.byCapability,
          timeSeries: act.timeSeries,
        };
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(out));
      })
      .catch((e) => bad(res, 500, e instanceof Error ? e.message : "dashboard error"));
    return;
  }

  // New-agent tab: the on-demand mint. Runs mint_client_agent.sh (per-person-email user_id,
  // <person>-<account> box naming), then records the agent so it shows on the fleet + dashboard.
  // Authed; secret-bearing stderr is NEVER returned to the caller.
  if (req.method === "POST" && url.pathname === "/mint") {
    if (!authed(req)) return bad(res, 401, "bad sim secret");
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      let body: {
        personName?: string;
        email?: string;
        clientAccount?: string;
        agentName?: string;
        priceMonthly?: number;
        profile?: string;
        capabilities?: string[];
        needsKit?: boolean;
      };
      try {
        body = JSON.parse(raw || "{}");
      } catch {
        return bad(res, 400, "bad json");
      }
      const personName = String(body.personName ?? "").trim();
      const email = String(body.email ?? "").trim();
      const clientAccount = String(body.clientAccount ?? "").trim();
      if (!personName) return bad(res, 400, "personName required");
      if (!email) return bad(res, 400, "client email required");

      const args = ["--email", email, "--person-name", personName];
      if (clientAccount) args.push("--client-account", clientAccount);

      runMint(args)
        .then(async ({ code, stdout }) => {
          const ok = stdout.match(/MINT-OK user_id=(\S+) ip=(\S+)/);
          if (code !== 0 || !ok) {
            // Never leak env/secret-bearing stderr to the client.
            return bad(res, 502, "Mint failed. Check the operator box receiver logs.");
          }
          const slug = clientAccount
            ? `${slugify(personName)}-${slugify(clientAccount)}`
            : slugify(personName);
          const connect = stdout.match(/Onboarding link for .*?: (\S+)/);
          // The per-client brain refs (non-secret): the project the mint named customer-<slug> and
          // the service account inside it. Recorded so the dashboard's per-client spend ties out and
          // offboarding can revoke ONLY this client's brain. The minted key itself is never echoed.
          const brain = stdout.match(/BRAIN-OK project=(\S+) service_account=(\S+)/);
          const price = Number(body.priceMonthly);
          // AGENT-PROFILES build: every minted agent ships with the chosen profile's skills (a named
          // "build"), or the default profile when none is chosen (the mint floor), unioned with any
          // explicit capability ids the form passed. Profiles come from AGENT_PROFILES (operator-defined).
          const requested = Array.isArray(body.capabilities) ? body.capabilities.map(String) : [];
          const profilesConfig = parseAgentProfiles(process.env.AGENT_PROFILES);
          const capabilities = resolveMintSkills(profilesConfig, { profile: body.profile, extras: requested });
          await registry.record({
            slug,
            email,
            agentName: String(body.agentName ?? personName).trim() || personName,
            capabilities,
            loginUrl: connect ? connect[1] : "",
            priceMonthly: Number.isFinite(price) && price >= 0 ? price : undefined,
            brainProjectId: brain ? brain[1] : undefined,
            brainServiceAccountId: brain ? brain[2] : undefined,
          });
          res.writeHead(200, { "content-type": "application/json" });
          res.end(
            JSON.stringify({
              ok: true,
              slug,
              user_id: ok[1],
              ip: ok[2],
              connectUrl: connect ? connect[1] : "",
              agentName: String(body.agentName ?? personName).trim() || personName,
            }),
          );
        })
        .catch((e) => bad(res, 500, e instanceof Error ? e.message : "mint error"));
    });
    return;
  }

  res.writeHead(404, { "content-type": "text/plain" });
  res.end("not found");
});

server.listen(PORT, () => {
  console.log(`[receiver] http://localhost:${PORT}  store -> ${SESSION_STORE_FILE}`);
});
