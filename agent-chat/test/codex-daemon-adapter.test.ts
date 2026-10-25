import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { codexAdapter, codexStopSharedServerForTest } from "../adapters/codex";

const directory = mkdtempSync(join(tmpdir(), "cmux-daemon-adapter-"));
const path = join(directory, "daemon.sock");
const requests: string[] = [];
const server = Bun.serve({
  unix: path,
  fetch(request, server) { return server.upgrade(request) ? undefined : new Response("no"); },
  websocket: {
    message(ws, data) {
      const message = JSON.parse(String(data));
      requests.push(message.method);
      if (message.id == null) return;
      const result = message.method === "model/list" ? {
        data: [{ id: "fixture-luna", model: "fixture-luna", displayName: "Fixture Luna", isDefault: true,
          supportedReasoningEfforts: [{ reasoningEffort: "low", description: "Low" }], defaultReasoningEffort: "low" }],
      } : { data: [] };
      ws.send(JSON.stringify({ id: message.id, result }));
    },
  },
});
const previousSocket = process.env.CMUX_AGENT_CHAT_CODEX_SOCKET;
const spawn = Bun.spawn;
try {
  process.env.CMUX_AGENT_CHAT_CODEX_SOCKET = path;
  Bun.spawn = (() => { throw new Error("Must not start another Codex process"); }) as typeof Bun.spawn;
  const options = await codexAdapter.listOptions!(directory);
  assert.ok(options.find(option => option.id === "model")?.choices?.some(model => model.value === "fixture-luna"));
  assert.deepEqual(requests.slice(0, 2), ["initialize", "initialized"]);
  codexStopSharedServerForTest();
  // Closing the adapter must leave the externally owned server available.
  await codexAdapter.listOptions!(directory);
  codexStopSharedServerForTest();
  process.env.CMUX_AGENT_CHAT_CODEX_SOCKET = "relative-invalid.sock";
  await assert.rejects(codexAdapter.listOptions!(directory), /absolute/);
  console.log("Shared-daemon catalog, handshake, reconnect and no-spawn failure behavior: OK");
} finally {
  Bun.spawn = spawn;
  if (previousSocket === undefined) delete process.env.CMUX_AGENT_CHAT_CODEX_SOCKET;
  else process.env.CMUX_AGENT_CHAT_CODEX_SOCKET = previousSocket;
  codexStopSharedServerForTest(); server.stop(true);
  rmSync(directory, { recursive: true, force: true });
}
