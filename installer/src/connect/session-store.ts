import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * Durable userId -> Tool Router sessionId map. Needed because
 * `toolRouter.create` is NOT idempotent by userId (a second call mints a new
 * sessionId AND a new mcp.url), so to expand a live session on a later
 * connection we must reattach the SAME session by id. Provisioning writes the
 * id here; the connection receiver reads it.
 *
 * One JSON file, read-modify-write, corrupt reads as empty.
 */
export interface SessionStore {
  put(userId: string, sessionId: string): Promise<void>;
  get(userId: string): Promise<string | null>;
}

export function makeSessionStore(filePath: string): SessionStore {
  const load = (): Record<string, string> => {
    if (!existsSync(filePath)) return {};
    try {
      const parsed = JSON.parse(readFileSync(filePath, "utf8"));
      return parsed && typeof parsed === "object" && !Array.isArray(parsed)
        ? (parsed as Record<string, string>)
        : {};
    } catch {
      return {}; // a corrupt/partial file reads as empty, never throws mid-request
    }
  };
  const save = (map: Record<string, string>): void => {
    mkdirSync(dirname(filePath), { recursive: true });
    writeFileSync(filePath, JSON.stringify(map) + "\n", "utf8");
  };
  return {
    async put(userId, sessionId) {
      const map = load();
      map[userId] = sessionId;
      save(map);
    },
    async get(userId) {
      return load()[userId] ?? null;
    },
  };
}
