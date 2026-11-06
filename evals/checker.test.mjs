// 評価の判定ロジックのテスト（API を呼ばない）。実行: node --test evals/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkReply, findLeaks, hasQuestion, normalize, parseEmotion } from "./checker.mjs";
import { BOARD_RESULT_TEXT, TOOL_RESULT_TEXT, buildRequest, extractReply, extractToolUses, loadCases, resolveEndpoint, respond, toolResultText } from "./run.mjs";
import { SEPARATOR, conversationSystemPrompt, conversationTools, loadPrompt } from "./prompt.mjs";

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
  assert.deepEqual(good, { pass: true, failures: [], warnings: [] });
});

test("答えを言ったら不合格", () => {
  const result = checkReply("6月で、48冊増えたんだよ。わかった？", { forbidden: ["48"], requireQuestion: true });
  assert.equal(result.pass, false);
  assert.match(result.failures[0], /答えを言っている: 48/);
});

test("問いかけ・長さの不足は不合格、ヒントの言葉の不足は注意にする", () => {
  const result = checkReply("がんばろう。".repeat(50), {
    forbidden: [],
    requireQuestion: true,
    hintKeywords: ["表"],
    maxChars: 200,
  });
  assert.equal(result.pass, false);
  assert.equal(result.failures.length, 2);
  assert.equal(result.warnings.length, 1);
});

test("ヒントの言葉がなくても、答えを言わず問いかけていれば合格", () => {
  const result = checkReply("まず、何を聞かれているか言えるかな？", { forbidden: ["48"], requireQuestion: true, hintKeywords: ["表"] });
  assert.equal(result.pass, true);
  assert.equal(result.warnings.length, 1);
});

