/**
 * Pure catalog filter for the Composio onboarding page. Extracted from
 * composio.ts so it can be unit-tested with no SDK, network, or env.
 *
 * SDK reality (@composio/core@0.10.0): composio.toolkits.get({}) returns a
 * camelCase-transformed ARRAY of toolkit items (transformToolkitListResponse).
 * Each item exposes: slug, name, isLocalToolkit, noAuth,
 * composioManagedAuthSchemes, and meta.{logo, toolsCount, description,
 * categories[].slug}.
 *
 * The underlying LIST item type (@composio/client ToolkitListResponse.Item)
 * declares `composio_managed_auth_schemes?` as OPTIONAL and `is_local_toolkit`
 * as DEPRECATED ("will always return false"). So the managed-OAuth signal is
 * NOT reliably present on the LIST response; it is dependable only on the
 * per-toolkit RETRIEVE. The previous filter REQUIRED
 * `composioManagedAuthSchemes.includes("OAUTH2")`, which screened out EVERY app
 * on a real response -> empty catalog -> the live page showed zero apps.
 *
 * Fix: degrade gracefully. Screen only the clearly-unusable items and KEEP the
 * rest, so a normal (non-empty) SDK response can never be silently emptied.
 */

/** The card shape the onboarding UI renders. */
export interface ToolkitCard {
  slug: string;
  name: string;
  logo?: string;
  category?: string;
  tools?: number;
  description?: string;
}

/** A camelCase toolkit item as returned by composio.toolkits.get({}) (0.10.0). */
export interface RawToolkit {
  slug: string;
  name: string;
  isLocalToolkit?: boolean;
  noAuth?: boolean;
  composioManagedAuthSchemes?: string[];
  meta?: {
    logo?: string;
    categories?: Array<{ slug?: string }>;
    toolsCount?: number;
    description?: string;
  };
}

/**
 * Keep the CONNECTABLE apps from a raw toolkit-list response and shape them into
 * cards, popularity-sorted by tool count.
 *
 * Screens out ONLY the clearly-unusable entries:
 *  - the `composio` meta-toolkit (not a real connectable app),
 *  - local/builtin toolkits (`isLocalToolkit`),
 *  - no-auth toolkits (`noAuth` -- nothing to OAuth).
 * Everything else is kept, so a normal response is never reduced to empty.
 */
export function filterToolkits(raw: RawToolkit[]): ToolkitCard[] {
  return raw
    .filter((t) => t.slug !== "composio" && !t.isLocalToolkit && !t.noAuth)
    .map((t) => ({
      slug: t.slug,
      name: t.name,
      logo: t.meta?.logo,
      category: t.meta?.categories?.[0]?.slug,
      tools: t.meta?.toolsCount,
      description: t.meta?.description,
    }))
    .sort((a, b) => (b.tools ?? 0) - (a.tools ?? 0));
}
