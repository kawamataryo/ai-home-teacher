import { test } from "node:test";
import assert from "node:assert/strict";
import { boardStrings, buildAnalyzerRequest, findLeaks, loadCases, loadTemplate } from "./boards.mjs";

test("評価の問題は8問以上あり、読み取り・思考・作文がそろう", () => {
  const cases = loadCases();
  assert.ok(cases.length >= 8);
  assert.deepEqual(new Set(cases.map((c) => c.kind)), new Set(["reading", "thinking", "writing"]));
  assert.equal(new Set(cases.map((c) => c.id)).size, cases.length);
});

test("分析のリクエストは写真のかわりに問題の文字を入れ、アプリのツールをそのまま使う", () => {
  const template = loadTemplate();
  const body = buildAnalyzerRequest(template, { problem: "1200円の25%引きは？" });
  const content = body.messages[0].content;
  assert.ok(content.every((b) => b.type === "text"));
  assert.match(content[0].text, /1200円の25%引き/);
  assert.deepEqual(body.tools.map((t) => t.name), ["report_analysis", "show_board", "render_svg"]);
  assert.deepEqual(body.tool_choice, { type: "auto" });
  // ひな形は書きかえない
  assert.equal(template.messages[0].content[0].type, "image");
});

test("黒板の文字は SVG の text の中身も拾う", () => {
  const strings = boardStrings({ name: "render_svg", input: { svg: '<svg><text x="1">答え 42</text></svg>', caption: "見てね" } });
  assert.deepEqual(strings, ["答え 42", "見てね"]);
});

test("黒板に答えの数が出ていたら漏れとみなす。問題文にある数は除く", () => {
  const c = { answer: "900円", problem: "1200円の25%引き" };
  const board = (text) => ({ name: "show_board", input: { title: "t", component: { type: "step_cards", steps: [{ heading: "h", detail: text }] } } });
  assert.equal(findLeaks([board("はらうのは 900円")], c).length, 1);
  assert.equal(findLeaks([board("1,200円の75%")], c).length, 0);
  assert.equal(findLeaks([board("？円")], c).length, 0);
  assert.equal(findLeaks([board("9000")], c).length, 0);
  assert.equal(findLeaks([board("x")], { answer: "", problem: "" }).length, 0);
  // 選択肢（問題文にある答え）は、書いてあるだけでは漏れにしない
  assert.equal(findLeaks([board("7月 180冊")], { answer: "7月", problem: "4月 120冊、7月 180冊" }).length, 0);
});

test("文字列の JSON で返った部品を読む（#107）", async () => {
  const { componentOf, closeBrackets } = await import("./boards.mjs");
  assert.equal(componentOf({ component: '{"type":"chalk_drawing","shapes":[]}' }).type, "chalk_drawing");
  assert.equal(componentOf({ component: '{"type":"chalk_drawing","shapes":[{"text":"a}"}]' }).type, "chalk_drawing");
  assert.equal(closeBrackets('{"a":[1,{"b":2}'), '{"a":[1,{"b":2}]}');
  assert.equal(componentOf({ component: { type: "table" } }).type, "table");
});
