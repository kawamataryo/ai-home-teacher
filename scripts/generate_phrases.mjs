#!/usr/bin/env node
// 先生の定型句の音声を ElevenLabs（Worker の /v1/tts 経由）で作り、アプリに同梱するファイルを書き出す。
//
// 使い方（Node 22 以上、依存なし）:
//   WORKER_BASE_URL=https://xxx.workers.dev FAMILY_TOKEN=... node scripts/generate_phrases.mjs
//   node scripts/generate_phrases.mjs --force        # すでにあるものも作り直す
//   node scripts/generate_phrases.mjs --key iine     # 1 つだけ
//
// 一覧: ios/HomeTeacher/Resources/Phrases/teacher_phrases.json（アプリの PhraseCache と共通）
// 出力: ios/HomeTeacher/Resources/Phrases/phrase_<key>.json（SynthesizedSpeech の JSON。音声は MP3 の base64）
// 書き出したら `cd ios && xcodegen generate` をやり直す。
//
// Worker の設定がなければ、何もせずに終了する（exit 0）。そのときアプリは初回起動時に
// PhraseCache.prepare で作ってディスクにキャッシュする（オフラインなら AVSpeechSynthesizer の声）。
// パーサーのテスト: node --test scripts/*.test.mjs
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseTTSStream } from "./tts_stream.mjs";

const phrasesDir = join(dirname(fileURLToPath(import.meta.url)), "..", "ios", "HomeTeacher", "Resources", "Phrases");

function parseArgs(argv) {
  const args = { force: false, key: null, voiceId: process.env.ELEVENLABS_VOICE_ID || null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--force") args.force = true;
    else if (argv[i] === "--key") args.key = argv[++i];
    else if (argv[i] === "--voice-id") args.voiceId = argv[++i];
  }
  return args;
}

async function synthesize(baseURL, token, text, voiceId) {
  const response = await fetch(new URL("/v1/tts", baseURL), {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(voiceId ? { text, voice_id: voiceId } : { text }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${await response.text()}`);
  const pieces = [];
  const decoder = new TextDecoder();
  for await (const chunk of response.body) pieces.push(decoder.decode(chunk, { stream: true }));
  pieces.push(decoder.decode());
  return parseTTSStream(pieces);
}

async function main() {
  const baseURL = process.env.WORKER_BASE_URL;
  const token = process.env.FAMILY_TOKEN;
  if (!baseURL || !token) {
    console.log("WORKER_BASE_URL と FAMILY_TOKEN がないので、定型句の生成をスキップします");
    return;
  }
  const args = parseArgs(process.argv.slice(2));
  const phrases = JSON.parse(readFileSync(join(phrasesDir, "teacher_phrases.json"), "utf8"))
    .filter((p) => !args.key || p.key === args.key);

  let failed = 0;
  for (const phrase of phrases) {
    const out = join(phrasesDir, `phrase_${phrase.key}.json`);
    if (!args.force && existsSync(out)) {
      const existing = JSON.parse(readFileSync(out, "utf8"));
      if (existing.text === phrase.text) {
        console.log(`skip ${phrase.key}（作成済み）`);
        continue;
      }
    }
    try {
      const { audio, alignment } = await synthesize(baseURL, token, phrase.text, args.voiceId);
      if (audio.length === 0) throw new Error("音声が空");
      const speech = {
        text: phrase.text,
        provider: "elevenlabs",
        format: "mp3",
        audio: audio.toString("base64"),
        ...(alignment ? { alignment } : {}),
      };
      writeFileSync(out, JSON.stringify(speech) + "\n");
      console.log(`ok   ${phrase.key} ${phrase.text}（${audio.length} bytes）`);
    } catch (error) {
      failed += 1;
      console.error(`fail ${phrase.key}: ${error.message}`);
    }
  }
  if (failed > 0) process.exitCode = 1;
}

await main();
