import { existsSync, readFileSync, appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * The agent activity log: one append-only record per unit of work an agent produced (a drafted
 * post, a sent follow-up, a scorecard). It is the substrate for "value created" on the dashboard:
 * count the work, multiply by what that work is worth. Append-only JSONL, file-backed like the
 * registry; a missing or corrupt file reads as empty and never throws.
 *
 * Records come from two places that land in the same log: the agents (auto, once wired) and the
 * operator's one-tap outcome capture (manual). Both shapes are the same row.
 */
export interface ActivityRecord {
  /** Which agent did the work (the box slug). */
  slug: string;
  /** The capability this work belongs to (maps to a per-action dollar value). */
  capability: string;
  /** A short human label, e.g. "LinkedIn post", "follow-up drafted". */
  action: string;
  /** Optional explicit dollar value for THIS record (overrides the capability rate). Revenue, time-saved-$, etc. */
  valueUsd?: number;
  /** ISO timestamp. */
  at: string;
}

export interface ActivityLog {
  record(a: Omit<ActivityRecord, "at"> & { at?: string }): Promise<void>;
  list(): Promise<ActivityRecord[]>;
}

export function makeActivityLog(filePath: string, opts: { now?: () => string } = {}): ActivityLog {
  const now = opts.now ?? (() => new Date().toISOString());
  return {
    async record(a) {
      mkdirSync(dirname(filePath), { recursive: true });
      const full: ActivityRecord = { ...a, at: a.at ?? now() };
      appendFileSync(filePath, JSON.stringify(full) + "\n", "utf8");
    },
    async list() {
      if (!existsSync(filePath)) return [];
      const out: ActivityRecord[] = [];
      for (const line of readFileSync(filePath, "utf8").split("\n")) {
        const t = line.trim();
        if (!t) continue;
        try {
          const r = JSON.parse(t) as ActivityRecord;
          if (r && typeof r.slug === "string" && typeof r.at === "string") out.push(r);
        } catch {
          // corrupt line: skip
        }
      }
      return out;
    },
  };
}
