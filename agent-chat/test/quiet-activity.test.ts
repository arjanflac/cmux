import { strict as assert } from "node:assert";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { quietActivity, toggleActivityDisclosure } from "../src/turns";
import type { Block } from "../src/session";
import { transcriptReadOnly } from "../src/session";
import { keyDispatchFor } from "../src/keymap";
(globalThis as any).location ??= { pathname: "/" };
Object.defineProperty(globalThis.navigator, "languages", { value: ["en"], configurable: true });
Object.defineProperty(globalThis.navigator, "language", { value: "en", configurable: true });
const { Blocks } = await import("../src/components/Transcript");
const activity: Block[] = [
  { kind: "assistant", text: "Readable progress", open: false },
  { kind: "tool", toolId: "1", name: "exec", detail: "private-command", out: "private-output", status: "ok" },
  { kind: "thinking", text: "Visible thinking", open: false },
  { kind: "error", text: "Visible error" },
  { kind: "tool", toolId: "2", name: "failed-tool", status: "fail", out: "large-error-dump" },
];
const result = quietActivity(activity);
assert.deepEqual(result.visible.map(b => b.kind), ["assistant", "thinking", "error", "tool"]);
assert.equal(result.details.length, 1);
assert.equal(activity.length, 5);
assert.deepEqual(toggleActivityDisclosure(["a","b"], {a:true}), {a:true,b:true});
assert.deepEqual(toggleActivityDisclosure(["a","b"], {a:true,b:true}), {a:false,b:false});
assert.equal(transcriptReadOnly("transcript", "?readonly=1"), true);
assert.equal(transcriptReadOnly("transcript", "?readonly=0"), false);
assert.equal(transcriptReadOnly(undefined, "?readonly=1"), false);
assert.deepEqual(keyDispatchFor({key:"t", ctrlKey:true, metaKey:false, altKey:false, shiftKey:false},
  {editable:true,popupOpen:false}), {kind:"global",action:"toggle-activity"});
assert.equal(keyDispatchFor({key:"a", ctrlKey:true, metaKey:false, altKey:false, shiftKey:false},
  {editable:true,popupOpen:false}), null);
const blocks: Block[] = [{kind:"user",text:"Test"}, ...activity, {kind:"assistant",text:"Final answer",open:false}];
for (const status of ["running", "idle"]) {
  const html = renderToStaticMarkup(React.createElement(Blocks, {
    blocks, status, actions: {} as any, onFork: () => {}, forkPending: false,
  }));
  for (const text of ["Readable progress","Visible thinking","Visible error","failed-tool","Final answer"])
    assert.ok(html.includes(text), `${status}: lost ${text}`);
  for (const text of ["private-command","private-output","large-error-dump"])
    assert.ok(!html.includes(text), `${status}: leaked ${text}`);
}
console.log("PASS: quiet activity preserves conversation and errors, hides tool dumps live and idle");
