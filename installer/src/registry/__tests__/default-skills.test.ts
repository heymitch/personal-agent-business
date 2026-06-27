import { describe, it, expect } from "vitest";
import { parseDefaultSkills, mergeDefaultSkills } from "../default-skills";

describe("parseDefaultSkills", () => {
  it("splits, trims, and drops blanks", () => {
    expect(parseDefaultSkills(" repurpose , sales-followup ,, ")).toEqual(["repurpose", "sales-followup"]);
  });
  it("returns [] for undefined/empty", () => {
    expect(parseDefaultSkills(undefined)).toEqual([]);
    expect(parseDefaultSkills("")).toEqual([]);
  });
  it("de-dupes", () => {
    expect(parseDefaultSkills("repurpose,repurpose")).toEqual(["repurpose"]);
  });
});

describe("mergeDefaultSkills", () => {
  it("unions picker selection with defaults, picked first, de-duped", () => {
    expect(mergeDefaultSkills(["job-scan"], ["repurpose", "job-scan"])).toEqual(["job-scan", "repurpose"]);
  });
  it("applies defaults even when the picker is empty (the mint floor)", () => {
    expect(mergeDefaultSkills([], ["repurpose", "sales-followup"])).toEqual(["repurpose", "sales-followup"]);
  });
  it("keeps the picker selection when there are no defaults", () => {
    expect(mergeDefaultSkills(["trend-jack"], [])).toEqual(["trend-jack"]);
  });
});
