/**
 * The connect-on-page core: list the connectable app catalog (with logos), mint
 * Composio Connect Links per app for a buyer's user_id, and report which are
 * ACTIVE. Proven mechanism (connectedAccounts.link -> redirectUrl). Uses
 * DEFAULT-MANAGED auth configs (no scope override -- the Fork A that works).
 */
import { Composio } from "@composio/core";

const composio = new Composio({ apiKey: process.env.COMPOSIO_API_KEY ?? "" });

export interface ToolkitCard {
  slug: string;
  name: string;
  logo?: string;
  category?: string;
  tools?: number;
  description?: string;
}

/** The full connectable catalog (~1000 apps) filtered to ones that work with
 *  Composio managed OAuth, with logos, sorted by popularity (tool count). */
export async function listToolkits(): Promise<ToolkitCard[]> {
  const tk = (composio as unknown as { toolkits: { get(q: object): Promise<unknown> } }).toolkits;
  const res = (await tk.get({})) as { items?: unknown[] };
  const raw = (res?.items ?? (Array.isArray(res) ? (res as unknown[]) : [])) as Array<{
    slug: string; name: string; isLocalToolkit?: boolean; noAuth?: boolean;
    composioManagedAuthSchemes?: string[];
    meta?: { logo?: string; categories?: Array<{ slug?: string }>; toolsCount?: number; description?: string };
  }>;
  return raw
    .filter(
      (t) =>
        !t.isLocalToolkit &&
        !t.noAuth &&
        t.slug !== "composio" &&
        Array.isArray(t.composioManagedAuthSchemes) &&
        t.composioManagedAuthSchemes.includes("OAUTH2"),
    )
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

/** Find-or-create a default-managed auth config for a toolkit (idempotent). */
async function ensureManagedAuthConfig(slug: string): Promise<string> {
  const name = `${slug}-default-managed`;
  const { items } = await composio.authConfigs.list({ toolkit: slug });
  const found = (items as Array<{ id: string; name: string }>).find((c) => c.name === name);
  if (found) return found.id;
  const created = (await composio.authConfigs.create(slug, {
    type: "use_composio_managed_auth",
    name,
  } as unknown as never)) as { id: string };
  return created.id;
}

/** Mint a white-labelable Connect Link the buyer opens to OAuth this app. */
export async function mintConnectLink(userId: string, slug: string): Promise<string> {
  const authConfigId = await ensureManagedAuthConfig(slug);
  const res = (await composio.connectedAccounts.link(userId, authConfigId)) as {
    redirectUrl?: string | null;
  };
  if (!res.redirectUrl) throw new Error("Composio returned no redirectUrl");
  return res.redirectUrl;
}

/** The toolkits this user has an ACTIVE connection for (drives the checklist). */
export async function connectedToolkits(userId: string): Promise<string[]> {
  const res = (await composio.connectedAccounts.list({ userIds: [userId] })) as {
    items?: Array<{ status: string; toolkit?: { slug?: string }; toolkitSlug?: string }>;
  };
  return (res.items ?? [])
    .filter((a) => a.status === "ACTIVE")
    .map((a) => (a.toolkit?.slug ?? a.toolkitSlug ?? "").toLowerCase());
}
