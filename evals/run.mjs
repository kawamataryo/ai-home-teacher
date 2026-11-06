#!/usr/bin/env node
// 先生のプロンプトの評価。evals/cases/*.json の会話を Claude に送り、返事を checker.mjs で検査する。
//
// 使い方（Node 22 以上、依存なし）:
//   WORKER_BASE_URL=https://xxx.workers.dev FAMILY_TOKEN=... node evals/run.mjs   # Worker 経由
//   ANTHROPIC_API_KEY=sk-ant-... node evals/run.mjs                                # Anthropic API を直接
//   node evals/run.mjs --dry-run            # 送る内容を表示するだけ（API を呼ばない）
//   node evals/run.mjs --case reading-library
//   node evals/run.mjs --character rika    # キャラを替える（既定は今の先生）。ケースに character があればそちらを使う
//
// キーも Worker の設定もなければ、何もせずに終了する（exit 0）。
// 判定のロジックのテスト: node --test evals/*.test.mjs
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checkReply } from "./checker.mjs";
import { DEFAULT_CHARACTER, characterById, conversationSystemPrompt, conversationTools } from "./prompt.mjs";

export const MODEL = "claude-haiku-5-5";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const casesDir = join(dirname(fileURLToPath(import.meta.url)), "cases");

export function loadCases(dir = casesDir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .flatMap((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
}

// アプリ（TeacherBrain）と同じ形の Messages API の本文。評価では stream しない。
export function buildRequest(testCase, character = DEFAULT_CHARACTER) {
  const speaker = testCase.character ? characterById(testCase.character) : character;
  return {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    // アプリと同じく、会話では考える処理を止める（MessagesRequest.thinkingDisabled）
    thinking: { type: "disabled" },
    system: conversationSystemPrompt({ mode: testCase.mode ?? "study", teacherNote: testCase.teacherNote, character: speaker }),
    messages: testCase.messages.map((m) => ({
      role: m.role,
      content: [{ type: "text", text: m.content }],
    })),
    tools: conversationTools(),
  };
}

// 呼ばれたツールの名前と入力。
export function extractToolUses(response) {
  return (response.content ?? []).filter((b) => b.type === "tool_use" || b.type === "server_tool_use").map((b) => ({ name: b.name, input: b.input }));
}

// Messages API の応答から、読み上げる文字（text block）を取り出す。
export function extractReply(response) {
  return (response.content ?? [])
    .filter((b) => b.type === "text")
    .map((b) => b.text)
    .join("");
}

// 環境変数から送り先を決める。なければ null。
// アプリの TeacherBrain.maxTokens と揃える
export const MAX_TOKENS = 1024;

export function resolveEndpoint(env) {
  if (env.WORKER_BASE_URL && env.FAMILY_TOKEN) {
    return {
      name: "Worker",
      url: new URL("/v1/claude", env.WORKER_BASE_URL).toString(),
      headers: { "content-type": "application/json", authorization: `Bearer ${env.FAMILY_TOKEN}` },
    };
  }
  if (env.ANTHROPIC_API_KEY) {
    return {
      name: "Anthropic API",
      url: ANTHROPIC_URL,
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": ANTHROPIC_VERSION,
      },
    };
  }
  return null;
}

// アプリの TeacherBrain.toolResultText / boardResultText と揃える。
export const TOOL_RESULT_TEXT = "記録しました。子どもには伝えずに、会話を続けてください。";
export const BOARD_RESULT_TEXT = "黒板に図を出しました（子どもに見えています）。もう話したことはくり返さずに、図を見ながら答えられる短い問いかけを1つだけ言ってください。もう問いかけで終えていれば、何も言わなくてかまいません。";

export function toolResultText(name) {
  return name === "show_board" || name === "render_svg" ? BOARD_RESULT_TEXT : TOOL_RESULT_TEXT;
}

// アプリと同じく、ツールだけ呼んで言葉がなかったときは tool_result を付けて1回だけ続きを呼ぶ。
// call(body) は Messages API の応答（JSON）を返す関数。
export async function respond(call, body) {
  const first = await call(body);
  let reply = extractReply(first);
  const toolUses = extractToolUses(first);
  const toolBlocks = (first.content ?? []).filter((b) => b.type === "tool_use");
  // 返事の長さの上限（max_tokens）で切れていないか。図が長いと、ツールの入力が途中で切れる
  const stops = [{ stop: first.stop_reason, outputTokens: first.usage?.output_tokens }];
  // アプリ（TeacherBrain）と同じく、言葉がないとき・黒板に図を出したときは続きを1回もらう
  const shownBoard = toolBlocks.some((b) => b.name === "show_board");
  if (first.stop_reason === "tool_use" && toolBlocks.length > 0 && (!reply.trim() || shownBoard)) {
    const next = await call({
      ...body,
      messages: [
        ...body.messages,
        { role: "assistant", content: first.content },
        {
          role: "user",
          content: toolBlocks.map((b) => ({ type: "tool_result", tool_use_id: b.id, content: toolResultText(b.name) })),
        },
      ],
    });
    reply += extractReply(next);
    toolUses.push(...extractToolUses(next));
    stops.push({ stop: next.stop_reason, outputTokens: next.usage?.output_tokens });
  }
  return { reply, toolUses, stops };
}

async function callClaude(endpoint, body) {
  const res = await fetch(endpoint.url, { method: "POST", headers: endpoint.headers, body: JSON.stringify(body) });
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text}`);
  return JSON.parse(text);
}

async function main(argv, env) {
  const dryRun = argv.includes("--dry-run");
  const only = argv.includes("--case") ? argv[argv.indexOf("--case") + 1] : null;
  // --case はカンマで区切って複数えらべる
  const picked = only ? new Set(only.split(",")) : null;
  const character = argv.includes("--character") ? characterById(argv[argv.indexOf("--character") + 1]) : DEFAULT_CHARACTER;
  const cases = loadCases().filter((c) => !picked || picked.has(c.id));
  if (cases.length === 0) {
    console.error(`評価のケースが見つかりません${only ? `: ${only}` : ""}`);
    return 1;
  }

  if (dryRun) {
    for (const c of cases) console.log(JSON.stringify({ id: c.id, request: buildRequest(c, character) }, null, 2));
    return 0;
  }

  const endpoint = resolveEndpoint(env);
  if (!endpoint) {
    console.log(
      "評価をスキップしました: API の設定がありません。\n" +
        "  Worker 経由: WORKER_BASE_URL と FAMILY_TOKEN を設定\n" +
        "  直接: ANTHROPIC_API_KEY を設定\n" +
        "判定ロジックだけのテストは `node --test evals/*.test.mjs` で実行できます。",
    );
    return 0;
  }

  console.log(`${endpoint.name} で ${cases.length} 件を評価します（${MODEL} / ${character.name}${character.honorific}）\n`);
  let failed = 0;
  for (const c of cases) {
    try {
      const { reply, toolUses, stops } = await respond((body) => callClaude(endpoint, body), buildRequest(c, character));
      // 黒板の文字にも答えを書かない
      const boardText = toolUses.filter((t) => t.name === "show_board").map((t) => JSON.stringify(t.input)).join("\n");
      const result = checkReply(reply, c.expect, toolUses.map((t) => t.name), boardText);
      if (stops.some((s) => s.stop === "max_tokens")) {
        result.pass = false;
        result.failures.push(`返事の長さの上限（max_tokens ${MAX_TOKENS}）で切れた`);
      }
      if (!result.pass) failed++;
      console.log(`${result.pass ? "PASS" : "FAIL"} ${c.id}（${c.title}）`);
      console.log(`  先生: ${reply.replaceAll("\n", " ")}`);
      for (const t of toolUses) console.log(`  ツール: ${t.name} ${JSON.stringify(t.input)}`);
      console.log(`  出力: ${stops.map((s) => `${s.outputTokens ?? "?"} トークン（${s.stop}）`).join(" → ")}`);
      for (const f of result.failures) console.log(`  - ${f}`);
      for (const w of result.warnings) console.log(`  (注意) ${w}`);
    } catch (error) {
      failed++;
      console.log(`ERROR ${c.id}: ${error.message}`);
    }
  }
  console.log(`\n${cases.length - failed}/${cases.length} 件 OK`);
  return failed === 0 ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2), process.env);
}
