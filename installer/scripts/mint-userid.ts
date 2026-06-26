/**
 * Print the per-PERSON-email Composio user_id for a buyer email, derived by the
 * SHIPPED, unchanged formula (`userIdForPurchase`). The mint action shells this
 * so the bash layer never re-implements the hash; the account slug is NOT passed
 * here (it never enters the id).
 *
 * Usage:  tsx scripts/mint-userid.ts <email>
 */
import { userIdForPurchase } from "../src/connect/user-id";

const email = process.argv[2] ?? "";
process.stdout.write(userIdForPurchase(email) + "\n");
