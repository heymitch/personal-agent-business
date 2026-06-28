/**
 * AGENT PROFILES: the operator defines named "builds", each a NAME + a set of THEIR OWN skill ids
 * (+ an optional description). Profiles drive both the agentize load stage (--profile) and the
 * console New-agent form (pick a profile = a default build). The public template ships ZERO operator
 * skills; every id here is operator-authored.
 *
 * This is the single source of truth the console API and the installer read the SAME way. The
 * canonical copy lives here (installer/src/registry/agent-profiles.ts) and is MIRRORED, content
 * for content, at surfaces/operator-console/lib/agent-profiles.ts (keep the two in sync, the same way
 * src/connect/user-id.ts mirrors surfaces/onboarding/lib/userid.ts).
 *
 * Stored as JSON in config/agent-profiles.json (gitignored; config/agent-profiles.example.json is the
 * neutral template) and surfaced to the console + receiver via the AGENT_PROFILES env var. Schema:
 *   { "profiles": [ { "name": string, "skills": string[], "description"?: string } ],
 *     "defaultProfile"?: string }
 */

export interface AgentProfile {
  name: string;
  skills: string[];
  description?: string;
}

export interface AgentProfilesConfig {
  profiles: AgentProfile[];
  defaultProfile?: string;
}

/** Clean a raw skills value: stringify, trim, drop blanks, de-dupe (order-preserving). */
function cleanSkills(raw: unknown): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  if (Array.isArray(raw)) {
    for (const s of raw) {
      const id = String(s ?? "").trim();
      if (id && !seen.has(id)) {
        seen.add(id);
        out.push(id);
      }
    }
  }
  return out;
}

/**
 * Parse the profiles config from a JSON string (the AGENT_PROFILES env var) or an already-parsed
 * object. NEVER throws: malformed input, or any structurally-invalid profile, is dropped, so the
 * result is always a clean config. A profile needs a non-empty, unique name; its skills are cleaned;
 * a blank or unknown defaultProfile is dropped (callers fall back to the first profile when needed).
 */
export function parseAgentProfiles(raw: string | object | undefined | null): AgentProfilesConfig {
  let obj: unknown = raw;
  if (typeof raw === "string") {
    const t = raw.trim();
    if (!t) return { profiles: [] };
    try {
      obj = JSON.parse(t);
    } catch {
      return { profiles: [] };
    }
  }
  if (!obj || typeof obj !== "object") return { profiles: [] };
  const src = obj as { profiles?: unknown; defaultProfile?: unknown };
  const seenNames = new Set<string>();
  const profiles: AgentProfile[] = [];
  if (Array.isArray(src.profiles)) {
    for (const p of src.profiles) {
      if (!p || typeof p !== "object") continue;
      const pp = p as { name?: unknown; skills?: unknown; description?: unknown };
      const name = String(pp.name ?? "").trim();
      if (!name || seenNames.has(name)) continue;
      seenNames.add(name);
      const profile: AgentProfile = { name, skills: cleanSkills(pp.skills) };
      const description = typeof pp.description === "string" ? pp.description.trim() : "";
      if (description) profile.description = description;
      profiles.push(profile);
    }
  }
  const dp = String(src.defaultProfile ?? "").trim();
  return dp && seenNames.has(dp) ? { profiles, defaultProfile: dp } : { profiles };
}

/**
 * Structural validation with human-readable errors (used by setup + tests). Pure, never throws.
 * Reports: bad JSON, non-object, missing/empty profiles, profiles without a name, duplicate names,
 * a missing skills array, and a defaultProfile that names no defined profile.
 */
export function validateAgentProfiles(raw: string | object | undefined | null): { ok: boolean; errors: string[] } {
  const errors: string[] = [];
  let obj: unknown = raw;
  if (typeof raw === "string") {
    const t = raw.trim();
    if (!t) return { ok: false, errors: ["empty profiles config"] };
    try {
      obj = JSON.parse(t);
    } catch {
      return { ok: false, errors: ["profiles config is not valid JSON"] };
    }
  }
  if (!obj || typeof obj !== "object") return { ok: false, errors: ["profiles config must be an object"] };
  const src = obj as { profiles?: unknown; defaultProfile?: unknown };
  if (!Array.isArray(src.profiles)) return { ok: false, errors: ["profiles must be an array"] };
  if (src.profiles.length === 0) errors.push("define at least one profile");
  const names = new Set<string>();
  src.profiles.forEach((p, i) => {
    if (!p || typeof p !== "object") {
      errors.push(`profile ${i} must be an object`);
      return;
    }
    const pp = p as { name?: unknown; skills?: unknown };
    const name = String(pp.name ?? "").trim();
    if (!name) errors.push(`profile ${i} needs a name`);
    else if (names.has(name)) errors.push(`duplicate profile name: ${name}`);
    else names.add(name);
    if (!Array.isArray(pp.skills)) errors.push(`profile ${name || i} needs a skills array`);
  });
  const dp = String(src.defaultProfile ?? "").trim();
  if (dp && !names.has(dp)) errors.push(`defaultProfile "${dp}" is not a defined profile`);
  return { ok: errors.length === 0, errors };
}

/** The named profile, or undefined. */
export function profileByName(config: AgentProfilesConfig, name: string | undefined | null): AgentProfile | undefined {
  const n = String(name ?? "").trim();
  if (!n) return undefined;
  return config.profiles.find((p) => p.name === n);
}

/** The skill ids for the named profile (empty if the profile is unknown). */
export function skillsForProfile(config: AgentProfilesConfig, name: string | undefined | null): string[] {
  return profileByName(config, name)?.skills ?? [];
}

/** The effective default profile NAME: the explicit defaultProfile, else the first profile, else undefined. */
export function defaultProfileName(config: AgentProfilesConfig): string | undefined {
  if (config.defaultProfile) return config.defaultProfile;
  return config.profiles[0]?.name;
}

/** The skill ids of the default profile (empty when no profiles are defined). */
export function defaultProfileSkills(config: AgentProfilesConfig): string[] {
  return skillsForProfile(config, defaultProfileName(config));
}

/**
 * Resolve the skills to load at mint time: the chosen profile's skills when a valid profile name is
 * given, else the DEFAULT profile's skills (the mint floor); then unioned with any explicit extra
 * capability ids. De-duped, order-preserving (profile skills first).
 */
export function resolveMintSkills(
  config: AgentProfilesConfig,
  opts: { profile?: string | null; extras?: string[] } = {},
): string[] {
  const base = profileByName(config, opts.profile)
    ? skillsForProfile(config, opts.profile)
    : defaultProfileSkills(config);
  const seen = new Set<string>();
  const out: string[] = [];
  for (const id of [...base, ...(opts.extras ?? [])]) {
    const v = String(id ?? "").trim();
    if (v && !seen.has(v)) {
      seen.add(v);
      out.push(v);
    }
  }
  return out;
}
