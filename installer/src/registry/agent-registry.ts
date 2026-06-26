import { existsSync, readFileSync, appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * The mint registry: one append-only record per provisioned agent. It holds the metadata the
 * server list does NOT (client email, agent name, capabilities, login url, build time), so the
 * fleet view can show a real agent card instead of just a box. The pipeline appends on a
 * successful provision; the fleet endpoint reads it.
 *
 * Append-only JSONL, deduped by slug on read (a re-provision of the same slug appends a fresh line
 * that supersedes the old one). File-backed: a missing or corrupt file reads as empty and never
 * throws, so it can never sink the pipeline.
 */
export interface AgentRecord {
  slug: string;
  email: string;
  agentName: string;
  capabilities: string[];
  loginUrl: string;
  /** What the operator charges this client per month (whole dollars). Drives revenue + ROI. */
  priceMonthly?: number;
  /** ISO timestamp, stamped at record time. */
  createdAt: string;
  /** True once the agent has been torn down. Retired agents drop out of the default fleet view. */
  retired?: boolean;
  /** ISO timestamp of when it was retired. */
  retiredAt?: string;
}

export interface AgentRegistry {
  record(rec: Omit<AgentRecord, "createdAt">): Promise<void>;
  /** Mark a slug retired (append-only, last-wins), preserving its metadata for the retired view. */
  retire(slug: string, opts?: { at?: string }): Promise<void>;
  /** Every recorded agent, deduped by slug (latest wins), newest first. */
  list(): Promise<AgentRecord[]>;
}

export function makeAgentRegistry(
  filePath: string,
  opts: { now?: () => string } = {},
): AgentRegistry {
  const now = opts.now ?? (() => new Date().toISOString());

  // Last line per slug wins; collect in file order, then return newest first.
  const readAll = (): AgentRecord[] => {
    if (!existsSync(filePath)) return [];
    const bySlug = new Map<string, AgentRecord>();
    for (const line of readFileSync(filePath, "utf8").split("\n")) {
      const t = line.trim();
      if (!t) continue;
      try {
        const r = JSON.parse(t) as AgentRecord;
        if (r && typeof r.slug === "string") bySlug.set(r.slug, r);
      } catch {
        // corrupt line: skip, never throw
      }
    }
    return [...bySlug.values()].sort((a, b) => (a.createdAt < b.createdAt ? 1 : -1));
  };

  return {
    async record(rec) {
      mkdirSync(dirname(filePath), { recursive: true });
      const full: AgentRecord = { ...rec, createdAt: now() };
      appendFileSync(filePath, JSON.stringify(full) + "\n", "utf8");
    },

    async retire(slug, retireOpts = {}) {
      const at = retireOpts.at ?? now();
      const existing = readAll().find((r) => r.slug === slug);
      // Preserve the original metadata (and createdAt) so the retired view still shows what it was.
      const rec: AgentRecord = existing
        ? { ...existing, retired: true, retiredAt: at }
        : { slug, email: "", agentName: slug, capabilities: [], loginUrl: "", createdAt: at, retired: true, retiredAt: at };
      mkdirSync(dirname(filePath), { recursive: true });
      appendFileSync(filePath, JSON.stringify(rec) + "\n", "utf8");
    },

    async list() {
      return readAll();
    },
  };
}
