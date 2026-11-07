// 本物の Claude に当てて、Worker の週のまとめの処理を最後まで通す。ふだんはスキップする。
// WEEKLY_LIVE=1 WORKER_BASE_URL=... FAMILY_TOKEN=... npx vitest run test/weekly.live.test.ts
// Anthropic への呼び出しを本番の /v1/claude に振り替える（ローカルに API キーを置かない）。保存先はローカルの D1。
import { afterEach, describe, expect, it, vi } from "vitest";
import { ensureWeeklySummary, listWeeklySummaries } from "../src/dashboard/weekly";
import type { Env } from "../src/index";
import { useD1 } from "./helpers/d1";

const d1 = useD1();
const live = process.env.WEEKLY_LIVE === "1";

afterEach(() => vi.unstubAllGlobals());

describe.skipIf(!live)("週のまとめ（本物の Claude）", () => {
  it("作って保存する", async () => {
    const db = d1.db();
    const rows = [
      ["s1", "2026-11-03T07:00:00.000Z", "割合の文章題。定価1200円の25%引きを線分図で考え、900円と答えた。", "もとにする量を自分で見つけられました！"],
      ["s2", "2026-11-05T07:00:00.000Z", "棒グラフの読み取り。目盛りを確かめてから答えた。", ""],
    ];
    for (const [id, at, summary, note] of rows) {
      await db
        .prepare("INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, summary, teacher_note, flags, updated_at) VALUES (?, 'default', ?, ?, 25, ?, ?, '[\"友だちとけんかした\"]', ?)")
        .bind(id, at, at, summary, note, at)
        .run();
      await db.batch(
        [1, 2].map((n) =>
          db
            .prepare("INSERT INTO problems (id, session_id, kind, summary, solved_by_self, hint_level_reached, created_at) VALUES (?, ?, 'thinking', ?, ?, ?, ?)")
            .bind(`${id}-${n}`, id, `${summary.slice(0, 8)}の問題${n}`, n === 1 ? 1 : 0, n, at),
        ),
      );
    }
    const realFetch = globalThis.fetch;
    vi.stubGlobal("fetch", (_url: string, init: RequestInit) =>
      realFetch(new URL("/v1/claude", process.env.WORKER_BASE_URL), {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${process.env.FAMILY_TOKEN}` },
        body: init.body,
      }),
    );
    const tasks: Promise<unknown>[] = [];
    const env = { ANTHROPIC_API_KEY: "relay", DB: db } as Env;
    await ensureWeeklySummary(env, "default", Date.parse("2026-11-10T03:00:00Z"), (t) => tasks.push(t));
    await Promise.all(tasks);
    const summaries = await listWeeklySummaries(db, "default");
    console.log(JSON.stringify(summaries, null, 2));
    expect(summaries).toHaveLength(1);
    expect(`${summaries[0].grown}${summaries[0].next_focus}`).not.toMatch(/900|けんか/);
  }, 60_000);
});
