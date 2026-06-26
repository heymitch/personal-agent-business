import { describe, it, expect, beforeEach } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeSessionStore } from "../session-store";

let file: string;
beforeEach(() => {
  file = join(mkdtempSync(join(tmpdir(), "wm-ss-")), "sessions.json");
});

describe("makeSessionStore (userId -> Tool Router sessionId)", () => {
  it("put then get returns the sessionId", async () => {
    const s = makeSessionStore(file);
    await s.put("wm-abc", "trs_1");
    expect(await s.get("wm-abc")).toBe("trs_1");
  });

  it("get returns null for an unknown user", async () => {
    expect(await makeSessionStore(file).get("nobody")).toBeNull();
  });

  it("put overwrites (re-provision mints a new session)", async () => {
    const s = makeSessionStore(file);
    await s.put("wm-abc", "trs_1");
    await s.put("wm-abc", "trs_2");
    expect(await s.get("wm-abc")).toBe("trs_2");
  });

  it("persists across instances (the webhook reads what provisioning wrote)", async () => {
    await makeSessionStore(file).put("wm-abc", "trs_1");
    expect(await makeSessionStore(file).get("wm-abc")).toBe("trs_1");
  });

  it("a corrupt file reads as empty, never throws mid-request", async () => {
    writeFileSync(file, "{ not json", "utf8");
    expect(await makeSessionStore(file).get("wm-abc")).toBeNull();
  });
});
