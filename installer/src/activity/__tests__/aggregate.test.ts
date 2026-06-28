import { describe, it, expect } from "vitest";
import { aggregateActivity, VALUE_PER_ACTION, ATTRIBUTION_WEIGHT } from "../aggregate";

/**
 * aggregateActivity turns the raw activity log into "value created" plus the series the dashboard
 * charts: total + per-client value, a by-capability breakdown, and a daily time series. Pure.
 * Value of one record = its explicit valueUsd, else the capability's per-action rate, else 0.
 *
 * The SHIPPED rate/weight maps are empty (the operator's capabilities are their OWN, no built-in
 * catalog); rates + weights are supplied per-call (the receiver loads them from rates.json /
 * weights.json). The capability ids below are NEUTRAL placeholders, not anyone's real skill set.
 */
const rates = { "content-draft": 150, "meeting-recap": 75 };
const weights = { "content-draft": 0.8, "meeting-recap": 0.7, "client-handoff": 0.15 };
const acts = [
  { slug: "acme", capability: "content-draft", action: "LinkedIn post", at: "2026-06-14T10:00:00Z" },
  { slug: "acme", capability: "content-draft", action: "X thread", at: "2026-06-14T12:00:00Z" },
  { slug: "acme", capability: "client-handoff", action: "follow-up", valueUsd: 500, at: "2026-06-15T09:00:00Z" },
  { slug: "globex", capability: "meeting-recap", action: "weekly scan", at: "2026-06-15T08:00:00Z" },
];

describe("aggregateActivity", () => {
  it("totals value using capability rates and per-record overrides", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates });
    // 2 content-draft @150 + 1 handoff override @500 + 1 meeting-recap @75
    expect(a.totalValue).toBe(150 + 150 + 500 + 75);
    expect(a.totalActions).toBe(4);
  });

  it("breaks value down per client", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates });
    expect(a.valueBySlug.acme).toBe(150 + 150 + 500);
    expect(a.valueBySlug.globex).toBe(75);
  });

  it("breaks down by capability, value-descending", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates });
    const draft = a.byCapability.find((c) => c.capability === "content-draft")!;
    expect(draft.actions).toBe(2);
    expect(draft.value).toBe(300);
    // sorted by value desc: client-handoff (500) first
    expect(a.byCapability[0].capability).toBe("client-handoff");
  });

  it("builds a daily time series in ascending date order", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates });
    expect(a.timeSeries.map((p) => p.date)).toEqual(["2026-06-14", "2026-06-15"]);
    expect(a.timeSeries[0].value).toBe(300); // two content-draft on the 14th
    expect(a.timeSeries[1].value).toBe(575); // 500 + 75 on the 15th
  });

  it("values an unknown capability with no override at 0 (no NaN)", () => {
    const a = aggregateActivity({ actions: [{ slug: "x", capability: "mystery", action: "?", at: "2026-06-15T00:00:00Z" }] });
    expect(a.totalValue).toBe(0);
    expect(Number.isNaN(a.totalValue)).toBe(false);
  });

  it("ships EMPTY default rate/weight maps (operator-tunable, no built-in catalog)", () => {
    expect(VALUE_PER_ACTION).toEqual({});
    expect(ATTRIBUTION_WEIGHT).toEqual({});
  });

  it("computes attributed (weighted) value: the agent's share, not the human's", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates, attributionWeight: weights });
    // content-draft @150 x0.8 x2 = 240; handoff @500 x0.15 = 75; meeting-recap @75 x0.7 = 52.5
    expect(a.totalAttributedValue).toBeCloseTo(367.5, 5);
    // raw is unchanged (human + agent together)
    expect(a.totalValue).toBe(875);
    // per client: agent's attributed share
    expect(a.attributedBySlug.acme).toBeCloseTo(315, 5); // 120 + 120 + 75
    expect(a.attributedBySlug.globex).toBeCloseTo(52.5, 5);
  });

  it("carries the attribution weight per capability for transparency", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates, attributionWeight: weights });
    const closer = a.byCapability.find((c) => c.capability === "client-handoff")!;
    const writer = a.byCapability.find((c) => c.capability === "content-draft")!;
    expect(closer.weight).toBeLessThan(writer.weight); // handoff is human-led, content is AI-led
    expect(writer.attributedValue).toBeCloseTo(writer.value * writer.weight, 5);
  });

  it("defaults an unweighted capability to full credit (1.0)", () => {
    const a = aggregateActivity({ actions: acts, valuePerAction: rates }); // no weights passed
    expect(a.totalAttributedValue).toBe(a.totalValue); // every weight defaults to 1
  });
});
