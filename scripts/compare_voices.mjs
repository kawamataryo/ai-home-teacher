#!/usr/bin/env node
// 同じ先生の文を ElevenLabs（/v1/tts）と Azure（/v1/tts/azure）で作り、聞き比べ用の MP3 を書き出す（#98）。
// 1 文ずつ、最初の 1 バイトが届くまでと全部届くまでの時間も表示する。
//
// 使い方（Node 22 以上、依存なし）:
//   WORKER_BASE_URL=https://xxx.workers.dev FAMILY_TOKEN=... node scripts/compare_voices.mjs [出力先]
//   node scripts/compare_voices.mjs out --azure-voice ja-JP-AoiNeural   # Azure の声を変えて試す
//
// 出力: <出力先（既定 voice-compare）>/<番号>_<elevenlabs|azure>.mp3
// Worker の設定がなければ、何もせずに終了する（exit 0）。
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseTTSStream } from "./tts_stream.mjs";

const SENTENCES = [
  "お、どれどれ。ちょっと見せて？",
  "いいね！ここまでは合ってるよ。",
  "じゃあ、3 と 5 だと、どっちが大きいかな？",
  "そろそろ休憩しよっか。",
];

function parseArgs(argv) {
  const args = { out: "voice-compare", azureVoice: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--azure-voice") args.azureVoice = argv[++i];
    else args.out = argv[i];
  }
  return args;
}

// 本文を全部受け取る。最初の 1 バイトまでの時間と、全部届くまでの時間（ミリ秒）も返す
async function fetchTimed(baseURL, token, path, body) {
  const started = performance.now();
  const response = await fetch(new URL(path, baseURL), {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path} HTTP ${response.status}: ${await response.text()}`);
  const chunks = [];
  let firstByte = null;
  for await (const chunk of response.body) {
    firstByte ??= performance.now() - started;
    chunks.push(Buffer.from(chunk));
  }
  return { bytes: Buffer.concat(chunks), firstByte: Math.round(firstByte ?? 0), total: Math.round(performance.now() - started) };
}

async function elevenlabs(baseURL, token, text) {
  const result = await fetchTimed(baseURL, token, "/v1/tts", { text });
  const { audio } = parseTTSStream([result.bytes.toString("utf8")]);
  return { ...result, bytes: audio };
}

async function azure(baseURL, token, text, voice) {
  return fetchTimed(baseURL, token, "/v1/tts/azure", voice ? { text, voice } : { text });
}

async function main() {
  const baseURL = process.env.WORKER_BASE_URL;
  const token = process.env.FAMILY_TOKEN;
  if (!baseURL || !token) {
    console.log("WORKER_BASE_URL と FAMILY_TOKEN がないので、聞き比べをスキップします");
    return;
  }
  const args = parseArgs(process.argv.slice(2));
  mkdirSync(args.out, { recursive: true });
  let failed = 0;
  for (const [index, text] of SENTENCES.entries()) {
    const n = String(index + 1).padStart(2, "0");
    for (const [name, run] of [
      ["elevenlabs", () => elevenlabs(baseURL, token, text)],
      ["azure", () => azure(baseURL, token, text, args.azureVoice)],
    ]) {
      try {
        const result = await run();
        const file = join(args.out, `${n}_${name}.mp3`);
        writeFileSync(file, result.bytes);
        console.log(`${file}  最初の音 ${result.firstByte}ms / 全部 ${result.total}ms  ${text}`);
      } catch (error) {
        failed++;
        console.error(`${n}_${name}: ${error.message}`);
      }
    }
  }
  if (failed) process.exitCode = 1;
}

await main();
