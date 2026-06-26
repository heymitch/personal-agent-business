import { describe, it, expect, vi } from "vitest";
import {
  ensureTightGmailAuthConfig,
  TIGHT_GMAIL_SCOPES,
  TIGHT_GMAIL_AUTH_CONFIG_NAME,
} from "../gmail-auth-config";

function fakeApi(existing: Array<{ id: string; name: string }>) {
  return {
    list: vi.fn().mockResolvedValue({ items: existing }),
    create: vi.fn().mockResolvedValue({ id: "ac_new123" }),
  };
}

describe("ensureTightGmailAuthConfig", () => {
  it("returns the existing config without creating when one matches by name", async () => {
    const api = fakeApi([
      { id: "ac_broad", name: "default-gmail" },
      { id: "ac_tight", name: TIGHT_GMAIL_AUTH_CONFIG_NAME },
    ]);
    const result = await ensureTightGmailAuthConfig(api);
    expect(result).toEqual({ id: "ac_tight", created: false });
    expect(api.create).not.toHaveBeenCalled();
  });

  it("creates a Composio-managed config with the tight scopes when absent", async () => {
    const api = fakeApi([{ id: "ac_broad", name: "default-gmail" }]);
    const result = await ensureTightGmailAuthConfig(api);
    expect(result).toEqual({ id: "ac_new123", created: true });
    expect(api.list).toHaveBeenCalledWith({ toolkit: "gmail" });
    expect(api.create).toHaveBeenCalledWith("gmail", {
      type: "use_composio_managed_auth",
      name: TIGHT_GMAIL_AUTH_CONFIG_NAME,
      credentials: { scopes: TIGHT_GMAIL_SCOPES },
    });
  });

  it("tight scopes allow read + send only: no full mailbox, no delete, no People API", () => {
    expect(TIGHT_GMAIL_SCOPES).toContain("https://www.googleapis.com/auth/gmail.readonly");
    expect(TIGHT_GMAIL_SCOPES).toContain("https://www.googleapis.com/auth/gmail.send");
    const joined = TIGHT_GMAIL_SCOPES.join(" ");
    expect(joined).not.toContain("https://mail.google.com/");
    expect(joined).not.toContain("contacts");
    expect(joined).not.toContain("directory");
    expect(joined).not.toContain("gmail.modify");
  });
});
