import assert from "node:assert/strict";
import { test } from "node:test";
import { azureAlignment, azureDuration, bundledPhraseName, ownPhrases, phrasesFor } from "./phrases_lib.mjs";

test("今の先生は今までの名前、ほかのキャラは別の名前にする", () => {
  assert.equal(bundledPhraseName("haru", "iine"), "phrase_iine");
  assert.equal(bundledPhraseName("rika", "iine"), "phrase_rika_iine");
});

test("言い替えがある定型句だけ文を替える", () => {
  const base = [{ key: "iine", text: "いいね！" }, { key: "naruhodo", text: "なるほど" }];
  assert.deepEqual(phrasesFor({ phrases: { iine: "いいね、それ！" } }, base), [
    { key: "iine", text: "いいね、それ！" },
    { key: "naruhodo", text: "なるほど" },
  ]);
  assert.deepEqual(phrasesFor({}, base), base);
});

test("自己紹介とあいさつも定型句にする", () => {
  const base = [{ key: "iine", text: "いいね！" }];
  assert.deepEqual(phrasesFor({ intro: "はじめまして。", greeting: "よろしくね！" }, base), [
    { key: "iine", text: "いいね！" },
    { key: "intro", text: "はじめまして。" },
    { key: "greeting", text: "よろしくね！" },
  ]);
});

test("Azure の音声の長さから文字タイミングを作る", () => {
  assert.equal(azureDuration(6000), 1);
  const alignment = azureAlignment("はい", 6000);
  assert.deepEqual(alignment.characters, ["は", "い"]);
  assert.deepEqual(alignment.character_start_times_seconds, [0, 0.5]);
  assert.deepEqual(alignment.character_end_times_seconds, [0.5, 1]);
  assert.equal(azureAlignment("", 6000), null);
  assert.equal(azureAlignment("はい", 0), null);
});

test("自己紹介とあいさつも定型句にする。なければ出さない", () => {
  assert.deepEqual(ownPhrases({ intro: "ボルだよ", greeting: "よろしく" }).map((p) => p.key), ["intro", "greeting"]);
  assert.deepEqual(ownPhrases({ intro: "", greeting: "よろしく" }).map((p) => p.key), ["greeting"]);
});
