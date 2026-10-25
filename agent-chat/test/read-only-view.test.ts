import { strict as assert } from "node:assert";
process.env.CMUX_AGENT_CHAT_READ_ONLY = "1";
const { readOnlyOperationAllowed, handleSessionMessage } = await import("../server");
assert.equal(readOnlyOperationAllowed("subscribe"), true);
assert.equal(readOnlyOperationAllowed("get-file-diff"), true);
for (const op of ["start", "send", "stop", "fork", "handoff", "delete", "set-option", "list-options", "unknown"]) {
  assert.equal(readOnlyOperationAllowed(op), false, op);
  assert.equal(readOnlyOperationAllowed(op, false), true, op);
  const replies: string[] = [];
  handleSessionMessage({ send: (text: string) => replies.push(text) } as any, { op });
  assert.equal(replies.length, 1, op);
  assert.equal(JSON.parse(replies[0]!).kind, "error", op);
}
console.log("PASS: viewing server refuses every model-changing operation before dispatch");
