#!/usr/bin/env node
// 週のまとめ（#162）の評価。アプリには同梱しないので、プロンプトとツールは worker/prompts/ から読む。
// 使い方（Node 22 以上、依存なし）:
//   WORKER_BASE_URL=https://xxx.workers.dev FAMILY_TOKEN=... node evals/weekly.mjs
//   node evals/weekly.mjs --dry-run
// 設定がなければ何もせずに終了する（exit 0）。判定のテスト: node --test evals/*.test.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checkReply } from "./checker.mjs";
import { resolveEndpoint } from "./run.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const promptsDir = join(here, "..", "worker", "prompts");
export const TOOL_NAME = "record_weekly_summary";
export const MODEL = "claude-sonnet-5-5";

export function loadCases() {
  return JSON.parse(readFileSync(join(here, "weekly", "cases.json"), "utf8"));
}

// worker/src/dashboard/weekly.ts の weeklyUserMessage と揃える
export function userMessage(testCase) {
  const problems = testCase.sessions.flatMap((s) => s.problems);
  const solved = problems.filter((p) => p.result.startsWith("自力で解けた")).length;
  const lines = [
    "# 2026-11-02 からの1週間の記録",
    "",
    `- 勉強した回数：${testCase.sessions.length}回`,
    `- 集中した時間：合計${testCase.sessions.length * 25}分`,
    `- 取り組んだ問題：${problems.length}問・自力で解けたのは${solved}問`,
  ];
  for (const s of testCase.sessions) {
    lines.push("", `## ${s.date} の勉強`, `- 要約：${s.summary}`);
    if (s.teacher_note) lines.push(`- 先生のひとこと：${s.teacher_note}`);
    for (const p of s.problems) lines.push(`- 問題 [${p.kind}] ${p.summary}：${p.result}`);
  }
  lines.push("", `必ず ${TOOL_NAME} ツールを呼んで記録してください（文章だけで答えないこと）。`);
  return lines.join("\n");
}

export function buildRequest(testCase) {
  return {
    model: MODEL,
    max_tokens: 1000,
    system: readFileSync(join(promptsDir, "weekly_summary.md"), "utf8"),
    messages: [{ role: "user", content: [{ type: "text", text: userMessage(testCase) }] }],
    tools: [JSON.parse(readFileSync(join(promptsDir, "weekly_summary_tool.json"), "utf8"))],
    tool_choice: { type: "auto" },
    stream: false,
  };
}

export function extractSummary(response) {
  return (response.content ?? []).find((b) => b.type === "tool_use" && b.name === TOOL_NAME)?.input ?? null;
}

export function checkSummary(summary, expect = {}) {
  if (!summary?.grown?.trim() || !summary?.next_focus?.trim()) return { pass: false, failures: ["まとめが空"], warnings: [] };
  return checkReply(`${summary.grown}\n${summary.next_focus}`, expect);
}

async function main(argv, env) {
  const cases = loadCases();
  if (argv.includes("--dry-run")) {
    for (const c of cases) console.log(JSON.stringify({ id: c.id, request: buildRequest(c) }, null, 2));
    return 0;
  }
  const endpoint = resolveEndpoint(env);
  if (!endpoint) {
    console.log("評価をスキップしました: API の設定がありません（WORKER_BASE_URL と FAMILY_TOKEN、または ANTHROPIC_API_KEY）");
    return 0;
  }
  console.log(`${endpoint.name} で ${cases.length} 件を評価します（${MODEL}）\n`);
  let failed = 0;
  for (const c of cases) {
    const res = await fetch(endpoint.url, { method: "POST", headers: endpoint.headers, body: JSON.stringify(buildRequest(c)) });
    const body = await res.text();
    if (!res.ok) {
      failed++;
      console.log(`ERROR ${c.id}: HTTP ${res.status} ${body}`);
      continue;
    }
    const summary = extractSummary(JSON.parse(body));
    const result = checkSummary(summary, c.expect);
    if (!result.pass) failed++;
    console.log(`${result.pass ? "PASS" : "FAIL"} ${c.id}（${c.title}）`);
    console.log(`  伸びたこと: ${summary?.grown ?? "(なし)"}`);
    console.log(`  見どころ: ${summary?.next_focus ?? "(なし)"}`);
    for (const f of result.failures) console.log(`  - ${f}`);
  }
  console.log(`\n${cases.length - failed}/${cases.length} 件 OK`);
  return failed === 0 ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2), process.env);
}
