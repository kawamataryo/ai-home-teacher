// 週のまとめ（#162）。その週で最初にダッシュボードを開いたときに、終わった週の分を Sonnet で 1 回だけ作る。
// 親を待たせないよう waitUntil で裏で作り、画面はふだんどおり返す。Claude が失敗しても画面には響かない。
// 入力は保存済みの文字の情報だけ（要約、先生のひとこと、問題）。要確認（flags）は渡さず、別の枠のままにする。

import prompt from "../../prompts/weekly_summary.md";
import tool from "../../prompts/weekly_summary_tool.json";
import type { Env } from "../env";
import { ANTHROPIC_URL, ANTHROPIC_VERSION } from "../upstream";
import { jstWeekStart } from "./growth";

export const WEEKLY_MODEL = "claude-sonnet-5-5";
const MAX_TOKENS = 1000;
// 記録が少ない週は作らない。1 回の勉強の要約と変わらないものを週のまとめと呼ばない
export const MIN_SESSIONS = 2;
export const MIN_PROBLEMS = 3;
// 失敗したときも開くたびには呼ばない。間をあけて、1 週につき合計 3 回まで
export const MAX_ATTEMPTS = 3;
export const RETRY_AFTER_MS = 6 * 60 * 60 * 1000;
// waitUntil が途中で切れて pending のまま残ったときは、失敗と同じ扱いにする
const PENDING_STALE_MS = 10 * 60 * 1000;
const CLAUDE_TIMEOUT_MS = 25_000;
const SUMMARY_LIST = 8;

const DAY_MS = 86_400_000;
const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

export type WeeklySummary = { week_start: string; grown: string; next_focus: string };
export type WeeklyState = { summaries: WeeklySummary[]; generating: boolean };

// 最後に終わった週の月曜（JST）
export function lastCompletedWeek(now: number): string {
  return new Date(Date.parse(`${jstWeekStart(now)}T00:00:00Z`) - 7 * DAY_MS).toISOString().slice(0, 10);
}

function weekRangeUtc(weekStart: string): { from: string; to: string } {
  const start = Date.parse(`${weekStart}T00:00:00Z`) - JST_OFFSET_MS;
  return { from: new Date(start).toISOString(), to: new Date(start + 7 * DAY_MS).toISOString() };
}

type WeekSession = {
  id: string;
  started_at: string;
  focus_minutes: number;
  summary: string;
  teacher_note: string;
};
type WeekProblem = { session_id: string; kind: string; summary: string; solved_by_self: number; hint_level_reached: number };
export type WeekRecord = { weekStart: string; sessions: WeekSession[]; problems: WeekProblem[] };

export async function loadWeekRecord(db: D1Database, childId: string, weekStart: string): Promise<WeekRecord> {
  const { from, to } = weekRangeUtc(weekStart);
  const [sessions, problems] = await Promise.all([
    db
      .prepare(
        `SELECT id, started_at, focus_minutes, summary, teacher_note FROM sessions
         WHERE child_id = ? AND started_at >= ? AND started_at < ? ORDER BY started_at`,
      )
      .bind(childId, from, to)
      .all<WeekSession>(),
    db
      .prepare(
        `SELECT p.session_id, p.kind, p.summary, p.solved_by_self, p.hint_level_reached
         FROM problems p JOIN sessions s ON s.id = p.session_id
         WHERE s.child_id = ? AND s.started_at >= ? AND s.started_at < ? ORDER BY s.started_at, p.created_at, p.rowid`,
      )
      .bind(childId, from, to)
      .all<WeekProblem>(),
  ]);
  return { weekStart, sessions: sessions.results, problems: problems.results };
}

export function hasEnoughRecords(record: WeekRecord): boolean {
  return record.sessions.length >= MIN_SESSIONS && record.problems.length >= MIN_PROBLEMS;
}

// 親向けの文に違う日付が入らないよう、JST の日付で渡す（started_at は UTC）
function jstDate(iso: string): string {
  return new Date(Date.parse(iso) + JST_OFFSET_MS).toISOString().slice(0, 10);
}

function problemResult(p: WeekProblem): string {
  const hint = p.hint_level_reached === 0 ? "ヒントなし" : `ヒント${p.hint_level_reached}段階目まで`;
  return p.solved_by_self ? `自力で解けた（${hint}）` : `まだ解けていない・一緒に解いた（${hint}）`;
}

// Claude に渡す 1 週間の記録。evals/weekly.mjs の userMessage と揃える
export function weeklyUserMessage(record: WeekRecord): string {
  const solved = record.problems.filter((p) => p.solved_by_self).length;
  const minutes = record.sessions.reduce((n, s) => n + s.focus_minutes, 0);
  const lines = [
    `# ${record.weekStart} からの1週間の記録`,
    "",
    `- 勉強した回数：${record.sessions.length}回`,
    `- 集中した時間：合計${minutes}分`,
    `- 取り組んだ問題：${record.problems.length}問・自力で解けたのは${solved}問`,
  ];
  for (const s of record.sessions) {
    lines.push("", `## ${jstDate(s.started_at)} の勉強`, `- 要約：${s.summary || "（なし）"}`);
    if (s.teacher_note) lines.push(`- 先生のひとこと：${s.teacher_note}`);
    for (const p of record.problems.filter((x) => x.session_id === s.id)) {
      lines.push(`- 問題 [${p.kind}] ${p.summary}：${problemResult(p)}`);
    }
  }
  lines.push("", "必ず record_weekly_summary ツールを呼んで記録してください（文章だけで答えないこと）。");
  return lines.join("\n");
}

