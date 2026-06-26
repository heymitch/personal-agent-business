import { describe, it, expect } from "vitest";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeAgentRegistry } from "../agent-registry";

/**
 * The mint registry is the metadata store the fleet view reads: one append-only record per
 * provisioned agent (the stuff the cloud host does NOT know: client email, agent name,
 * capabilities, login url, when it was built). Append-only and dedup-by-slug, so a re-provision of
 * the same slug supersedes the old record. File-backed; a missing or corrupt file reads as empty
 * and never throws (it must not be able to sink the pipeline).
 */
function tmpFile(): string {
  return join(mkdtempSync(join(tmpdir(), "pab-reg-")), "registry.jsonl");
}

const rec = {
  slug: "acme-agent",
  email: "founder@acme.com",
  agentName: "Acme's Agent",
  capabilities: ["repurpose"],
  loginUrl: "https://acme-agent.example.com",
};

describe("makeAgentRegistry", () => {
  it("records an agent and lists it back with a stamped createdAt", async () => {
    const reg = makeAgentRegistry(tmpFile(), { now: () => "2026-06-16T00:00:00.000Z" });
    await reg.record(rec);

    const all = await reg.list();
    expect(all).toHaveLength(1);
    expect(all[0]).toMatchObject({ ...rec, createdAt: "2026-06-16T00:00:00.000Z" });
  });

  it("lists an empty array when the file does not exist yet", async () => {
    const reg = makeAgentRegistry(tmpFile());
    expect(await reg.list()).toEqual([]);
  });

  it("dedupes by slug: a re-provision supersedes the old record (latest wins)", async () => {
    const file = tmpFile();
    let t = 0;
    const reg = makeAgentRegistry(file, { now: () => `2026-06-16T00:00:0${t++}.000Z` });
    await reg.record({ ...rec, agentName: "Old Name" });
    await reg.record({ ...rec, agentName: "New Name" });

    const all = await reg.list();
    expect(all).toHaveLength(1);
    expect(all[0].agentName).toBe("New Name");
  });

  it("keeps distinct slugs separate", async () => {
    const reg = makeAgentRegistry(tmpFile());
    await reg.record(rec);
    await reg.record({ ...rec, slug: "other-agent", agentName: "Other" });
    const slugs = (await reg.list()).map((r) => r.slug).sort();
    expect(slugs).toEqual(["acme-agent", "other-agent"]);
  });

  it("skips a corrupt line instead of throwing", async () => {
    const file = tmpFile();
    const reg = makeAgentRegistry(file);
    await reg.record(rec);
    // append a garbage line directly
    const { appendFileSync } = await import("node:fs");
    appendFileSync(file, "}{ not json\n");
    const all = await reg.list();
    expect(all).toHaveLength(1);
    expect(all[0].slug).toBe("acme-agent");
  });

  it("retire() marks a slug retired, preserving its metadata for the retired view", async () => {
    const file = tmpFile();
    let t = 0;
    const reg = makeAgentRegistry(file, { now: () => `2026-06-16T00:00:0${t++}.000Z` });
    await reg.record(rec); // createdAt ...00
    await reg.retire("acme-agent"); // retiredAt ...01

    const all = await reg.list();
    expect(all).toHaveLength(1); // still one slug (last-wins)
    expect(all[0]).toMatchObject({
      slug: "acme-agent",
      agentName: "Acme's Agent", // metadata preserved
      email: "founder@acme.com",
      retired: true,
      createdAt: "2026-06-16T00:00:00.000Z", // original build time kept
      retiredAt: "2026-06-16T00:00:01.000Z",
    });
  });

  it("retire() on an unknown slug writes a minimal retired stub (never throws)", async () => {
    const reg = makeAgentRegistry(tmpFile(), { now: () => "2026-06-16T00:00:00.000Z" });
    await reg.retire("ghost");
    const all = await reg.list();
    expect(all[0]).toMatchObject({ slug: "ghost", retired: true });
  });

  it("a re-provision after retirement brings the slug back (latest wins)", async () => {
    const file = tmpFile();
    let t = 0;
    const reg = makeAgentRegistry(file, { now: () => `2026-06-16T00:00:0${t++}.000Z` });
    await reg.record(rec);
    await reg.retire("acme-agent");
    await reg.record(rec); // re-built
    const all = await reg.list();
    expect(all).toHaveLength(1);
    expect(all[0].retired).toBeFalsy(); // active again
  });
});
