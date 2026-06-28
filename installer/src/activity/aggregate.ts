import type { ActivityRecord } from "./activity-log";

/**
 * Default dollar value of ONE unit of work per capability: what that output would cost if a human
 * did it (the labor the agent replaces) -- the "value created" rate. EMPTY by default: the
 * operator's skills/capabilities are their OWN (there is no built-in catalog to ship publicly), so
 * the operator tunes per-capability rates via a rates file (the receiver merges rates.json over
 * this). A capability with no rate and no explicit override is valued at 0.
 */
export const VALUE_PER_ACTION: Record<string, number> = {};

/**
 * Agent attribution weight per capability: the AGENT'S share of the value, vs the human's. The
 * honesty knob -- a high-leverage human role (sales) weights low; an AI-heavy role weights high.
 * EMPTY by default (the operator's capability ids are their own); the operator tunes it via a
 * weights file (the receiver merges weights.json over this). Unknown capability -> full credit (1.0).
 */
export const ATTRIBUTION_WEIGHT: Record<string, number> = {};

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
