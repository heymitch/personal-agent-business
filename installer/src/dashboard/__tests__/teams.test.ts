import { describe, it, expect } from "vitest";
import { teamOf, rollupTeams } from "../teams";

/**
 * rollupTeams collapses the per-client dashboard rows into per-TEAM P&L. Revenue is a flat team
 * retainer (unlimited seats: adding an agent to a retained team does NOT raise revenue, only a few
 * dollars of cost), falling back to the sum of per-agent prices for a self-serve team with no
 * retainer. This is what makes the "marginal agent is almost pure leverage" story real and is the
 * revenue axis the leverage quadrant reads.
 */
const clients = [
  // Bigco team: flat $7k retainer, 2 agents (unlimited seats)
  { slug: "agent-one", email: "a@bigco.com", status: "running", openaiSpend: 6, boxCost: 8, totalCost: 14, valueCreated: 400, attributedValue: 320, tokens: 3_000_000 },
  { slug: "agent-two", email: "b@bigco.com", status: "running", openaiSpend: 4, boxCost: 8, totalCost: 12, valueCreated: 2080, attributedValue: 312, tokens: 1_500_000 },
  // Internal: no retainer, no price -> 0 revenue
  { slug: "internal-test", email: "x@operator.local", status: "running", openaiSpend: 0, boxCost: 8, totalCost: 8, valueCreated: 0, attributedValue: 0, tokens: 0 },
  // Acme: self-serve, no retainer, per-agent price -> revenue = price
  { slug: "acme", email: "a@acme.com", status: "running", priceMonthly: 200, openaiSpend: 10, boxCost: 8, totalCost: 18, valueCreated: 600, attributedValue: 480, tokens: 2_000_000 },
];
const retainerByTeam = { Bigco: 7000 };

describe("teamOf", () => {
  it("buckets by email domain, matching the console grouping", () => {
    expect(teamOf("a@bigco.com")).toBe("Bigco");
    expect(teamOf("x@operator.local")).toBe("Internal");
    expect(teamOf("a@acme.com")).toBe("Acme");
    expect(teamOf("")).toBe("Unassigned");
  });
});

describe("rollupTeams", () => {
  it("applies a flat retainer once per team regardless of seat count (unlimited seats)", () => {
    const { teams } = rollupTeams({ clients, retainerByTeam });
    const bigco = teams.find((t) => t.team === "Bigco")!;
    expect(bigco.agents).toBe(2);
    expect(bigco.retainerMonthly).toBe(7000); // flat, NOT 2 x anything
    expect(bigco.isRetainer).toBe(true);
    expect(bigco.totalCost).toBe(26); // 14 + 12
    expect(bigco.profit).toBe(6974); // 7000 - 26
    expect(bigco.costPerAgent).toBe(13); // 26 / 2 -> the leverage story
  });

  it("falls back to summed per-agent price for a self-serve team with no retainer", () => {
    const { teams } = rollupTeams({ clients, retainerByTeam });
    const acme = teams.find((t) => t.team === "Acme")!;
    expect(acme.retainerMonthly).toBe(200); // the agent's price
    expect(acme.isRetainer).toBe(false);
    expect(acme.profit).toBe(182); // 200 - 18
  });

  it("gives a no-revenue team 0 revenue and a negative profit (cost only)", () => {
    const { teams } = rollupTeams({ clients, retainerByTeam });
    const internal = teams.find((t) => t.team === "Internal")!;
    expect(internal.retainerMonthly).toBe(0);
    expect(internal.profit).toBe(-8);
    expect(internal.marginPct).toBe(0); // no revenue -> margin 0, never NaN
  });

  it("rolls up value, attribution and weighted ROT per team", () => {
    const { teams } = rollupTeams({ clients, retainerByTeam });
    const bigco = teams.find((t) => t.team === "Bigco")!;
    expect(bigco.valueCreated).toBe(2480); // 400 + 2080
    expect(bigco.attributedValue).toBe(632); // 320 + 312
    expect(bigco.tokens).toBe(4_500_000);
    // ROT = attributed / Mtok = 632 / 4.5
    expect(bigco.rot).toBeCloseTo(140.444, 2);
  });

  it("totals revenue as the sum of team revenue, counting a retainer once", () => {
    const { revenue, teams } = rollupTeams({ clients, retainerByTeam });
    expect(revenue).toBe(7200); // 7000 (Bigco flat) + 0 (Internal) + 200 (Acme)
    // sorts by revenue desc so the biggest book is first
    expect(teams[0].team).toBe("Bigco");
  });

  it("computes margin% against revenue", () => {
    const { teams } = rollupTeams({ clients, retainerByTeam });
    const bigco = teams.find((t) => t.team === "Bigco")!;
    expect(bigco.marginPct).toBeCloseTo((6974 / 7000) * 100, 2);
  });
});
