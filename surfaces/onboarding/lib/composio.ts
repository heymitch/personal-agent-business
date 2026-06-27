/**
 * The connect-on-page core: list the connectable app catalog (with logos), mint
 * Composio Connect Links per app for a buyer's user_id, and report which are
 * ACTIVE. Proven mechanism (connectedAccounts.link -> redirectUrl). Uses
 * DEFAULT-MANAGED auth configs (no scope override -- the Fork A that works).
 */
import { Composio } from "@composio/core";
import { type RawToolkit, type ToolkitCard, filterToolkits } from "./toolkits-filter.js";

export type { ToolkitCard };

const composio = new Composio({ apiKey: process.env.COMPOSIO_API_KEY ?? "" });

/** The full connectable catalog (~1000 apps), with logos, sorted by popularity
 *  (tool count). Screens out only the clearly-unusable items (local/builtin,
 *  no-auth, and the `composio` meta-toolkit) so the catalog is never silently
 *  empty -- see filterToolkits for the @composio/core@0.10.0 field-shape notes. */
export async function listToolkits(): Promise<ToolkitCard[]> {
  const tk = (composio as unknown as { toolkits: { get(q: object): Promise<unknown> } }).toolkits;
  const res = (await tk.get({})) as { items?: unknown[] };
  const raw = (res?.items ?? (Array.isArray(res) ? (res as unknown[]) : [])) as RawToolkit[];
  return filterToolkits(raw);
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
