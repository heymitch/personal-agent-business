/**
 * The operator dashboard's business math, pure. Join each client's price (revenue) with their
 * costs (per-project OpenAI spend + a flat monthly box cost) into per-client and total
 * spend / revenue / ROI. All IO (the OpenAI costs API, the box list) is resolved by the caller and
 * passed in, so this is fully testable and holds no keys.
 *
 * Box cost is charged unless the box is explicitly stopped (a running OR unknown-status box is
 * still billing; only a definitively off box is free). OpenAI spend is month-to-date USD per
 * client (we mint a project per client, so it is directly attributable).
 */
export interface DashboardClient {
  slug: string;
  agentName: string;
  email: string;
  status?: string;
  priceMonthly: number;
  openaiSpend: number;
  boxCost: number;
  totalCost: number;
  roi: number;
}

export interface DashboardData {
  clients: DashboardClient[];
  totals: {
    agents: number;
    revenue: number;
    openaiSpend: number;
    boxCost: number;
    totalCost: number;
    roi: number;
  };
}

export function aggregateDashboard(input: {
  agents: Array<{
    slug: string;
    agentName: string;
    email: string;
    priceMonthly?: number;
    status?: string;
  }>;
  openaiSpendBySlug: Record<string, number>;
  boxMonthlyUsd: number;
}): DashboardData {
  const clients: DashboardClient[] = input.agents.map((a) => {
    const priceMonthly = Number(a.priceMonthly) || 0;
    const openaiSpend = Number(input.openaiSpendBySlug[a.slug]) || 0;
    const stopped = a.status === "off" || a.status === "stopped";
    const boxCost = stopped ? 0 : input.boxMonthlyUsd;
    const totalCost = openaiSpend + boxCost;
    return {
      slug: a.slug,
      agentName: a.agentName,
      email: a.email,
      status: a.status,
      priceMonthly,
      openaiSpend,
      boxCost,
      totalCost,
      roi: priceMonthly - totalCost,
    };
  });

  const sum = (pick: (c: DashboardClient) => number) => clients.reduce((n, c) => n + pick(c), 0);
  const revenue = sum((c) => c.priceMonthly);
  const openaiSpend = sum((c) => c.openaiSpend);
  const boxCost = sum((c) => c.boxCost);
  const totalCost = openaiSpend + boxCost;

  return {
    clients,
    totals: { agents: clients.length, revenue, openaiSpend, boxCost, totalCost, roi: revenue - totalCost },
  };
}
