import type { ActivityRecord } from "./activity-log";

/**
 * Default dollar value of ONE unit of work per capability: what that output would cost if a human
 * did it (the labor the agent replaces). Operator-tunable; this is the "value created" rate. These
 * are deliberately conservative ghostwriter/assistant rates.
 */
export const VALUE_PER_ACTION: Record<string, number> = {
  repurpose: 150,
  "job-scan": 75,
  "trend-jack": 120,
  "kit-schedule": 100,
  "ghost-scorecard": 200,
  "sales-followup": 80,
};

/**
 * Agent attribution weight per capability: the AGENT'S share of the value, vs the human's. This is
 * the honesty knob. A high-leverage human role (sales) generates revenue the AI cannot claim (it
 * can't make the calls), so it weights low; AI-heavy roles (organic content, success) weight high.
 * Tunable over time and by price point: marketing may out-leverage sales, etc. Override per box via
 * a weights file. Unknown capability defaults to full credit (1.0).
 *
 * Maps to the capability writer/coach/closer groups: writer high, coach mid, closer low.
 */
export const ATTRIBUTION_WEIGHT: Record<string, number> = {
  // writer (AI does the work)
  repurpose: 0.8,
  "job-scan": 0.7,
  "trend-jack": 0.8,
  "kit-schedule": 0.7,
  // coach (AI monitors + scores, human acts)
  "ghost-scorecard": 0.5,
  // closer (human closes; AI supports)
  "sales-followup": 0.15,
};

export interface ActivityAggregate {
  /** Raw value: what the human + agent produced together (unweighted). */
  totalValue: number;
  /** Attributed value: the agent's weighted share (the honest number; drives weighted ROT). */
  totalAttributedValue: number;
  totalActions: number;
  /** Raw value per client (slug). */
  valueBySlug: Record<string, number>;
  /** Attributed (weighted) value per client. */
  attributedBySlug: Record<string, number>;
  /** Per-capability breakdown, raw-value-descending. Carries the attribution weight for transparency. */
  byCapability: Array<{ capability: string; actions: number; value: number; attributedValue: number; weight: number }>;
  /** Daily raw value + action count, ascending by date. */
  timeSeries: Array<{ date: string; value: number; actions: number }>;
}

/** Value of one record: explicit override, else the capability's per-action rate, else 0. */
function valueOf(r: ActivityRecord, rates: Record<string, number>): number {
  if (typeof r.valueUsd === "number" && Number.isFinite(r.valueUsd)) return r.valueUsd;
  return Number(rates[r.capability]) || 0;
}

/** The agent's attribution weight for a capability (unknown -> full credit). */
function weightOf(capability: string, weights: Record<string, number>): number {
  const w = weights[capability];
  return typeof w === "number" && Number.isFinite(w) ? w : 1;
}

export function aggregateActivity(input: {
  actions: ActivityRecord[];
  valuePerAction?: Record<string, number>;
  attributionWeight?: Record<string, number>;
}): ActivityAggregate {
  const rates = input.valuePerAction ?? VALUE_PER_ACTION;
  const weights = input.attributionWeight ?? ATTRIBUTION_WEIGHT;
  const valueBySlug: Record<string, number> = {};
  const attributedBySlug: Record<string, number> = {};
  const capAcc = new Map<string, { actions: number; value: number; attributedValue: number; weight: number }>();
  const dayAcc = new Map<string, { value: number; actions: number }>();
  let totalValue = 0;
  let totalAttributedValue = 0;

  for (const r of input.actions) {
    const v = valueOf(r, rates);
    const w = weightOf(r.capability, weights);
    const av = v * w;
    totalValue += v;
    totalAttributedValue += av;
    valueBySlug[r.slug] = (valueBySlug[r.slug] ?? 0) + v;
    attributedBySlug[r.slug] = (attributedBySlug[r.slug] ?? 0) + av;
    const cap = capAcc.get(r.capability) ?? { actions: 0, value: 0, attributedValue: 0, weight: w };
    cap.actions += 1;
    cap.value += v;
    cap.attributedValue += av;
    cap.weight = w;
    capAcc.set(r.capability, cap);
    const date = r.at.slice(0, 10);
    const day = dayAcc.get(date) ?? { value: 0, actions: 0 };
    day.value += v;
    day.actions += 1;
    dayAcc.set(date, day);
  }

  const byCapability = [...capAcc.entries()]
    .map(([capability, x]) => ({ capability, ...x }))
    .sort((a, b) => b.value - a.value);
  const timeSeries = [...dayAcc.entries()]
    .map(([date, x]) => ({ date, ...x }))
    .sort((a, b) => (a.date < b.date ? -1 : 1));

  return {
    totalValue,
    totalAttributedValue,
    totalActions: input.actions.length,
    valueBySlug,
    attributedBySlug,
    byCapability,
    timeSeries,
  };
}
