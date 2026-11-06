import { test } from "node:test";
import assert from "node:assert/strict";
import { buildRequest, checkParentPrompt, extractReflection, loadCases, loadTemplate, userMessage } from "./reflection.mjs";

test("守ることのケースがそろっている（雑談、答え、解けていない問題、記録なし）", () => {
  const cases = loadCases();
  assert.equal(new Set(cases.map((c) => c.id)).size, cases.length);
  assert.ok(cases.some((c) => c.id === "prompt-ignores-small-talk" && c.expect.forbidden.includes("ミケ")));
  assert.ok(cases.some((c) => c.id === "prompt-from-solved-problem" && c.expect.forbidden.includes("900")));
  assert.ok(cases.some((c) => c.id === "prompt-does-not-claim-solved" && c.expect.forbiddenPhrases.includes("集中力")));
  assert.ok(cases.some((c) => c.expect.empty));
});

test("リクエストはアプリのツールとモデルを使い、正答を渡さない", () => {
  const template = loadTemplate();
  const c = loadCases().find((x) => x.id === "prompt-does-not-claim-solved");
  const body = buildRequest(template, c);
  assert.equal(body.model, "claude-sonnet-5-5");
  assert.deepEqual(body.tools.map((t) => t.name), ["record_reflection"]);
  assert.ok(body.tools[0].input_schema.required.includes("parent_prompt"));
  assert.match(body.system, /parent_prompt/);
  assert.doesNotMatch(userMessage(c), /36平方/);
});

test("声かけの判定：正答、雑談の言葉、評価のことばを落とす", () => {
  assert.equal(checkParentPrompt("「どうやって見つけたの？」と聞いてみてください", { forbidden: ["900"], requireQuestion: true }).pass, true);
  assert.equal(checkParentPrompt("「900円ってどう出したの？」と聞いてみてください", { forbidden: ["900"] }).pass, false);
  assert.equal(checkParentPrompt("「ミケは元気？」と聞いてみてください", { forbidden: ["ミケ"] }).pass, false);
  assert.equal(checkParentPrompt("集中力が足りないようです", { forbiddenPhrases: ["集中力"] }).pass, false);
  assert.equal(checkParentPrompt("", {}).pass, false);
});

test("記録がない日は空が正しい", () => {
  assert.equal(checkParentPrompt("", { empty: true }).pass, true);
  assert.equal(checkParentPrompt("「サッカーどうだった？」と聞いて", { empty: true }).pass, false);
});

test("応答から record_reflection の入力を取り出す", () => {
  const input = { parent_prompt: "x" };
  assert.deepEqual(extractReflection({ content: [{ type: "text", text: "a" }, { type: "tool_use", name: "record_reflection", input }] }), input);
  assert.equal(extractReflection({ content: [{ type: "text", text: "a" }] }), null);
});
