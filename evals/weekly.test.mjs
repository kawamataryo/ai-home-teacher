import { test } from "node:test";
import assert from "node:assert/strict";
import { buildRequest, checkSummary, extractSummary, loadCases, userMessage } from "./weekly.mjs";

test("守ることのケースがそろっている（答え、記録にないこと、診断）", () => {
  const cases = loadCases();
  assert.equal(new Set(cases.map((c) => c.id)).size, cases.length);
  assert.ok(cases.some((c) => c.expect.forbidden?.includes("900")));
  assert.ok(cases.some((c) => c.expect.forbidden?.includes("体調")));
  assert.ok(cases.some((c) => c.expect.forbiddenPhrases?.includes("集中力")));
});

test("リクエストは Sonnet で strict なツールを使い、Worker のプロンプトを読む", () => {
  const body = buildRequest(loadCases()[0]);
  assert.equal(body.model, "claude-sonnet-5-5");
  assert.equal(body.tools[0].name, "record_weekly_summary");
  assert.equal(body.tools[0].strict, true);
  assert.match(body.system, /record_weekly_summary/);
  assert.match(userMessage(loadCases()[0]), /取り組んだ問題：4問・自力で解けたのは3問/);
});

test("判定：正答、診断のことば、空を落とす", () => {
  const good = { grown: "割合で図をかいて考えました。", next_focus: "線分図に注目してみてください。" };
  assert.equal(checkSummary(good, { forbidden: ["900"], requiredKeywords: ["割合"] }).pass, true);
  assert.equal(checkSummary({ ...good, grown: "900円と答えました。" }, { forbidden: ["900"] }).pass, false);
  assert.equal(checkSummary({ ...good, next_focus: "集中力がありません。" }, { forbiddenPhrases: ["集中力"] }).pass, false);
  assert.equal(checkSummary({ grown: "", next_focus: "" }, {}).pass, false);
  assert.equal(checkSummary(null, {}).pass, false);
});

test("応答から record_weekly_summary の入力を取り出す", () => {
  const input = { grown: "a", next_focus: "b" };
  assert.deepEqual(extractSummary({ content: [{ type: "tool_use", name: "record_weekly_summary", input }] }), input);
  assert.equal(extractSummary({ content: [{ type: "text", text: "a" }] }), null);
});
