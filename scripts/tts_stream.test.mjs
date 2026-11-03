import assert from "node:assert/strict";
import { test } from "node:test";
import { createObjectScanner, parseTTSStream } from "./tts_stream.mjs";

function chunk(text, audio, offset = 0) {
  const chars = [...text];
  return JSON.stringify({
    audio_base64: Buffer.from(audio).toString("base64"),
    alignment: {
      characters: chars,
      character_start_times_seconds: chars.map((_, i) => offset + i * 0.1),
      character_end_times_seconds: chars.map((_, i) => offset + (i + 1) * 0.1),
    },
  });
}

test("改行区切りでもくっついていても同じに読む", () => {
  const objects = [chunk('い{"', [1, 2]), chunk("ね\\}", [3])];
  const a = parseTTSStream([objects.join("\n") + "\n"]);
  const b = parseTTSStream([objects.join("")]);
  assert.deepEqual(a, b);
  assert.deepEqual([...a.audio], [1, 2, 3]);
  assert.equal(a.alignment.characters.join(""), 'い{"ね\\}');
});

test("どこで切って届いても同じに読む", () => {
  const body = chunk("いいね", [1]) + chunk("！", [2], 0.3);
  const expected = parseTTSStream([body]);
  for (let cut = 1; cut < body.length; cut++) {
    assert.deepEqual(parseTTSStream([body.slice(0, cut), body.slice(cut)]), expected, `cut ${cut}`);
  }
});

test("チャンクの先頭からの時刻は前の終わりを足す", () => {
  const { alignment } = parseTTSStream([chunk("あい", [1]) + chunk("う", [2])]);
  assert.deepEqual(alignment.character_start_times_seconds.map((t) => Math.round(t * 10) / 10), [0, 0.1, 0.2]);
});

test("途中で終わったら投げる", () => {
  assert.throws(() => parseTTSStream(['{"audio_base64":"AA']));
  assert.equal(createObjectScanner().hasPartialObject, false);
});

test("上流のエラーは投げる", () => {
  assert.throws(() => parseTTSStream(['{"detail":{"status":"quota_exceeded"}}']), /upstream error/);
});
