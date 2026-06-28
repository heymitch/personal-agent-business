import { describe, it, expect } from "vitest";
import {
  parseAgentProfiles,
  validateAgentProfiles,
  skillsForProfile,
  defaultProfileName,
  defaultProfileSkills,
  resolveMintSkills,
} from "../agent-profiles";

/**
 * agent-profiles is the single source of truth for the operator's named "builds" (profile = name +
 * their own skill ids + optional description). The console API and the receiver read it the SAME way.
 * The parser NEVER throws; the validator reports human-readable errors. No author skill ids appear
 * here; every id is a neutral placeholder.
 */

const sample = {
  profiles: [
    { name: "Starter", skills: ["alpha", "beta"], description: "small build" },
    { name: "Pro", skills: ["alpha", "beta", "gamma"] },
  ],
  defaultProfile: "Starter",
};

describe("parseAgentProfiles (valid)", () => {
  it("parses an object config and keeps profiles + defaultProfile", () => {
    const c = parseAgentProfiles(sample);
    expect(c.profiles.map((p) => p.name)).toEqual(["Starter", "Pro"]);
    expect(c.defaultProfile).toBe("Starter");
    expect(c.profiles[0].description).toBe("small build");
  });

  it("parses the same config from a JSON STRING (the AGENT_PROFILES env shape)", () => {
    const c = parseAgentProfiles(JSON.stringify(sample));
    expect(skillsForProfile(c, "Pro")).toEqual(["alpha", "beta", "gamma"]);
  });

  it("trims and de-dupes skill ids, order-preserving", () => {
    const c = parseAgentProfiles({ profiles: [{ name: "X", skills: [" a ", "a", "", "b"] }] });
    expect(skillsForProfile(c, "X")).toEqual(["a", "b"]);
  });

  it("drops a defaultProfile that names no defined profile", () => {
    const c = parseAgentProfiles({ profiles: [{ name: "X", skills: [] }], defaultProfile: "Ghost" });
    expect(c.defaultProfile).toBeUndefined();
  });
});

describe("parseAgentProfiles (invalid -> clean empty, never throws)", () => {
  it("returns an empty config for undefined / empty string", () => {
    expect(parseAgentProfiles(undefined)).toEqual({ profiles: [] });
    expect(parseAgentProfiles("")).toEqual({ profiles: [] });
  });

  it("returns an empty config for malformed JSON instead of throwing", () => {
    expect(parseAgentProfiles("{not json")).toEqual({ profiles: [] });
  });

  it("drops profiles that are missing a name or are not objects, and de-dupes names", () => {
    const c = parseAgentProfiles({
      profiles: [{ skills: ["a"] }, "nope", { name: "Keep", skills: ["a"] }, { name: "Keep", skills: ["b"] }],
    });
    expect(c.profiles.map((p) => p.name)).toEqual(["Keep"]);
    expect(skillsForProfile(c, "Keep")).toEqual(["a"]);
  });
});

describe("validateAgentProfiles", () => {
  it("accepts a well-formed config", () => {
    expect(validateAgentProfiles(sample)).toEqual({ ok: true, errors: [] });
  });

  it("rejects malformed JSON", () => {
    const r = validateAgentProfiles("{nope");
    expect(r.ok).toBe(false);
    expect(r.errors[0]).toMatch(/valid JSON/);
  });

  it("flags an empty profiles list, a nameless profile, a missing skills array, and a bad defaultProfile", () => {
    const r = validateAgentProfiles({ profiles: [{ skills: "x" }], defaultProfile: "Nope" });
    expect(r.ok).toBe(false);
    expect(r.errors.join(" ")).toMatch(/needs a name/);
    expect(r.errors.join(" ")).toMatch(/skills array/);
    expect(r.errors.join(" ")).toMatch(/defaultProfile/);
  });

  it("flags duplicate profile names", () => {
    const r = validateAgentProfiles({ profiles: [{ name: "A", skills: [] }, { name: "A", skills: [] }] });
    expect(r.ok).toBe(false);
    expect(r.errors.join(" ")).toMatch(/duplicate profile name/);
  });
});

describe("defaults + mint resolution", () => {
  it("defaultProfileName uses the explicit default, else the first profile", () => {
    expect(defaultProfileName(parseAgentProfiles(sample))).toBe("Starter");
    expect(defaultProfileName(parseAgentProfiles({ profiles: [{ name: "First", skills: [] }] }))).toBe("First");
    expect(defaultProfileName(parseAgentProfiles({ profiles: [] }))).toBeUndefined();
  });

  it("defaultProfileSkills returns the default profile's skills, empty when none defined", () => {
    expect(defaultProfileSkills(parseAgentProfiles(sample))).toEqual(["alpha", "beta"]);
    expect(defaultProfileSkills(parseAgentProfiles({ profiles: [] }))).toEqual([]);
  });

  it("resolveMintSkills picks the chosen profile's skills", () => {
    expect(resolveMintSkills(parseAgentProfiles(sample), { profile: "Pro" })).toEqual(["alpha", "beta", "gamma"]);
  });

  it("resolveMintSkills falls back to the default profile when the chosen name is unknown/blank", () => {
    const c = parseAgentProfiles(sample);
    expect(resolveMintSkills(c, { profile: "Ghost" })).toEqual(["alpha", "beta"]);
    expect(resolveMintSkills(c, {})).toEqual(["alpha", "beta"]);
  });

  it("resolveMintSkills unions the profile with explicit extras, de-duped, profile first", () => {
    const c = parseAgentProfiles(sample);
    expect(resolveMintSkills(c, { profile: "Starter", extras: ["beta", "delta"] })).toEqual(["alpha", "beta", "delta"]);
  });
});
