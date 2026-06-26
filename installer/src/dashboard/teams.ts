/**
 * Per-team P&L rollup. Revenue in this business attaches to the TEAM (an agency retainer), not the
 * seat: a client pays a flat monthly retainer for unlimited agents, so adding a seat costs a few
 * dollars of box + tokens while revenue stays flat. That is the whole leverage thesis, so the
 * dashboard reports it at the team level. A team with no configured retainer falls back to the sum
 * of its agents' per-seat prices (the self-serve model), so both pricing shapes coexist.
 *
 * Pure: the caller passes the already-costed + valued client rows and the retainer config. The team
 * derivation (teamOf) mirrors the console's client-side grouping so the two never disagree.
 *
 * teamOf is generic: it buckets by the email domain's base word. Configure retainers per team in
 * the operator's retainers.json; no client names are baked in here.
 */
export function teamOf(email: string): string {
  const dom = (String(email ?? "").split("@")[1] ?? "").toLowerCase();
  if (!dom) return "Unassigned";
  if (dom.includes("operator.local") || dom.includes("internal")) return "Internal";
  const base = dom.split(".")[0];
  return base ? base.charAt(0).toUpperCase() + base.slice(1) : "Other";
}

export interface TeamClientRow {
  slug: string;
  email: string;
  status?: string;
  /** Self-serve per-seat price; only used when the team has no flat retainer. */
  priceMonthly?: number;
  openaiSpend: number;
  boxCost: number;
  totalCost: number;
  valueCreated: number;
  attributedValue: number;
  tokens: number;
}

export interface TeamRollup {
  team: string;
  /** Flat team retainer if configured (unlimited seats), else summed per-agent price (self-serve). */
  retainerMonthly: number;
  /** True when a flat retainer applied (revenue is decoupled from seat count). */
  isRetainer: boolean;
  agents: number;
  running: number;
  valueCreated: number;
  attributedValue: number;
  openaiSpend: number;
  boxCost: number;
  totalCost: number;
  /** revenue - totalCost. */
  profit: number;
  /** profit / revenue * 100; 0 when there is no revenue (never NaN). */
  marginPct: number;
  tokens: number;
  /** Weighted Return on Tokens for the team: attributedValue / million tokens. */
  rot: number;
  /** totalCost / agents: the marginal-seat cost that makes "unlimited seats" leverage visible. */
  costPerAgent: number;
}

function num(n: unknown): number {
  const v = Number(n);
  return Number.isFinite(v) ? v : 0;
}

export function rollupTeams(input: {
  clients: TeamClientRow[];
  retainerByTeam: Record<string, number>;
  teamOf?: (email: string) => string;
}): { teams: TeamRollup[]; revenue: number } {
  const team = input.teamOf ?? teamOf;
  const groups = new Map<string, TeamClientRow[]>();
  for (const c of input.clients) {
    const t = team(c.email);
    (groups.get(t) ?? groups.set(t, []).get(t)!).push(c);
  }

  const teams: TeamRollup[] = [...groups.entries()].map(([name, rows]) => {
    const sum = (pick: (r: TeamClientRow) => number) => rows.reduce((n, r) => n + num(pick(r)), 0);
    const totalCost = sum((r) => r.totalCost);
    const tokens = sum((r) => r.tokens);
    const attributedValue = sum((r) => r.attributedValue);
    const mtok = tokens / 1_000_000;

    const configured = input.retainerByTeam[name];
    const isRetainer = typeof configured === "number" && Number.isFinite(configured);
    const retainerMonthly = isRetainer ? Number(configured) : sum((r) => r.priceMonthly ?? 0);
    const profit = retainerMonthly - totalCost;

    return {
      team: name,
      retainerMonthly,
      isRetainer,
      agents: rows.length,
      running: rows.filter((r) => r.status === "running").length,
      valueCreated: sum((r) => r.valueCreated),
      attributedValue,
      openaiSpend: sum((r) => r.openaiSpend),
      boxCost: sum((r) => r.boxCost),
      totalCost,
      profit,
      marginPct: retainerMonthly > 0 ? (profit / retainerMonthly) * 100 : 0,
      tokens,
      rot: mtok > 0 ? attributedValue / mtok : 0,
      costPerAgent: rows.length > 0 ? totalCost / rows.length : 0,
    };
  });

  teams.sort((a, b) => b.retainerMonthly - a.retainerMonthly);
  const revenue = teams.reduce((n, t) => n + t.retainerMonthly, 0);
  return { teams, revenue };
}