export function weeklyRequest(record: WeekRecord) {
  return {
    model: WEEKLY_MODEL,
    max_tokens: MAX_TOKENS,
    system: prompt,
    messages: [{ role: "user", content: [{ type: "text", text: weeklyUserMessage(record) }] }],
    tools: [tool],
    tool_choice: { type: "auto" },
    stream: false,
  };
}

async function callClaude(apiKey: string, record: WeekRecord): Promise<{ grown: string; next_focus: string }> {
  const res = await fetch(ANTHROPIC_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": ANTHROPIC_VERSION },
    body: JSON.stringify(weeklyRequest(record)),
    signal: AbortSignal.timeout(CLAUDE_TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`Claude HTTP ${res.status}`);
  const body = (await res.json()) as { stop_reason?: string; content?: Array<{ type: string; name?: string; input?: any }> };
  const input = body.content?.find((b) => b.type === "tool_use" && b.name === tool.name)?.input;
  const grown = typeof input?.grown === "string" ? input.grown.trim() : "";
  const nextFocus = typeof input?.next_focus === "string" ? input.next_focus.trim() : "";
  if (body.stop_reason === "max_tokens" || !grown || !nextFocus) throw new Error("週のまとめの形が違う");
  return { grown, next_focus: nextFocus };
}

// 呼ぶ権利を取る。行を作れた、または間をあけた失敗を更新できたときだけ true。
// 同時に開いても、どちらか一方だけが true になる
async function claim(db: D1Database, childId: string, weekStart: string, now: number): Promise<boolean> {
  const at = new Date(now).toISOString();
  const created = await db
    .prepare(
      `INSERT INTO weekly_summaries (child_id, week_start, status, attempts, claimed_at) VALUES (?, ?, 'pending', 1, ?)
       ON CONFLICT(child_id, week_start) DO NOTHING`,
    )
    .bind(childId, weekStart, at)
    .run();
  if (created.meta.changes > 0) return true;
  const retried = await db
    .prepare(
      `UPDATE weekly_summaries SET status = 'pending', attempts = attempts + 1, claimed_at = ?
       WHERE child_id = ? AND week_start = ? AND attempts < ?
         AND ((status = 'failed' AND claimed_at <= ?) OR (status = 'pending' AND claimed_at <= ?))`,
    )
    .bind(
      at,
      childId,
      weekStart,
      MAX_ATTEMPTS,
      new Date(now - RETRY_AFTER_MS).toISOString(),
      new Date(now - PENDING_STALE_MS).toISOString(),
    )
    .run();
  return retried.meta.changes > 0;
}

async function generate(env: Env, childId: string, record: WeekRecord): Promise<void> {
  const db = env.DB;
  try {
    const { grown, next_focus } = await callClaude(env.ANTHROPIC_API_KEY, record);
    await db
      .prepare(`UPDATE weekly_summaries SET status = 'ready', grown = ?, next_focus = ? WHERE child_id = ? AND week_start = ?`)
      .bind(grown, next_focus, childId, record.weekStart)
      .run();
  } catch (error) {
    // 記録にある週の文は残さず、理由だけログに出す
    console.error("週のまとめを作れなかった", record.weekStart, error instanceof Error ? error.message : "unknown");
    await db
      .prepare(`UPDATE weekly_summaries SET status = 'failed' WHERE child_id = ? AND week_start = ?`)
      .bind(childId, record.weekStart)
      .run();
  }
}

// 必要なら裏で作り始める。ここでは例外を投げない（ダッシュボードを開くのを邪魔しない）
export async function ensureWeeklySummary(
  env: Env,
  childId: string,
  now: number,
  waitUntil: (task: Promise<unknown>) => void,
): Promise<boolean> {
  try {
    const weekStart = lastCompletedWeek(now);
    const existing = await env.DB
      .prepare("SELECT status FROM weekly_summaries WHERE child_id = ? AND week_start = ?")
      .bind(childId, weekStart)
      .first<{ status: string }>();
    if (existing?.status === "ready") return false;
    const record = await loadWeekRecord(env.DB, childId, weekStart);
    if (!hasEnoughRecords(record)) return false;
    if (!(await claim(env.DB, childId, weekStart, now))) return existing?.status === "pending";
    waitUntil(generate(env, childId, record));
    return true;
  } catch (error) {
    console.error("週のまとめの確認に失敗した", error instanceof Error ? error.message : "unknown");
    return false;
  }
}

export async function listWeeklySummaries(db: D1Database, childId: string): Promise<WeeklySummary[]> {
  const { results } = await db
    .prepare(
      `SELECT week_start, grown, next_focus FROM weekly_summaries
       WHERE child_id = ? AND status = 'ready' ORDER BY week_start DESC LIMIT ?`,
    )
    .bind(childId, SUMMARY_LIST)
    .all<WeeklySummary>();
  return results;
}
