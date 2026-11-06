// 今の先生（既定）のプロンプトが、キャラを分ける前と同じ内容で組み上がることを確かめる（#118, #119）。
// evals/fixtures/prompts/haru/ は分ける前の main で書き出した正解。アプリ側は PromptGoldenTests.swift で同じファイルと比べる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { CHARACTERS, DEFAULT_CHARACTER, SEPARATOR, conversationSystemPrompt, loadPrompt } from "./prompt.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "prompts", "haru");
const golden = (name) => readFileSync(join(dir, `${name}.txt`), "utf8");
const variables = { today: "2026年11月6日（金）" };

test("既定の先生は haru", () => {
  assert.equal(DEFAULT_CHARACTER.id, "haru");
  assert.equal(DEFAULT_CHARACTER.name, "ハル");
  assert.equal(new Set(CHARACTERS.map((c) => c.id)).size, CHARACTERS.length);
});

test("会話（勉強中）が分ける前と同じ", () => {
  assert.equal(conversationSystemPrompt({ mode: "study", variables }), golden("conversation_study"));
});

test("会話（休憩中・前回のこと・先生のメモあり）が分ける前と同じ", () => {
  const prompt = conversationSystemPrompt({
    mode: "rest",
    variables,
    previousSession: "## 前回の勉強（昨日）\n\n割合の問題",
    teacherNote: "- 正答: 40",
  });
  assert.equal(prompt, golden("conversation_rest_full"));
});

test("ふり返りと言いかえが分ける前と同じ", () => {
  assert.equal([loadPrompt("teacher"), loadPrompt("reflection")].join(SEPARATOR), golden("reflection_system"));
  assert.equal(loadPrompt("nudge_variation"), golden("nudge_variation"));
});