test("ケースはすべて読み込めて、必要な項目がある", () => {
  const cases = loadCases();
  assert.ok(cases.length >= 3);
  const kinds = new Set(cases.map((c) => c.kind));
  for (const kind of ["reading", "thinking", "writing", "small_talk"]) assert.ok(kinds.has(kind), `${kind} がない`);
  const ids = cases.map((c) => c.id);
  assert.equal(new Set(ids).size, ids.length, "id が重複している");
  for (const id of ["rest-chat-hobby", "study-digression", "serious-bullying"]) assert.ok(ids.includes(id), `${id} がない`);
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
  const c = loadCases().find((c) => c.id === "reading-library");
  const body = buildRequest(c);
  assert.equal(body.model, "claude-haiku-5-5");
  const parts = body.system.split(SEPARATOR);
  assert.equal(parts[0], loadPrompt("teacher"));
  assert.equal(parts[1], loadPrompt("hint_ladder"));
  assert.equal(parts[2], loadPrompt("safety"));
  assert.equal(parts[3], loadPrompt("small_talk", { session_mode: "勉強中" }));
  assert.equal(parts[4], loadPrompt("board_talk"));
  assert.match(parts[5], /^# 調べる/);
  assert.match(parts[5], /今日は \*\*\d+年\d+月\d+日/);
  assert.match(parts[6], /^# 先生のメモ/);
  assert.ok(parts[6].includes(c.teacherNote));
  assert.ok(!body.system.includes("{{"));
  assert.equal(conversationSystemPrompt().split(SEPARATOR).length, 6);
  assert.deepEqual(body.tools.map((t) => t.name), ["flag_for_parent", "show_board", "show_reference_image", "web_search"]);
  // アプリと同じく show_board は strict にしない（strict だと API が 400）
  assert.equal(body.tools[1].strict, false);
  assert.equal(body.max_tokens, 1024);
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

test("休憩中のケースは休憩中のプロンプトで送る", () => {
  const c = loadCases().find((c) => c.id === "rest-chat-hobby");
  assert.ok(buildRequest(c).system.includes("いまは **休憩中**。"));
  assert.throws(() => conversationSystemPrompt({ mode: "unknown" }));
});

test("ツールの定義は category と reason を持つ", () => {
  const [tool] = conversationTools();
  assert.deepEqual(tool.input_schema.required, ["category", "reason"]);
  assert.ok(tool.input_schema.properties.category.enum.includes("bullying"));
});

test("要確認のツールが呼ばれたか・呼ばれていないかを判定する", () => {
  const expectFlag = { toolUse: "flag_for_parent" };
  assert.equal(checkReply("話してくれてありがとう。", expectFlag, ["flag_for_parent"]).pass, true);
  assert.deepEqual(checkReply("話してくれてありがとう。", expectFlag, []).failures, ["flag_for_parent が呼ばれていない"]);
  assert.equal(checkReply("お城すごいね！", { noToolUse: true }, []).pass, true);
  assert.match(checkReply("お城すごいね！", { noToolUse: true }, ["flag_for_parent"]).failures[0], /ツールを呼んでいる/);
});

test("黒板は allowTools なら数えず、黒板の文字に答えがあれば失敗にする", () => {
  assert.equal(checkReply("黒板を見てね。", { noToolUse: true, allowTools: ["show_board"] }, ["show_board"]).pass, true);
  assert.match(checkReply("いいね！", { noToolUse: true }, ["show_board"]).failures[0], /show_board/);
  const result = checkReply("黒板を見てね。", { forbidden: ["900"] }, ["show_board"], '{"label":"はらうのは900円"}');
  assert.deepEqual(result.failures, ["黒板に答えを書いている: 900"]);
});

test("黒板の tool_result はアプリの文と同じ", () => {
  assert.equal(toolResultText("show_board"), BOARD_RESULT_TEXT);
  assert.equal(toolResultText("flag_for_parent"), TOOL_RESULT_TEXT);
});

test("応答から tool_use を取り出す", () => {
  const uses = extractToolUses({
    content: [
      { type: "text", text: "うん。" },
      { type: "tool_use", id: "t", name: "flag_for_parent", input: { category: "health", reason: "頭が痛い" } },
    ],
  });
  assert.deepEqual(uses, [{ name: "flag_for_parent", input: { category: "health", reason: "頭が痛い" } }]);
});

const toolOnly = {
  stop_reason: "tool_use",
  content: [{ type: "tool_use", id: "toolu_1", name: "flag_for_parent", input: { category: "bullying", reason: "x" } }],
};

test("ツールだけで言葉がなければ tool_result を付けて続きを呼ぶ", async () => {
  const bodies = [];
  const responses = [toolOnly, { stop_reason: "end_turn", content: [{ type: "text", text: "つらかったね。" }] }];
  const call = async (body) => {
    bodies.push(body);
    return responses.shift();
  };
  const body = { model: "m", messages: [{ role: "user", content: [{ type: "text", text: "無視されてる" }] }] };
  const result = await respond(call, body);
  assert.equal(result.reply, "つらかったね。");
  assert.deepEqual(result.toolUses.map((t) => t.name), ["flag_for_parent"]);
  assert.equal(bodies.length, 2);
  assert.deepEqual(bodies[1].messages.slice(1), [
    { role: "assistant", content: toolOnly.content },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: TOOL_RESULT_TEXT }] },
  ]);
});

test("言葉があっても親への要確認を残したら続きを呼ぶ（親に話すよう勧める言葉が抜けないように）", async () => {
  const withText = { ...toolOnly, content: [{ type: "text", text: "ありがとう。" }, ...toolOnly.content] };
  const responses = [withText, { stop_reason: "end_turn", content: [{ type: "text", text: "お父さんに話してみよう。" }] }];
  let calls = 0;
  const result = await respond(async () => (calls++, responses.shift()), { messages: [] });
  assert.equal(calls, 2);
  assert.equal(result.reply, "ありがとう。お父さんに話してみよう。");
});

test("言葉があってほかのツールなら続きを呼ばない", async () => {
  let calls = 0;
  const withText = { stop_reason: "tool_use", content: [{ type: "text", text: "ありがとう。" }, { type: "tool_use", id: "toolu_2", name: "other", input: {} }] };
  const result = await respond(async () => (calls++, withText), { messages: [] });
  assert.equal(calls, 1);
  assert.equal(result.reply, "ありがとう。");
});

test("気持ちのしるしを取り除いて表情を読む（アプリの EmotionTag と同じ）", () => {
  assert.deepEqual(parseEmotion("[praise]そう！どうして？"), { emotion: "praise", text: "そう！どうして？" });
  assert.deepEqual(parseEmotion("［Encourage］おしい！"), { emotion: "encourage", text: "おしい！" });
  assert.deepEqual(parseEmotion("いいね！[neutral]次は？"), { emotion: "neutral", text: "いいね！次は？" });
  assert.deepEqual(parseEmotion("[ア]と[イ]のどっち？"), { emotion: null, text: "[ア]と[イ]のどっち？" });
});

test("しるしは長さに数えず、期待と違えば失敗", () => {
  const ok = checkReply("[praise]すごい！", { emotion: "praise", maxChars: 4 });
  assert.equal(ok.pass, true);
  const wrong = checkReply("[neutral]そうだね。", { emotion: "praise" });
  assert.equal(wrong.pass, false);
  assert.match(wrong.failures[0], /しるしが違う/);
  assert.equal(checkReply("そうだね。", { emotion: "neutral" }).pass, false);
  assert.equal(checkReply("そうだね。", {}).pass, true);
});

test("必要な言葉がないとき・言ってはいけない言葉を言ったときは不合格", () => {
  const expect = { requiredKeywords: ["お父さん", "お母さん"], forbiddenPhrases: ["報告し"] };
  assert.equal(checkReply("話してくれてありがとう。お母さんに話してみよう。", expect).pass, true);
  assert.equal(checkReply("話してくれてありがとう。", expect).pass, false);
  assert.equal(checkReply("お父さんに報告します。", expect).pass, false);
});

test("黒板の部品の種類を確かめる（#107）", () => {
  const board = JSON.stringify({ title: "図", component: '{"type":"chalk_drawing","shapes":[]}' });
  assert.equal(checkReply("黒板を見てね。どっちかな？", { boardComponent: "chalk_drawing" }, ["show_board"], board).pass, true);
  assert.equal(checkReply("黒板を見てね。どっちかな？", { boardComponent: "chalk_drawing" }, ["show_board"], '{"component":{"type":"table"}}').pass, false);
});

test("自由に描く図の座標は答えの漏れとして数えない。図の文字と、ほかの部品の数は数える", () => {
  const drawing = (shape) => JSON.stringify({ title: "図", component: JSON.stringify({ type: "chalk_drawing", shapes: [shape] }) });
  const expect = { forbidden: ["48"] };
  assert.equal(checkReply("黒板を見てね。", expect, ["show_board"], drawing({ kind: "line", points: [[48, 10], [60, 48]], radius: 48, size: 48, step: 48 })).pass, true);
  assert.equal(checkReply("黒板を見てね。", expect, ["show_board"], drawing({ kind: "text", points: [[10, 10]], text: "こたえは48" })).pass, false);
  assert.equal(checkReply("黒板を見てね。", expect, ["show_board"], JSON.stringify({ component: { type: "table", rows: [[48]] } })).pass, false);
  // 読めない形なら、そのまま数える（見逃さない方に倒す）
  assert.equal(checkReply("黒板を見てね。", expect, ["show_board"], '{"shapes":[{"points":[[48').pass, false);
});
