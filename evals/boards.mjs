#!/usr/bin/env node
// 黒板（Generative UI）の評価（#70）。適性検査風の問題を、アプリと同じ本文・同じツールで分析（Sonnet）に送り、
// 返ってきた show_board / render_svg の入力を evals/fixtures/boards/<phase>/<id>.json に保存する。
// 画像は Swift のテスト（BoardEvalTests）で docs/screenshots/boards-eval/<phase>/ に書き出す。
//
// 本文とツールは Swift から書き出したもの（evals/fixtures/board_tools.json）を使う。写真のかわりに問題の文字を入れる。
//
// 使い方（Node 22 以上、依存なし）:
//   WORKER_BASE_URL=https://xxx.workers.dev FAMILY_TOKEN=... node evals/boards.mjs --phase before
//   node evals/boards.mjs --dry-run --case 01-ratio-sale
//   node evals/boards.mjs --report --phase before    # 保存した結果の集計だけ（API を呼ばない）
// 設定がなければ何もせずに終了する（exit 0）。
import { mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolveEndpoint } from "./run.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const BOARD_TOOLS = ["show_board", "render_svg"];

export function loadCases() {
  return JSON.parse(readFileSync(join(here, "boards", "cases.json"), "utf8"));
}

export function loadTemplate() {
  return JSON.parse(readFileSync(join(here, "fixtures", "board_tools.json"), "utf8")).analyzer_request;
}

// 「黒板も出して」と頼む一文（--ask-board）。アプリが図を出さないとき、部品カタログ自体の質を見るために使う。
export const ASK_BOARD = "あわせて、ヒントの段階1〜2で子どもに見せる黒板の図を show_board（表せなければ render_svg）で1つ出してください。";

// アプリの分析リクエスト（ProblemAnalyzer.makeRequestBody）の画像を、問題の文字に置きかえる。
export function buildAnalyzerRequest(template, testCase, { askBoard = false } = {}) {
  const body = structuredClone(template);
  const content = body.messages[0].content;
  if (askBoard) {
    const last = content.findLast((b) => b.type === "text");
    last.text += `\n${ASK_BOARD}`;
  }
  const imageIndex = content.findIndex((b) => b.type === "image");
  const problem = {
    type: "text",
    text: `（写真のかわりに、写っている問題を文字に起こしたもの）\n${testCase.problem}`,
  };
  if (imageIndex >= 0) content.splice(imageIndex, 1, problem);
  else content.unshift(problem);
  return body;
}

// 黒板に書かれた文字（SVG は <text> の中身）を集める。
export function boardStrings(board) {
  const out = [];
  const walk = (v, key) => {
    if (typeof v === "string") {
      if (key === "type" || key === "image_id") return;
      if (key === "svg") {
        for (const m of v.matchAll(/<text[^>]*>([\s\S]*?)<\/text>/g)) out.push(m[1].replace(/<[^>]+>/g, ""));
        return;
      }
      out.push(v);
    } else if (Array.isArray(v)) v.forEach((x) => walk(x, key));
    else if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) walk(x, k);
  };
  walk(board.input, null);
  return out;
}

const normalize = (s) => s.normalize("NFKC").replace(/\s+/g, "").replace(/[,，]/g, "");

// 黒板に正答が書かれていないか。答えの数（例：900）だけが出ていても漏れとみなす（問題文に同じ数があれば除く）。
// 答えが問題文の中にある（「7月」「B町」のような選択肢）ときは、書いてあるだけでは漏れにしない（目で確かめる）。
export function findLeaks(boards, testCase) {
  if (!testCase.answer) return [];
  const answer = normalize(testCase.answer);
  const digits = answer.match(/\d+(\.\d+)?/g) ?? [];
  const problem = normalize(testCase.problem);
  const isChoice = problem.includes(answer);
  const leaks = [];
  for (const board of boards) {
    for (const s of boardStrings(board).map(normalize)) {
      if (!isChoice && s.includes(answer)) leaks.push(s);
      else if (digits.some((d) => !problem.includes(d) && new RegExp(`(^|[^\\d.])${d.replace(".", "\\.")}($|[^\\d.])`).test(s))) {
        leaks.push(s);
      }
    }
  }
  return leaks;
}

