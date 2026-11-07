import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ensureWeeklySummary, hasEnoughRecords, lastCompletedWeek, listWeeklySummaries, loadWeekRecord, weeklyRequest, weeklyUserMessage } from "../src/dashboard/weekly";
import type { Env } from "../src/index";
import { useD1 } from "./helpers/d1";

const d1 = useD1();
const NOW = Date.parse("2026-11-10T03:00:00Z"); // JST 11/10（火）12:00。終わった週の月曜は 11/2
const CHILD = "default";

function env(): Env {
  return { ANTHROPIC_API_KEY: "key", ELEVENLABS_API_KEY: "x", TYPESAFE_API_KEY: "x", FAMILY_TOKEN: "x", ELEVENLABS_VOICE_ID: "x", DB: d1.db() };
}

async function seedWeek(sessions = 2, problemsPerSession = 2) {
  const db = d1.db();
  for (let i = 0; i < sessions; i++) {
    const id = `s${i}`;
    const at = `2026-11-0${3 + i}T07:00:00.000Z`;
    await db
      .prepare("INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, summary, teacher_note, flags, updated_at) VALUES (?, 'default', ?, ?, 25, ?, 'よくできました', ?, ?)")
      .bind(id, at, at, `要約${i}`, JSON.stringify(["友だちとけんかした"]), at)
      .run();
    for (let j = 0; j < problemsPerSession; j++) {
      await db
        .prepare("INSERT INTO problems (id, session_id, kind, summary, solved_by_self, hint_level_reached, created_at) VALUES (?, ?, 'thinking', ?, ?, 1, ?)")
        .bind(`${id}-p${j}`, id, `問題${i}-${j}`, j % 2, at)
        .run();
    }
  }
}

function claudeOk(grown = "割合の文章題で、もとにする量を自分で見つけました。", next = "線分図の使い方に注目してみてください。") {
  return Response.json({ stop_reason: "tool_use", content: [{ type: "tool_use", name: "record_weekly_summary", input: { grown, next_focus: next } }] });
}

let fetchMock: ReturnType<typeof vi.fn>;
beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

// waitUntil に渡された処理を最後まで待つ
async function run(now = NOW) {
  const tasks: Promise<unknown>[] = [];
  const generating = await ensureWeeklySummary(env(), CHILD, now, (t) => tasks.push(t));
  await Promise.all(tasks);
  return generating;
}
const row = () => d1.db().prepare("SELECT * FROM weekly_summaries").first<any>();

describe("週の区切りと、作らない週", () => {
  it("最後に終わった週は JST の月曜始まりで決まる", () => {
    expect(lastCompletedWeek(Date.parse("2026-11-08T14:59:59Z"))).toBe("2026-10-26"); // JST 11/8（日）23:59
    expect(lastCompletedWeek(Date.parse("2026-11-08T15:00:00Z"))).toBe("2026-11-02"); // JST 11/9（月）0:00
  });

  it("JST の週の範囲にあるセッションだけを読む", async () => {
    await seedWeek();
    const db = d1.db();
    await db
      .prepare("INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, updated_at) VALUES ('after', 'default', '2026-11-08T15:00:00.000Z', '2026-11-08T15:00:00.000Z', 1, '2026-11-08T15:00:00.000Z'), ('edge', 'default', '2026-11-08T14:59:00.000Z', '2026-11-08T14:59:00.000Z', 1, '2026-11-08T14:59:00.000Z')")
      .run();
    const record = await loadWeekRecord(db, CHILD, "2026-11-02");
    expect(record.sessions.map((s) => s.id)).toEqual(["s0", "s1", "edge"]);
  });

  it("勉強が 1 回だけ、または問題が少ない週は作らず、Claude を呼ばない", async () => {
    await seedWeek(1, 5);
    expect(await run()).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(await row()).toBeNull();
    expect(hasEnoughRecords({ weekStart: "x", sessions: [{}, {}] as any, problems: [{}, {}] as any })).toBe(false);
  });
});

describe("入力", () => {
  it("日付は JST で渡す（朝の勉強が前の日にならない）", async () => {
    const at = "2026-11-03T22:30:00.000Z"; // JST 11/4（水）7:30
    await d1.db()
      .prepare("INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, updated_at) VALUES ('morning', 'default', ?, ?, 10, ?)")
      .bind(at, at, at)
      .run();
    const text = weeklyUserMessage(await loadWeekRecord(d1.db(), CHILD, "2026-11-02"));
    expect(text).toContain("## 2026-11-04 の勉強");
    expect(text).not.toContain("2026-11-03 の勉強");
  });

  it("要約、ひとこと、問題を渡し、要確認は渡さない。写真や音声の項目もない", async () => {
    await seedWeek();
    const record = await loadWeekRecord(d1.db(), CHILD, "2026-11-02");
    const text = weeklyUserMessage(record);
    expect(text).toContain("要約0");
    expect(text).toContain("よくできました");
    expect(text).toContain("問題 [thinking] 問題0-1：自力で解けた（ヒント1段階目まで）");
    expect(text).toContain("取り組んだ問題：4問・自力で解けたのは2問");
    expect(text).not.toContain("けんか");
    const body = JSON.stringify(weeklyRequest(record));
    expect(body).not.toMatch(/image|audio|base64/);
    expect(weeklyRequest(record).model).toBe("claude-sonnet-5-5");
    expect(weeklyRequest(record).tools[0].strict).toBe(true);
    expect(weeklyRequest(record).system).toContain("正答の数字や言葉");
  });
});

