/**
 * The tight-scope Gmail auth config (the consent screen a client actually
 * sees). Composio's managed DEFAULT Gmail scopes are broad and scary:
 * https://mail.google.com/ (full mailbox including permanent delete) plus
 * contacts and People-API personal data. Per the connect-layer contract, no
 * client may see that consent screen: mint links against this config instead
 * of the broad default.
 *
 * Read + send only. Still Composio-managed auth (their pre-verified Google
 * app), so no CASA audit lands on us.
 */
export const TIGHT_GMAIL_AUTH_CONFIG_NAME = "gmail-tight-scope";

export const TIGHT_GMAIL_SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/userinfo.profile",
];

/** The slice of `composio.authConfigs` this needs (injected, testable). */
export interface AuthConfigsApi {
  list(params: { toolkit: string }): Promise<{ items: Array<{ id: string; name: string }> }>;
  create(
    toolkit: string,
    options: {
      type: "use_composio_managed_auth";
      name: string;
      credentials: { scopes: string[] };
    },
  ): Promise<{ id: string }>;
}

/** Find the tight-scope config by name, or create it. Idempotent. */
export async function ensureTightGmailAuthConfig(
  api: AuthConfigsApi,
): Promise<{ id: string; created: boolean }> {
  const { items } = await api.list({ toolkit: "gmail" });
  const existing = items.find((c) => c.name === TIGHT_GMAIL_AUTH_CONFIG_NAME);
  if (existing) return { id: existing.id, created: false };
  const created = await api.create("gmail", {
    type: "use_composio_managed_auth",
    name: TIGHT_GMAIL_AUTH_CONFIG_NAME,
    credentials: { scopes: TIGHT_GMAIL_SCOPES },
  });
  return { id: created.id, created: true };
}
