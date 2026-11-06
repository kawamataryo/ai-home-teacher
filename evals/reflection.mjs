#!/usr/bin/env node
// ふり返り（record_reflection）の評価。今夜の声かけ（parent_prompt、#158）が「守ること」を守っているかを見る。
// ツールとモデルは Swift から書き出したもの（evals/fixtures/reflection_tool.json）を使い、アプリと揃える。
//
// 使い方（Node 22 以上、依存なし）:
//   WORKER_BASE_URL=https://xxx.workers.dev FAMILY_TOKEN=... node evals/reflection.mjs
//   node evals/reflection.mjs --dry-run --case prompt-keeps-secret
// 設定がなければ何もせずに終了する（exit 0）。判定のテスト: node --test evals/*.test.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checkReply } from "./checker.mjs";
import { SEPARATOR, loadPrompt } from "./prompt.mjs";
import { resolveEndpoint } from "./run.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const TOOL_NAME = "record_reflection";

export function loadCases() {
  return JSON.parse(readFileSync(join(here, "reflection", "cases.json"), "utf8"));
}

export function loadTemplate() {
  return JSON.parse(readFileSync(join(here, "fixtures", "reflection_tool.json"), "utf8"));
}

// アプリの SessionReflector.userMessage と同じ形。正答（answer）は Claude に渡さない
export function userMessage(testCase) {
  const solved = testCase.problems.filter((p) => p.result.startsWith("自力で解けた")).length;
  const lines = [
    "# 今日のセッション",
    "",
    "- 日時：11月6日（金）16:00〜16:40",
    "- 集中した時間：25分",
    "",
    `# 取り組んだ問題（${testCase.problems.length}問・自力で解けたのは${solved}問）`,
    "",
    ...(testCase.problems.length === 0 ? ["（なし）"] : testCase.problems.map((p, i) => `${i + 1}. [${p.kind}] ${p.summary}：${p.result}`)),
    "",
    "# いま覚えていること",
    "",
    "（まだない）",
    "",
    "# 会話",
    "",
    ...(testCase.transcript.length === 0 ? ["（会話なし）"] : testCase.transcript),
    "",
    `必ず ${TOOL_NAME} ツールを呼んで、ふり返りを記録してください（文章だけで答えないこと）。`,
  ];
  return lines.join("\n");
}

export function buildRequest(template, testCase) {
  return {
    model: template.model,
    max_tokens: template.max_tokens,
    system: [loadPrompt("teacher"), loadPrompt("reflection")].join(SEPARATOR),
    messages: [{ role: "user", content: [{ type: "text", text: userMessage(testCase) }] }],
    tools: template.tools,
    tool_choice: template.tool_choice,
    stream: false,
  };
}

export function extractReflection(response) {
  return (response.content ?? []).find((b) => b.type === "tool_use" && b.name === TOOL_NAME)?.input ?? null;
}

// 親に見せる文を検査する。empty: 勉強の記録がないなら空のまま
export function checkParentPrompt(parentPrompt, expect = {}) {
  const text = (parentPrompt ?? "").trim();
  if (expect.empty) {
    return { pass: text === "", failures: text === "" ? [] : [`空のはずが作っている: ${text}`], warnings: [] };
  }
  if (!text) return { pass: false, failures: ["声かけが空"], warnings: [] };
  return checkReply(text, expect);
}

async function main(argv, env) {
  const dryRun = argv.includes("--dry-run");
  const only = argv.includes("--case") ? new Set(argv[argv.indexOf("--case") + 1].split(",")) : null;
  const template = loadTemplate();
  const cases = loadCases().filter((c) => !only || only.has(c.id));
  if (dryRun) {
    for (const c of cases) console.log(JSON.stringify({ id: c.id, request: buildRequest(template, c) }, null, 2));
    return 0;
  }
  const endpoint = resolveEndpoint(env);
  if (!endpoint) {
    console.log("評価をスキップしました: API の設定がありません（WORKER_BASE_URL と FAMILY_TOKEN、または ANTHROPIC_API_KEY）");
    return 0;
  }
  console.log(`${endpoint.name} で ${cases.length} 件を評価します（${template.model}）\n`);
  let failed = 0;
  for (const c of cases) {
    const res = await fetch(endpoint.url, { method: "POST", headers: endpoint.headers, body: JSON.stringify(buildRequest(template, c)) });
    const body = await res.text();
    if (!res.ok) {
      failed++;
      console.log(`ERROR ${c.id}: HTTP ${res.status} ${body}`);
      continue;
    }
    const reflection = extractReflection(JSON.parse(body));
    const result = reflection
      ? checkParentPrompt(reflection.parent_prompt, c.expect)
      : { pass: false, failures: [`${TOOL_NAME} が呼ばれていない`], warnings: [] };
    if (!result.pass) failed++;
    console.log(`${result.pass ? "PASS" : "FAIL"} ${c.id}（${c.title}）`);
    console.log(`  声かけ: ${reflection?.parent_prompt ?? "(なし)"}`);
    for (const f of result.failures) console.log(`  - ${f}`);
    for (const w of result.warnings) console.log(`  (注意) ${w}`);
  }
  console.log(`\n${cases.length - failed}/${cases.length} 件 OK`);
  return failed === 0 ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2), process.env);
}
