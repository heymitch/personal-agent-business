/**
 * DEFAULT-SKILLS: the operator picks which of their skills EVERY newly minted client agent ships
 * with by default. Stored as DEFAULT_SKILLS (comma-separated capability ids) and applied as the
 * floor at mint time: the per-client picker selection is unioned with the defaults, so a new agent
 * always carries the operator's defaults even if the picker is left empty.
 */

/** Parse DEFAULT_SKILLS ("repurpose, sales-followup") into a clean, de-duped id list. */
export function parseDefaultSkills(raw: string | undefined): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const s of String(raw ?? "").split(",")) {
    const id = s.trim();
    if (id && !seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/**
 * Merge the per-client picker selection with the operator's default skills. Picked ids come first
 * (preserving their order), then any defaults not already picked. De-duped.
 */
export function mergeDefaultSkills(requested: string[], defaults: string[]): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  for (const id of [...requested, ...defaults]) {
    const v = String(id ?? "").trim();
    if (v && !seen.has(v)) {
      seen.add(v);
      out.push(v);
    }
  }
  return out;
}
