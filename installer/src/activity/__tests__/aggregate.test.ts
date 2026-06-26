import { describe, it, expect } from "vitest";
import { aggregateActivity, VALUE_PER_ACTION } from "../aggregate";

/**
 * aggregateActivity turns the raw activity log into "value created" plus the series the dashboard
 * charts: total + per-client value, a by-capability breakdown, and a daily time series. Pure.
 * Value of one record = its explicit valueUsd, else the capability's per-action rate, else 0.
 */
const acts = [
  { slug: "acme", capability: "repurpose", action: "LinkedIn post", at: "2026-06-14T10:00:00Z" },
  { slug: "acme", capability: "repurpose", action: "X thread", at: "2026-06-14T12:00:00Z" },
  { slug: "acme", capability: "sales-followup", action: "follow-up", valueUsd: 500, at: "2026-06-15T09:00:00Z" },
  { slug: "globex", capability: "job-scan", action: "weekly scan", at: "2026-06-15T08:00:00Z" },
];

describe("aggregateActivity", () => {
  it("totals value using capability rates and per-record overrides", () => {
    const a = aggregateActivity({ actions: acts });
    // 2 repurpose @150 + 1 follow-up override @500 + 1 job-scan @75
    expect(a.totalValue).toBe(150 + 150 + 500 + 75);
    expect(a.totalActions).toBe(4);
  });

  it("breaks value down per client", () => {
    const a = aggregateActivity({ actions: acts });
    expect(a.valueBySlug.acme).toBe(150 + 150 + 500);
    expect(a.valueBySlug.globex).toBe(75);
  });

  it("breaks down by capability, value-descending", () => {
    const a = aggregateActivity({ actions: acts });
    const repurpose = a.byCapability.find((c) => c.capability === "repurpose")!;
    expect(repurpose.actions).toBe(2);
    expect(repurpose.value).toBe(300);
    // sorted by value desc: sales-followup (500) first
    expect(a.byCapability[0].capability).toBe("sales-followup");
  });

  it("builds a daily time series in ascending date order", () => {
    const a = aggregateActivity({ actions: acts });
    expect(a.timeSeries.map((p) => p.date)).toEqual(["2026-06-14", "2026-06-15"]);
    expect(a.timeSeries[0].value).toBe(300); // two repurpose on the 14th
    expect(a.timeSeries[1].value).toBe(575); // 500 + 75 on the 15th
  });

  it("values an unknown capability with no override at 0 (no NaN)", () => {
    const a = aggregateActivity({ actions: [{ slug: "x", capability: "mystery", action: "?", at: "2026-06-15T00:00:00Z" }] });
    expect(a.totalValue).toBe(0);
    expect(Number.isNaN(a.totalValue)).toBe(false);
  });

  it("ships sensible default per-action rates for the shipped capabilities", () => {
    expect(VALUE_PER_ACTION.repurpose).toBeGreaterThan(0);
    expect(VALUE_PER_ACTION["sales-followup"]).toBeGreaterThan(0);
  });

  it("computes attributed (weighted) value: the agent's share, not the human's", () => {
    const a = aggregateActivity({ actions: acts });
    // repurpose @150 x0.8 x2 = 240; followup @500 x0.15 = 75; job-scan @75 x0.7 = 52.5
    expect(a.totalAttributedValue).toBeCloseTo(367.5, 5);
    // raw is unchanged (human + agent together)
    expect(a.totalValue).toBe(875);
    // per client: agent's attributed share
    expect(a.attributedBySlug.acme).toBeCloseTo(315, 5); // 120 + 120 + 75
    expect(a.attributedBySlug.globex).toBeCloseTo(52.5, 5);
  });

  it("carries the attribution weight per capability for transparency", () => {
    const a = aggregateActivity({ actions: acts });
    const closer = a.byCapability.find((c) => c.capability === "sales-followup")!;
    const writer = a.byCapability.find((c) => c.capability === "repurpose")!;
    expect(closer.weight).toBeLessThan(writer.weight); // sales is human-led, content is AI-led
    expect(writer.attributedValue).toBeCloseTo(writer.value * writer.weight, 5);
  });

  it("honors tunable weight overrides (the metric adjusts over time)", () => {
    const a = aggregateActivity({ actions: acts, attributionWeight: { repurpose: 1, "sales-followup": 1, "job-scan": 1 } });
    expect(a.totalAttributedValue).toBe(a.totalValue); // full credit when every weight is 1
  });
});
