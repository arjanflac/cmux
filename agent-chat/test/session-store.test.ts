import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ChatSessionStore } from "../session-store";
import type { SessionCtx } from "../types";

test("idle GUI sessions retain their own provider identity, transcript and changed options", () => {
  const directory = mkdtempSync(join(tmpdir(), "cmux-chat-store-"));
  const store = new ChatSessionStore(directory);
  const session: SessionCtx & { createdAt: number } = {
    id: "abcdef12", provider: "codex", cwd: "/project", title: "Own graphical chat", createdAt: 123,
    autoApprove: true, startOptions: { model: "gpt-6-luna" }, status: "idle",
    internal: { threadId: "thread-exact-123" },
    events: [{ kind: "user", text: "Keep this conversation" },
      { kind: "options", options: [{ id: "effort", kind: "select", label: "Effort", value: "low" }] }],
    emit() {}, setStatus() {},
  };
  try {
    store.save(session);
    const [saved] = store.load();
    expect(saved?.providerSessionId).toBe("thread-exact-123");
    expect(saved?.events).toEqual(session.events);
    expect(saved?.options).toEqual({ model: "gpt-6-luna", effort: "low" });
    expect(statSync(join(directory, "abcdef12.json")).mode & 0o777).toBe(0o600);
    session.status = "running";
    store.save(session);
    expect(store.load()).toEqual([]); // Never pretend interrupted work is idle.
    writeFileSync(join(directory, "badbad12.json"), "invalid JSON");
    expect(store.load()).toEqual([]);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("disabled persistence does not write any session files", () => {
  expect(new ChatSessionStore("").load()).toEqual([]);
});
