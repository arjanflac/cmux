import assert from "node:assert/strict";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { StatusRow } from "../src/components/StatusRow";
import type { SessionOption } from "../src/session";

Object.defineProperty(globalThis, "document", {
  configurable: true,
  value: { documentElement: {} },
});
Object.defineProperty(globalThis, "getComputedStyle", {
  configurable: true,
  value: () => ({ getPropertyValue: () => "" }),
});

const mutations: unknown[] = [];
function renderMode(option: SessionOption | undefined, running: boolean): string {
  return renderToStaticMarkup(React.createElement(StatusRow, {
    provider: "claude",
    cwd: "/work/project",
    options: option ? [option] : [],
    onChange: (id: string, value: unknown) => { mutations.push({ id, value }); },
    openOptionId: null,
    setOpenOptionId: () => {},
    running,
  }));
}

const choices = [
  { value: "default", label: "Default" },
  { value: "build", label: "Build" },
  { value: "plan", label: "Plan" },
  { value: "acceptEdits", label: "Accept edits" },
];

for (const running of [false, true]) {
  for (const id of ["mode", "permissionMode"]) {
    for (const choice of choices) {
      const option: SessionOption = { id, label: "Mode", kind: "select", value: choice.value, choices };
      const markup = renderMode(option, running);
      assert.ok(!markup.includes('aria-label="Mode"'), "mode controls do not occupy the composer row");
      if (id === "permissionMode") assert.ok(markup.includes('aria-label="More options"'), "permissions remain available in the menu");
      assert.ok(!markup.includes('cwd-label'), "a non-editable cwd is not shown as a fake control");
    }
  }
}
assert.deepEqual(mutations, [], "rendering a picker must preserve the provider's mode");
console.log("compact composer preserves permissions without inline mode/cwd controls");
