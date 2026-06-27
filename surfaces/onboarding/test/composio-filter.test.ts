/**
 * Regression test for the connect-page catalog filter (Composio onboarding).
 *
 * BUG: the previous filter required
 *   Array.isArray(t.composioManagedAuthSchemes)
 *     && t.composioManagedAuthSchemes.includes("OAUTH2")
 * but @composio/core@0.10.0's LIST response (composio.toolkits.get({})) does not
 * reliably populate `composioManagedAuthSchemes` -> EVERY app was screened out
 * -> empty catalog -> the live onboarding page showed ZERO apps.
 *
 * Run: node --test test/composio-filter.test.ts
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { filterToolkits, type RawToolkit } from "../lib/toolkits-filter.ts";

// Mock shaped like the REAL transformed 0.10.0 list items. The connectable apps
// deliberately OMIT composioManagedAuthSchemes -- exactly the field the old
// filter depended on and the live API did not return on the list response.
const mockToolkits: RawToolkit[] = [
  {
    slug: "gmail",
    name: "Gmail",
    isLocalToolkit: false,
    noAuth: false,
    meta: { logo: "https://logos/gmail.png", categories: [{ slug: "productivity" }], toolsCount: 42, description: "Email" },
  },
  {
    slug: "github",
    name: "GitHub",
    isLocalToolkit: false,
    noAuth: false,
    meta: { logo: "https://logos/github.png", categories: [{ slug: "developer-tools" }], toolsCount: 120, description: "Code host" },
  },
  {
    slug: "slack",
    name: "Slack",
    isLocalToolkit: false,
    noAuth: false,
    meta: { logo: "https://logos/slack.png", categories: [{ slug: "communication" }], toolsCount: 30, description: "Team chat" },
  },
  // screened: the composio meta-toolkit (not a real connectable app)
  { slug: "composio", name: "Composio", isLocalToolkit: false, noAuth: false, meta: { toolsCount: 9 } },
  // screened: no-auth toolkit (nothing to OAuth)
  { slug: "weather", name: "Weather", isLocalToolkit: false, noAuth: true, meta: { toolsCount: 4 } },
  // screened: local/builtin toolkit
  { slug: "filetool", name: "File Tool", isLocalToolkit: true, noAuth: false, meta: { toolsCount: 8 } },
];

test("catalog is non-empty and keeps connectable apps, popularity-sorted", () => {
  const cards = filterToolkits(mockToolkits);
  assert.ok(cards.length > 0, "catalog must never be silently empty");
  assert.deepEqual(
    cards.map((c) => c.slug),
    ["github", "gmail", "slack"],
    "keeps connectable apps, sorted by tool count desc",
  );
});

test("screens out composio meta-toolkit, no-auth, and local toolkits", () => {
  const slugs = filterToolkits(mockToolkits).map((c) => c.slug);
  assert.ok(!slugs.includes("composio"), "composio meta-toolkit removed");
  assert.ok(!slugs.includes("weather"), "no-auth toolkit removed");
  assert.ok(!slugs.includes("filetool"), "local/builtin toolkit removed");
});

test("maps logo / category / tools from the real 0.10.0 field paths", () => {
  const github = filterToolkits(mockToolkits).find((c) => c.slug === "github");
  assert.ok(github, "github card present");
  assert.equal(github?.logo, "https://logos/github.png");
  assert.equal(github?.category, "developer-tools");
  assert.equal(github?.tools, 120);
});

// Proves this test CATCHES the regression: the old composioManagedAuthSchemes
// predicate applied to the same representative response yields an empty catalog.
test("old composioManagedAuthSchemes filter would regress to empty (caught)", () => {
  const oldFilter = (rows: RawToolkit[]) =>
    rows.filter(
      (t) =>
        !t.isLocalToolkit &&
        !t.noAuth &&
        t.slug !== "composio" &&
        Array.isArray(t.composioManagedAuthSchemes) &&
        t.composioManagedAuthSchemes.includes("OAUTH2"),
    );
  assert.equal(oldFilter(mockToolkits).length, 0, "old filter screened out every app");
  assert.ok(filterToolkits(mockToolkits).length > 0, "new filter keeps the catalog populated");
});