describe("作って保存する", () => {
  it("Claude の結果を保存し、一覧で返す", async () => {
    await seedWeek();
    fetchMock.mockResolvedValueOnce(claudeOk());
    expect(await run()).toBe(true);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    expect(init.headers["x-api-key"]).toBe("key");
    expect(await row()).toMatchObject({ status: "ready", week_start: "2026-11-02", attempts: 1 });
    expect(await listWeeklySummaries(d1.db(), CHILD)).toEqual([
      { week_start: "2026-11-02", grown: "割合の文章題で、もとにする量を自分で見つけました。", next_focus: "線分図の使い方に注目してみてください。" },
    ]);
  });

  it("同じ週は再度 Claude を呼ばない", async () => {
    await seedWeek();
    fetchMock.mockResolvedValue(claudeOk());
    await run();
    await run();
    await run(NOW + 24 * 3_600_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("同時に開いても 1 回しか呼ばない", async () => {
    await seedWeek();
    fetchMock.mockImplementation(async () => claudeOk());
    await Promise.all([run(), run(), run()]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("作っている間に開いても呼ばない", async () => {
    await seedWeek();
    let finish!: (r: Response) => void;
    fetchMock.mockReturnValueOnce(new Promise((r) => (finish = r)));
    const tasks: Promise<unknown>[] = [];
    await ensureWeeklySummary(env(), CHILD, NOW, (t) => tasks.push(t));
    expect(await run(NOW + 60_000)).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    finish(claudeOk());
    await Promise.all(tasks);
    expect((await row()).status).toBe("ready");
  });
});

describe("失敗", () => {
  it.each([
    ["HTTP エラー", () => Promise.resolve(new Response("{}", { status: 500 }))],
    ["通信エラー", () => Promise.reject(new Error("network"))],
    ["ツールを呼ばなかった", () => Promise.resolve(Response.json({ stop_reason: "end_turn", content: [{ type: "text", text: "x" }] }))],
    ["途中で切れた", () => Promise.resolve(Response.json({ stop_reason: "max_tokens", content: [{ type: "tool_use", name: "record_weekly_summary", input: { grown: "a", next_focus: "b" } }] }))],
    ["中身が空", () => Promise.resolve(Response.json({ stop_reason: "tool_use", content: [{ type: "tool_use", name: "record_weekly_summary", input: { grown: " ", next_focus: "" } }] }))],
  ])("%s なら failed にして、すぐには呼び直さない", async (_, reply) => {
    await seedWeek();
    fetchMock.mockImplementation(reply);
    await run();
    expect((await row()).status).toBe("failed");
    expect(await listWeeklySummaries(d1.db(), CHILD)).toEqual([]);
    await run(NOW + 60_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("6 時間あけたらやり直し、合計 3 回で止める", async () => {
    await seedWeek();
    fetchMock.mockImplementation(async () => new Response("{}", { status: 500 }));
    const hours = (h: number) => NOW + h * 3_600_000;
    await run(hours(0));
    await run(hours(7));
    await run(hours(14));
    await run(hours(21));
    await run(hours(28));
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect((await row()).attempts).toBe(3);
  });

  it("やり直しで作れたら保存する", async () => {
    await seedWeek();
    fetchMock.mockResolvedValueOnce(new Response("{}", { status: 500 })).mockResolvedValueOnce(claudeOk());
    await run(NOW);
    await run(NOW + 7 * 3_600_000);
    expect(await row()).toMatchObject({ status: "ready", attempts: 2 });
  });

  it("途中で切れて pending のまま残っても、10 分たてばやり直せる", async () => {
    await seedWeek();
    await d1.db().prepare("INSERT INTO weekly_summaries (child_id, week_start, status, claimed_at) VALUES ('default', '2026-11-02', 'pending', ?)").bind(new Date(NOW - 11 * 60_000).toISOString()).run();
    fetchMock.mockResolvedValueOnce(claudeOk());
    await run();
    expect(await row()).toMatchObject({ status: "ready", attempts: 2 });
  });

  it("DB が読めなくても例外を投げない", async () => {
    const broken = { ...env(), DB: { prepare: () => { throw new Error("db"); } } as unknown as D1Database };
    await expect(ensureWeeklySummary(broken, CHILD, NOW, () => {})).resolves.toBe(false);
  });
});
