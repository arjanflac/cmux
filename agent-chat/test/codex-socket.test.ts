import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connectCodexSocket } from "../adapters/codex-socket";

test("shared daemon connections route replies and disconnect independently", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cmux-codex-socket-"));
  const path = join(dir, "control.sock");
  const server = Bun.serve({
    unix: path,
    fetch(request, server) { return server.upgrade(request) ? undefined : new Response("no", { status: 400 }); },
    websocket: {
      message(ws, data) {
        const message = JSON.parse(String(data));
        if (message.method === "hang") return;
        if (message.method === "fail") ws.send(JSON.stringify({ id: message.id, error: { message: "fixture refused" } }));
        else ws.send(JSON.stringify({ id: message.id, result: message.params }));
      },
    },
  });
  let closed = 0;
  const first = await connectCodexSocket(path, () => {}, () => closed++, 200);
  const second = await connectCodexSocket(path, () => {}, () => {}, 200);
  try {
    expect(await first.request("echo", { threadId: "first" })).toEqual({ threadId: "first" });
    expect(await second.request("echo", { threadId: "second" })).toEqual({ threadId: "second" });
    await expect(first.request("fail")).rejects.toThrow("fixture refused");
    await expect(first.request("hang")).rejects.toThrow("timed out");
    const pending = first.request("hang").then(
      () => { throw new Error("Expected the disconnected request to reject"); },
      error => expect(error.message).toContain("connection closed"),
    );
    first.close();
    await pending;
    expect(closed).toBe(1);
    expect(await second.request("echo", { stillRunning: true })).toEqual({ stillRunning: true });
  } finally {
    first.close(); second.close(); server.stop(true); rmSync(dir, { recursive: true, force: true });
  }
});

test("invalid daemon endpoints are rejected instead of starting another backend", async () => {
  await expect(connectCodexSocket("ws://remote-host", () => {}, () => {})).rejects.toThrow("absolute");
});