export function summarize(result, testCase) {
  const kinds = result.boards.map((b) => (b.name === "show_board" ? b.input?.component?.type : "svg"));
  return {
    id: testCase.id,
    boards: result.boards.length,
    kinds,
    analyzed: Boolean(result.analysis),
    leaks: findLeaks(result.boards, testCase),
  };
}

// 応答から分析と図を取り出す。
export function extract(response) {
  const blocks = response.content ?? [];
  const tools = blocks.filter((b) => b.type === "tool_use");
  return {
    analysis: tools.find((b) => b.name === "report_analysis")?.input ?? null,
    boards: tools.filter((b) => BOARD_TOOLS.includes(b.name)).map((b) => ({ name: b.name, input: b.input })),
    text: blocks.filter((b) => b.type === "text").map((b) => b.text).join(""),
    stop_reason: response.stop_reason,
    usage: response.usage,
  };
}

async function callClaude(endpoint, body) {
  const res = await fetch(endpoint.url, { method: "POST", headers: endpoint.headers, body: JSON.stringify(body) });
  const text = await res.text();
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 500)}`);
  return JSON.parse(text);
}

function arg(argv, name, fallback = null) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
}

function printSummary(rows) {
  for (const r of rows) {
    const leak = r.leaks.length ? `  答えが漏れた: ${r.leaks.join(" / ")}` : "";
    console.log(`${r.id}: 図 ${r.boards} 枚 [${r.kinds.join(", ") || "なし"}]${r.analyzed ? "" : "  分析なし"}${leak}`);
  }
  const withBoard = rows.filter((r) => r.boards > 0).length;
  const leaked = rows.filter((r) => r.leaks.length > 0).length;
  console.log(`\n図あり ${withBoard}/${rows.length}、答えの漏れ ${leaked}/${rows.length}`);
}

async function main(argv, env) {
  const phase = arg(argv, "--phase", "before");
  const only = arg(argv, "--case");
  const cases = loadCases().filter((c) => !only || c.id === only);
  const outDir = join(here, "fixtures", "boards", phase);

  if (argv.includes("--report")) {
    if (!existsSync(outDir)) return console.error(`結果がありません: ${outDir}`), 1;
    const saved = readdirSync(outDir).filter((f) => f.endsWith(".json")).map((f) => JSON.parse(readFileSync(join(outDir, f), "utf8")));
    printSummary(saved.map((s) => summarize(s, cases.find((c) => c.id === s.id) ?? { answer: "", problem: "" })));
    return 0;
  }

  const template = loadTemplate();
  if (argv.includes("--dry-run")) {
    for (const c of cases) {
      const body = buildAnalyzerRequest(template, c);
      console.log(JSON.stringify({ id: c.id, model: body.model, tools: body.tools.map((t) => t.name), messages: body.messages }, null, 2));
    }
    return 0;
  }

  const endpoint = resolveEndpoint(env);
  if (!endpoint) {
    console.log("評価をスキップしました: WORKER_BASE_URL と FAMILY_TOKEN（または ANTHROPIC_API_KEY）を設定してください。");
    return 0;
  }

  mkdirSync(outDir, { recursive: true });
  console.log(`${endpoint.name} で ${cases.length} 問の図を作ります（phase: ${phase}）\n`);
  const rows = [];
  const askBoard = argv.includes("--ask-board");
  for (const c of cases) {
    const body = buildAnalyzerRequest(template, c, { askBoard });
    try {
      // アプリ（ProblemAnalyzer.analyze）と同じく、report_analysis が無ければ1回だけやり直す
      let result = extract(await callClaude(endpoint, body));
      if (!result.analysis) result = extract(await callClaude(endpoint, body));
      const saved = { id: c.id, title: c.title, model: body.model, ask_board: askBoard, ...result };
      writeFileSync(join(outDir, `${c.id}.json`), JSON.stringify(saved, null, 2) + "\n");
      rows.push(summarize(result, c));
    } catch (error) {
      console.log(`ERROR ${c.id}: ${error.message}`);
      rows.push({ id: c.id, boards: 0, kinds: [], analyzed: false, leaks: [`ERROR ${error.message}`] });
    }
  }
  printSummary(rows);
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await main(process.argv.slice(2), process.env);
}
