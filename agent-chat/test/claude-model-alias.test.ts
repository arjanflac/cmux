import { test, expect } from "bun:test";
import { normalizeClaudeModelCatalog } from "../adapters/claude";

test("Claude's current aliases retain their executable value and reported capabilities", () => {
  const catalog = normalizeClaudeModelCatalog([
    { value: "opus", displayName: "Opus 5.5", supportsFastMode: true,
      supportedEffortLevels: ["low", "medium", "high", "max"], defaultEffortLevel: "medium" },
    { value: "sonnet", displayName: "Sonnet 5.5", supportedEffortLevels: ["low", "high"] },
  ], "2.1.306");
  const opus = catalog.choices.find(choice => choice.value === "opus");
  expect(opus?.label).toContain("5.5");
  expect(catalog.meta.get("opus")?.supportsFastMode).toBe(true);
  expect(opus?.efforts?.map(effort => effort.value)).toEqual(["low", "medium", "high", "max"]);
  expect(catalog.choices.find(choice => choice.value === "sonnet")?.label).toContain("5.5");
});
