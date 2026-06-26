/**
 * Receiver route smoke tests. These boot the real server module in a child
 * process (so its env is isolated) and hit the routes over loopback. They prove
 * the route SHAPE the extract names without touching Composio / the cloud host:
 *
 *  - GR1 instant path exists: POST /refresh-session is a real route.
 *  - Auth gate: a bad x-sim-secret is rejected 401 (the route is protected).
 *  - Deps gate: with no COMPOSIO_API_KEY the route 503s loudly (never pretends).
 *  - GR1 companion: GET /composio-webhook answers the challenge handshake.
 *  - Console surface: GET /fleet + GET /dashboard are auth-gated and return the
 *    empty (no agents recorded) shape the console renders.
 *  - Console surface: POST /mint is auth-gated.
 *
 * No COMPOSIO_API_KEY, HETZNER_TOKEN, or OPENAI_ADMIN_KEY is set, so refreshDeps
 * is null and every external read returns empty: nothing external is touched,
 * nothing is spent. The registry/activity/status files point at non-existent
 * temp paths so /fleet + /dashboard read as empty.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const serverPath = resolve(here, "../server.ts");
const tsxBin = resolve(here, "../../node_modules/.bin/tsx");
const PORT = 8911;
const SECRET = "test-secret";
const BASE = `http://127.0.0.1:${PORT}`;

let child: ChildProcess;

beforeAll(async () => {
  child = spawn(tsxBin, [serverPath], {
    env: {
      ...process.env,
      SIM_PORT: String(PORT),
      SIM_SECRET: SECRET,
      COMPOSIO_API_KEY: "", // deliberately empty: no real Composio, no spend
      HETZNER_TOKEN: "", // empty: hostStatusBySlug short-circuits, no network
      OPENAI_ADMIN_KEY: "", // empty: openaiUsageBySlug short-circuits, no network
      SESSION_STORE_FILE: resolve(here, "../session-store.test.json"),
      REGISTRY_FILE: resolve(here, "../registry.test-missing.jsonl"),
      ACTIVITY_FILE: resolve(here, "../activity.test-missing.jsonl"),
      STATUS_FILE: resolve(here, "../status.test-missing.jsonl"),
      TOKENS_FILE: resolve(here, "../tokens.test-missing.json"),
    },
    stdio: "ignore",
  });
  // Poll until the server answers /health.
  const deadline = Date.now() + 8000;
  for (;;) {
    try {
      const r = await fetch(`${BASE}/health`);
      if (r.ok) break;
    } catch {
      // not up yet
    }
    if (Date.now() > deadline) throw new Error("receiver did not start in time");
    await new Promise((r) => setTimeout(r, 150));
  }
}, 15000);

afterAll(() => {
  child?.kill("SIGKILL");
});

describe("receiver routes (the extract's two pieces, no Composio touched)", () => {
  it("GET /health reports refresh is disabled when no Composio key is set", async () => {
    const r = await fetch(`${BASE}/health`);
    const j = (await r.json()) as { ok: boolean; refresh: boolean };
    expect(r.status).toBe(200);
    expect(j.ok).toBe(true);
    expect(j.refresh).toBe(false);
  });

  it("POST /refresh-session rejects a bad sim secret (the route is protected)", async () => {
    const r = await fetch(`${BASE}/refresh-session`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-sim-secret": "WRONG" },
      body: JSON.stringify({ userId: "wm-abc" }),
    });
    expect(r.status).toBe(401);
  });

  it("POST /refresh-session 503s with the right secret but no Composio key (never fakes)", async () => {
    const r = await fetch(`${BASE}/refresh-session`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-sim-secret": SECRET },
      body: JSON.stringify({ userId: "wm-abc" }),
    });
    expect(r.status).toBe(503);
    const j = (await r.json()) as { error: string };
    expect(j.error).toMatch(/COMPOSIO_API_KEY/);
  });

  it("GET /composio-webhook answers the verification challenge (GR1 companion)", async () => {
    const r = await fetch(`${BASE}/composio-webhook?challenge=ping123`);
    expect(r.status).toBe(200);
    expect(await r.text()).toBe("ping123");
  });

  it("GET /fleet rejects a bad sim secret (the console proxy holds the real one)", async () => {
    const r = await fetch(`${BASE}/fleet`, { headers: { "x-sim-secret": "WRONG" } });
    expect(r.status).toBe(401);
  });

  it("GET /fleet returns the empty fleet shape with the right secret (no agents recorded)", async () => {
    const r = await fetch(`${BASE}/fleet`, { headers: { "x-sim-secret": SECRET } });
    expect(r.status).toBe(200);
    const j = (await r.json()) as { fleet: unknown[] };
    expect(Array.isArray(j.fleet)).toBe(true);
    expect(j.fleet).toEqual([]);
  });

  it("GET /dashboard rejects a bad sim secret", async () => {
    const r = await fetch(`${BASE}/dashboard`, { headers: { "x-sim-secret": "WRONG" } });
    expect(r.status).toBe(401);
  });

  it("GET /dashboard returns the empty aggregate shape with the right secret (no spend hit)", async () => {
    const r = await fetch(`${BASE}/dashboard`, { headers: { "x-sim-secret": SECRET } });
    expect(r.status).toBe(200);
    const j = (await r.json()) as {
      clients: unknown[];
      teams: unknown[];
      totals: { agents: number; revenue: number };
    };
    expect(j.clients).toEqual([]);
    expect(j.teams).toEqual([]);
    expect(j.totals.agents).toBe(0);
    expect(j.totals.revenue).toBe(0);
  });

  it("POST /mint rejects a bad sim secret (mint is protected, never runs unauthed)", async () => {
    const r = await fetch(`${BASE}/mint`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-sim-secret": "WRONG" },
      body: JSON.stringify({ personName: "Dana", email: "dana@example.com" }),
    });
    expect(r.status).toBe(401);
  });
});
