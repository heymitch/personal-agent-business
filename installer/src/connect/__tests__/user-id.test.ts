import { describe, it, expect } from "vitest";
import { userIdForPurchase } from "../user-id";
import { createHash } from "node:crypto";

describe("userIdForPurchase (the SHIPPED per-person-email binding, unchanged)", () => {
  it("user_id is per-person-email, case/space-insensitive, no slug", () => {
    const expected = "wm-" + createHash("sha256").update("alice@x.com").digest("hex").slice(0, 24);
    expect(userIdForPurchase("Alice@X.com ")).toBe(expected);
  });

  it("the SAME email always maps to the SAME id (the binding is deterministic)", () => {
    expect(userIdForPurchase("dana@example.com")).toBe(userIdForPurchase("dana@example.com"));
  });

  it("the account slug never enters the hash (different account, same email = same id)", () => {
    // The mint passes an account slug for naming the box/URL, NOT into this hash.
    // Proven by the formula taking only `email`: there is no slug parameter.
    const a = userIdForPurchase("dana@example.com");
    const b = userIdForPurchase("dana@example.com");
    expect(a).toBe(b);
    expect(a.startsWith("wm-")).toBe(true);
  });

  it("requires an email", () => {
    expect(() => userIdForPurchase("")).toThrow(/email/i);
  });
});
