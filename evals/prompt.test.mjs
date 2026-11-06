// 今の先生（既定）のプロンプトが、キャラを分ける前と同じ内容で組み上がることを確かめる（#118, #119）。
// evals/fixtures/prompts/haru/ は分ける前の main で書き出した正解。アプリ側は PromptGoldenTests.swift で同じファイルと比べる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { CHARACTERS, DEFAULT_CHARACTER, SEPARATOR, characterProfile, conversationSystemPrompt, loadPrompt } from "./prompt.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "prompts", "haru");
const golden = (name) => readFileSync(join(dir, `${name}.txt`), "utf8");
const variables = { today: "2026年11月6日（金）" };

test("既定の先生は haru", () => {
  assert.equal(DEFAULT_CHARACTER.id, "haru");
  assert.equal(DEFAULT_CHARACTER.name, "ハル");
  assert.equal(new Set(CHARACTERS.map((c) => c.id)).size, CHARACTERS.length);
});

// 比べるのはキャラに関わる部分だけ（teacher と声かけ）。hint_ladder など共通の部分は別の変更で変わってよい。
test("先生のプロンプトと声かけが分ける前と同じ", () => {
  assert.equal(loadPrompt("teacher"), golden("teacher"));
  assert.equal(loadPrompt("nudge_variation"), golden("nudge_variation"));
});

test("会話は分ける前の先生のプロンプトから始まる", () => {
  assert.ok(conversationSystemPrompt({ mode: "study", variables }).startsWith(golden("teacher") + SEPARATOR));
});

test("どのキャラでも性格のファイルがあり、hint_ladder と safety が必ず入る", () => {
  const hint = loadPrompt("hint_ladder");
  const safety = loadPrompt("safety");
  for (const character of CHARACTERS) {
    const prompt = conversationSystemPrompt({ variables, character });
    assert.ok(prompt.includes(characterProfile(character).split("\n")[0]), character.id);
    assert.ok(prompt.includes(hint), `${character.id} に hint_ladder がない`);
    assert.ok(prompt.includes(safety), `${character.id} に safety がない`);
    assert.ok(prompt.includes("答えをそのまま言わない"), character.id);
    assert.ok(!prompt.includes("{{"), `${character.id} に差し込み忘れがある`);
    assert.ok(prompt.includes(`「${character.name}${character.honorific}」`), character.id);
    assert.ok(!loadPrompt("nudge_variation", {}, character).includes("{{"), character.id);
  }
});

test("先生のメモが変わってもキャラごとのプロンプトの前半は同じ（キャッシュが効く）", () => {
  for (const character of CHARACTERS) {
    const a = conversationSystemPrompt({ variables, character, teacherNote: "- 段階 1" });
    const b = conversationSystemPrompt({ variables, character, teacherNote: "- 段階 2" });
    const heading = "# 先生のメモ";
    assert.equal(a.slice(0, a.lastIndexOf(heading)), b.slice(0, b.lastIndexOf(heading)), character.id);
  }
});
