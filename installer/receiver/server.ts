/**
 * Operator receiver (the minting engine's session endpoint). Runs ON the
 * operator's OWN box, installed over SSH. It is the instant trigger the
 * onboarding page pings when a buyer connects a new app (Composio OAuth):
 *
 *   POST /refresh-session  { userId }       -> expand that user's existing Tool
 *                                              Router session to the union of
 *                                              their ACTIVE connections (same
 *                                              mcp.url, no box re-wire).
 *   POST/GET /composio-webhook              -> Composio does NOT fire on a NEW
 *                                              connection (GR1), but it DOES fire
 *                                              connected_account.expired, on which
 *                                              we refresh (the refresh naturally
 *                                              drops the now-inactive toolkit).
 *
 * Secrets come ONLY from process.env (COMPOSIO_API_KEY, SIM_SECRET,
 * SESSION_STORE_FILE). On the box, systemd loads those from the receiver's own
 * provision env file (GR4: NOT the agent's ~/.hermes/.env).
 *
 * Run:  SIM_SECRET=... COMPOSIO_API_KEY=... npx tsx receiver/server.ts
 */
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { Composio } from "@composio/core";
import { makeSessionStore } from "../src/connect/session-store.js";
import { makeRefreshSdk, type ComposioRefreshSubset } from "../src/connect/refresh-session-sdk.js";
import { refreshSessionToolkits } from "../src/connect/refresh-session.js";
import { handleConnectionCompleted } from "../src/connect/handle-connection-completed.js";

const here = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.SIM_PORT ?? 8788);
const SECRET = process.env.SIM_SECRET ?? "dev-secret"; // default warns if unset; set before exposing
const COMPOSIO_API_KEY = process.env.COMPOSIO_API_KEY ?? "";
const SESSION_STORE_FILE = process.env.SESSION_STORE_FILE ?? join(here, "session-store.json");

if (!process.env.SIM_SECRET) {
  console.warn("[receiver] SIM_SECRET unset; using 'dev-secret'. Set one before exposing this.");
}

// refreshDeps is null when COMPOSIO_API_KEY is unset, which makes the routes 503
// loudly instead of pretending to refresh.
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
    if ((req.headers["x-sim-secret"] ?? "") !== SECRET) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "bad sim secret" }));
      return;
    }
    if (!refreshDeps) {
      res.writeHead(503, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "COMPOSIO_API_KEY not set on receiver" }));
      return;
    }
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

  res.writeHead(404, { "content-type": "text/plain" });
  res.end("not found");
});

server.listen(PORT, () => {
  console.log(`[receiver] http://localhost:${PORT}  store -> ${SESSION_STORE_FILE}`);
});
