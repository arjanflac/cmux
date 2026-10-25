import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentEvent, OptionValue, SessionCtx } from "./types";

export interface SavedChat {
  version: 1;
  id: string;
  provider: "codex" | "claude";
  providerSessionId: string;
  conversationId?: string;
  parentSessionId?: string;
  parentConversationId?: string;
  cwd: string;
  title: string;
  createdAt: number;
  autoApprove: boolean;
  options: Record<string, OptionValue>;
  events: AgentEvent[];
  wasRunning: boolean;
}

/** Own graphical sessions only. This never searches another frontend's threads. */
export class ChatSessionStore {
  constructor(private directory: string) {}

  save(session: SessionCtx & { createdAt: number; transcript?: unknown }): void {
    if (!this.directory || session.transcript || !["codex", "claude"].includes(session.provider)) return;
    const providerSessionId = session.internal[session.provider === "codex" ? "threadId" : "providerSessionId"];
    if (typeof providerSessionId !== "string") return;
    const latestOptions = [...session.events].reverse().find(event => event.kind === "options") as
      Extract<AgentEvent, { kind: "options" }> | undefined;
    const options = Object.fromEntries((latestOptions?.options ?? []).map(option => [option.id, option.value]));
    const record: SavedChat = {
      version: 1, id: session.id, provider: session.provider as SavedChat["provider"], providerSessionId,
      conversationId: session.conversationId, parentSessionId: session.parentSessionId, parentConversationId: session.parentConversationId,
      cwd: session.cwd, title: session.title, createdAt: session.createdAt, autoApprove: session.autoApprove,
      options: { ...session.startOptions, ...options }, events: session.events, wasRunning: session.status === "running",
    };
    if (!valid(record)) throw new Error("Cannot persist an invalid graphical session");
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const file = join(this.directory, `${record.id}.json`);
    const temporary = `${file}.pending`;
    writeFileSync(temporary, JSON.stringify(record), { mode: 0o600 });
    renameSync(temporary, file);
  }

  load(): SavedChat[] {
    if (!this.directory || !existsSync(this.directory)) return [];
    return readdirSync(this.directory).filter(name => /^[\da-f]{8}\.json$/.test(name)).flatMap(name => {
      try {
        const record = JSON.parse(readFileSync(join(this.directory, name), "utf8"));
        // A crashed active frontend needs transcript reconciliation before it
        // can safely submit again. Keep its file, but do not pretend it is idle.
        return valid(record) && !record.wasRunning ? [record] : [];
      } catch { return []; }
    });
  }
}

function valid(record: any): record is SavedChat {
  return record?.version === 1 && /^[\da-f]{8}$/.test(record.id)
    && ["codex", "claude"].includes(record.provider)
    && typeof record.providerSessionId === "string" && /^[\w-]{8,128}$/.test(record.providerSessionId)
    && typeof record.cwd === "string" && record.cwd.startsWith("/")
    && typeof record.title === "string" && Number.isFinite(record.createdAt)
    && typeof record.autoApprove === "boolean" && typeof record.wasRunning === "boolean"
    && record.options && typeof record.options === "object" && !Array.isArray(record.options)
    && Array.isArray(record.events) && record.events.length <= 10_000;
}
