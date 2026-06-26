import { describe, it, expect } from "vitest";
import { aggregateDashboard } from "../aggregate";

/**
 * aggregateDashboard is the pure business math behind the operator dashboard: join each client's
 * price (revenue) with their costs (per-project OpenAI spend + a flat monthly box cost) into
 * per-client and total spend / revenue / ROI. Pure: all IO (the OpenAI costs API, the box list)
 * is resolved by the caller and passed in, so this is fully testable.
 */
describe("aggregateDashboard", () => {
  const agents = [
    { slug: "acme", agentName: "Acme", email: "a@acme.com", priceMonthly: 100, status: "running" },
    { slug: "globex", agentName: "Globex", email: "g@globex.com", priceMonthly: 50, status: "running" },
  ];

  it("computes per-client cost, revenue, and ROI", () => {
    const d = aggregateDashboard({
      agents,
      openaiSpendBySlug: { acme: 12, globex: 4 },
      boxMonthlyUsd: 8,
    });
    const acme = d.clients.find((c) => c.slug === "acme")!;
    expect(acme.priceMonthly).toBe(100);
    expect(acme.openaiSpend).toBe(12);
    expect(acme.boxCost).toBe(8);
    expect(acme.totalCost).toBe(20);
    expect(acme.roi).toBe(80); // 100 - 20
  });

  it("rolls up totals across all clients", () => {
    const d = aggregateDashboard({
      agents,
      openaiSpendBySlug: { acme: 12, globex: 4 },
      boxMonthlyUsd: 8,
    });
    expect(d.totals.agents).toBe(2);
    expect(d.totals.revenue).toBe(150); // 100 + 50
    expect(d.totals.openaiSpend).toBe(16); // 12 + 4
    expect(d.totals.boxCost).toBe(16); // 8 + 8
    expect(d.totals.totalCost).toBe(32);
    expect(d.totals.roi).toBe(118); // 150 - 32
  });

  it("defaults missing price + missing spend to 0 (no NaN)", () => {
    const d = aggregateDashboard({
      agents: [{ slug: "x", agentName: "X", email: "x@x.com" }],
      openaiSpendBySlug: {},
      boxMonthlyUsd: 8,
    });
    const x = d.clients[0];
    expect(x.priceMonthly).toBe(0);
    expect(x.openaiSpend).toBe(0);
    expect(x.roi).toBe(-8); // 0 - (0 + 8)
    expect(Number.isNaN(d.totals.roi)).toBe(false);
  });

  it("charges no box cost for a non-running agent", () => {
    const d = aggregateDashboard({
      agents: [{ slug: "off", agentName: "Off", email: "o@o.com", priceMonthly: 30, status: "off" }],
      openaiSpendBySlug: { off: 2 },
      boxMonthlyUsd: 8,
    });
    const off = d.clients[0];
    expect(off.boxCost).toBe(0);
    expect(off.totalCost).toBe(2);
    expect(off.roi).toBe(28);
  });
});
