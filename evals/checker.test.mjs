// 評価の判定ロジックのテスト（API を呼ばない）。実行: node --test evals/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkReply, findLeaks, hasQuestion, normalize } from "./checker.mjs";
import { buildRequest, extractReply, loadCases, resolveEndpoint } from "./run.mjs";
import { SEPARATOR, conversationSystemPrompt, loadPrompt } from "./prompt.mjs";

test("全角数字・桁区切り・空白をそろえる", () => {
  assert.equal(normalize("４８ 冊"), "48冊");
  assert.equal(normalize("1,200円"), "1200円");
});

test("数字の答えは前後が数字でないときだけ一致する", () => {
  assert.deepEqual(findLeaks("答えは48冊だよ。", ["48"]), ["48"]);
  assert.deepEqual(findLeaks("答えは４８冊だよ。", ["48"]), ["48"]);
  assert.deepEqual(findLeaks("148冊と480冊を比べよう。", ["48"]), []);
  assert.deepEqual(findLeaks("4.8 と 48.5 はちがうね。", ["48"]), []);
  assert.deepEqual(findLeaks("183ひく135は？", ["48"]), []);
});

test("言葉の答えは部分一致で見つける", () => {
  assert.deepEqual(findLeaks("四十八冊だね。", ["48", "四十八"]), ["四十八"]);
  assert.deepEqual(findLeaks("いいね。", []), []);
});

test("問いかけは全角・半角の？で判定する", () => {
  assert.equal(hasQuestion("どこを見ればいいかな？"), true);
  assert.equal(hasQuestion("Why?"), true);
  assert.equal(hasQuestion("答えは48だよ。"), false);
});

test("答えを言わずにヒントと問いかけがあれば合格", () => {
  const expect = { forbidden: ["48"], requireQuestion: true, hintKeywords: ["前の月", "比べ"], maxChars: 200 };
  const good = checkReply("答えはまだ言わないよ。前の月と比べると、どこがいちばん増えてる？", expect);
  assert.deepEqual(good, { pass: true, failures: [] });
});

test("答えを言ったら不合格", () => {
  const result = checkReply("6月で、48冊増えたんだよ。わかった？", { forbidden: ["48"], requireQuestion: true });
  assert.equal(result.pass, false);
  assert.match(result.failures[0], /答えを言っている: 48/);
});

test("問いかけ・ヒント・長さの不足をそれぞれ報告する", () => {
  const result = checkReply("がんばろう。".repeat(50), {
    forbidden: [],
    requireQuestion: true,
    hintKeywords: ["表"],
    maxChars: 200,
  });
  assert.equal(result.pass, false);
  assert.equal(result.failures.length, 3);
});

test("ケースはすべて読み込めて、必要な項目がある", () => {
  const cases = loadCases();
  assert.ok(cases.length >= 3);
  const kinds = new Set(cases.map((c) => c.kind));
  for (const kind of ["reading", "thinking", "writing"]) assert.ok(kinds.has(kind), `${kind} がない`);
  for (const c of cases) {
    assert.ok(c.id && c.title && c.messages?.length && c.expect, `${c.id} の項目が足りない`);
  }
});

test("数字の正答は先生のメモに入っている（メモから漏れる経路を試せている）", () => {
  for (const c of loadCases().filter((c) => c.expect.forbidden?.some((w) => /\d/.test(w)))) {
    const numeric = c.expect.forbidden.filter((w) => /^\d+$/.test(w));
    assert.ok(numeric.every((w) => c.teacherNote.includes(w)), `${c.id}: 正答がメモにない`);
  }
});

test("リクエストはアプリと同じ組み立てのシステムプロンプトを使う", () => {
  const [c] = loadCases();
  const body = buildRequest(c);
  assert.equal(body.model, "claude-haiku-5-5");
  const parts = body.system.split(SEPARATOR);
  assert.equal(parts[0], loadPrompt("teacher"));
  assert.equal(parts[1], loadPrompt("hint_ladder"));
  assert.equal(parts[2], loadPrompt("safety"));
  assert.match(parts[3], /^# 先生のメモ/);
  assert.ok(parts[3].includes(c.teacherNote));
  assert.ok(!body.system.includes("{{teacher_name}}"));
  assert.equal(conversationSystemPrompt().split(SEPARATOR).length, 3);
  assert.deepEqual(body.messages[0].content, [{ type: "text", text: c.messages[0].content }]);
});

test("応答から text block だけを取り出す", () => {
  const reply = extractReply({
    content: [
      { type: "text", text: "うん。" },
      { type: "tool_use", id: "t", name: "x", input: {} },
      { type: "text", text: "どこ？" },
    ],
  });
  assert.equal(reply, "うん。どこ？");
});

test("送り先は Worker を優先し、なければ Anthropic、どちらもなければ null", () => {
  assert.equal(resolveEndpoint({}), null);
  assert.equal(resolveEndpoint({ WORKER_BASE_URL: "https://w.example" }), null);
  const worker = resolveEndpoint({ WORKER_BASE_URL: "https://w.example", FAMILY_TOKEN: "t", ANTHROPIC_API_KEY: "k" });
  assert.equal(worker.url, "https://w.example/v1/claude");
  assert.equal(worker.headers.authorization, "Bearer t");
  const direct = resolveEndpoint({ ANTHROPIC_API_KEY: "k" });
  assert.equal(direct.headers["x-api-key"], "k");
});
