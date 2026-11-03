import { beforeEach, describe, expect, it } from "vitest";
import app, { type Env } from "../src/index";
import { useD1 } from "./helpers/d1";

const d1 = useD1();
const AUTH = { Authorization: "Bearer family-secret" };

function env(): Env {
  return {
    ANTHROPIC_API_KEY: "x",
    ELEVENLABS_API_KEY: "x",
    TYPESAFE_API_KEY: "x",
    FAMILY_TOKEN: "family-secret",
    ELEVENLABS_VOICE_ID: "x",
    DB: d1.db(),
  };
}

function send(method: string, path: string, body?: unknown, headers: Record<string, string> = AUTH) {
  return app.request(
    path,
    {
      method,
      headers: { "content-type": "application/json", ...headers },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    },
    env(),
  );
}

const session = {
  id: "11111111-1111-4111-8111-111111111111",
  started_at: "2026-11-03T16:00:00+09:00",
  ended_at: "2026-11-03T16:40:00+09:00",
  focus_minutes: 35,
  summary: "割合の文章題を 3 問やった",
  teacher_note: "今日は割合の問題を自力で解けました！",
  flags: ["学校で友だちとけんかしたと話していた"],
  problems: [
    { kind: "thinking", summary: "割合：もとにする量を求める", solved_by_self: true, hint_level_reached: 1 },
    { kind: "reading", summary: "グラフから増えた割合を読む", solved_by_self: false, hint_level_reached: 3 },
  ],
};

// 別の家族のデータ（FAMILY_TOKEN では見えてはいけない）
async function seedOtherFamily() {
  const db = d1.db();
  await db.batch([
    db.prepare("INSERT INTO families (id, name) VALUES ('other', 'よその家')"),
    db.prepare("INSERT INTO children (id, family_id, nickname, grade) VALUES ('other-child', 'other', 'よそ', 5)"),
    db.prepare(
      `INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, summary, teacher_note, flags, updated_at)
       VALUES ('other-session', 'other-child', '2026-11-01T00:00:00.000Z', '2026-11-01T00:30:00.000Z', 30, 'よその要約', '', '[]', '2026-11-01T00:30:00.000Z')`,
    ),
    db.prepare(
      `INSERT INTO memories (id, child_id, category, content, updated_at)
       VALUES ('m-other', 'other-child', 'likes', 'よその好きなこと', '2026-11-01T00:00:00.000Z')`,
    ),
  ]);
}

describe("スキーマ", () => {
  it("画像・音声のカラムがどのテーブルにもない", async () => {
    const db = d1.db();
    const { results: tables } = await db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'")
      .all<{ name: string }>();
    const names = tables.map((t) => t.name).sort();
    expect(names).toEqual(expect.arrayContaining(["children", "families", "memories", "parents", "problems", "sessions"]));
    for (const t of names) {
      const { results: cols } = await db.prepare(`PRAGMA table_info(${t})`).all<{ name: string; type: string }>();
      for (const col of cols) {
        expect(col.name).not.toMatch(/image|photo|picture|audio|voice|sound|blob|base64/i);
        expect(col.type.toUpperCase()).not.toBe("BLOB");
      }
    }
  });
});

describe("認証", () => {
  it("トークンなしは 401", async () => {
    expect((await send("GET", "/v1/sessions", undefined, {})).status).toBe(401);
    expect((await send("PUT", "/v1/memory", { category: "likes", items: [] }, {})).status).toBe(401);
  });
});

describe("POST /v1/sessions", () => {
  it("セッションと問題を保存して、保存した形で返す", async () => {
    const res = await send("POST", "/v1/sessions", session);
    expect(res.status).toBe(200);
    const { session: saved } = (await res.json()) as any;
    expect(saved).toMatchObject({
      id: session.id,
      child_id: "default",
      started_at: "2026-11-03T07:00:00.000Z", // UTC に正規化
      ended_at: "2026-11-03T07:40:00.000Z",
      focus_minutes: 35,
      summary: session.summary,
      teacher_note: session.teacher_note,
      flags: session.flags,
    });
    expect(saved.updated_at).toMatch(/Z$/);
    expect(saved.problems).toHaveLength(2);
    expect(saved.problems[0]).toMatchObject({
      kind: "thinking",
      solved_by_self: true,
      hint_level_reached: 1,
      created_at: "2026-11-03T07:00:00.000Z",
    });
    expect(saved.problems[1]).toMatchObject({ kind: "reading", solved_by_self: false, hint_level_reached: 3 });
  });

  it("同じ id で送り直すと上書きになり、問題は重複しない", async () => {
    await send("POST", "/v1/sessions", session);
    const res = await send("POST", "/v1/sessions", {
      ...session,
      summary: "書き直した要約",
      flags: [],
      problems: [session.problems[0]],
    });
    expect(res.status).toBe(200);
    const list = (await (await send("GET", "/v1/sessions")).json()) as any;
    expect(list.sessions).toHaveLength(1);
    expect(list.sessions[0].summary).toBe("書き直した要約");
    expect(list.sessions[0].flags).toEqual([]);
    expect(list.sessions[0].problems).toHaveLength(1);
    const { count } = (await d1.db().prepare("SELECT count(*) AS count FROM problems").first<{ count: number }>())!;
    expect(count).toBe(1);
  });

  it.each([
    ["必須項目がない", { id: "a" }],
    ["id に使えない文字", { ...session, id: "../x" }],
    ["ended_at が started_at より前", { ...session, ended_at: "2026-11-03T15:00:00+09:00" }],
    ["日時の形式が違う", { ...session, started_at: "昨日" }],
    ["問題の種類が違う", { ...session, problems: [{ ...session.problems[0], kind: "drawing" }] }],
    ["ヒントの段階が 4 を超える", { ...session, problems: [{ ...session.problems[0], hint_level_reached: 5 }] }],
    ["画像のフィールドは受け取らない", { ...session, image_base64: "AAAA" }],
    ["問題に音声のフィールドは受け取らない", { ...session, problems: [{ ...session.problems[0], audio_url: "x" }] }],
  ])("%s は 400", async (_, body) => {
    const res = await send("POST", "/v1/sessions", body);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error).toBe("invalid request");
    const { count } = (await d1.db().prepare("SELECT count(*) AS count FROM sessions").first<{ count: number }>())!;
    expect(count).toBe(0);
  });

  it("壊れた JSON は 400", async () => {
    const res = await send("POST", "/v1/sessions", "{oops");
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid json" });
  });

  it("別の家族のセッション id は上書きできない", async () => {
    await seedOtherFamily();
    const res = await send("POST", "/v1/sessions", { ...session, id: "other-session" });
    expect(res.status).toBe(404);
    const row = await d1.db().prepare("SELECT summary FROM sessions WHERE id = 'other-session'").first<{ summary: string }>();
    expect(row?.summary).toBe("よその要約");
  });

  it("別の家族の child_id は指定できない", async () => {
    await seedOtherFamily();
    const res = await send("POST", "/v1/sessions", { ...session, child_id: "other-child" });
    expect(res.status).toBe(404);
  });
});

describe("GET /v1/sessions", () => {
  beforeEach(async () => {
    await send("POST", "/v1/sessions", session);
    await send("POST", "/v1/sessions", {
      ...session,
      id: "22222222-2222-4222-8222-222222222222",
      started_at: "2026-11-04T16:00:00+09:00",
      ended_at: "2026-11-04T16:20:00+09:00",
      problems: [],
    });
  });

  it("自分の家族のセッションだけを新しい順に返す", async () => {
    await seedOtherFamily();
    const res = await send("GET", "/v1/sessions");
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.sessions.map((s: any) => s.id)).toEqual([
      "22222222-2222-4222-8222-222222222222",
      session.id,
    ]);
    expect(body.sessions[1].problems).toHaveLength(2);
    expect(body.server_time).toMatch(/Z$/);
  });

  it("since より後に保存したものだけを返す", async () => {
    const { server_time } = (await (await send("GET", "/v1/sessions")).json()) as any;
    expect(((await (await send("GET", `/v1/sessions?since=${server_time}`)).json()) as any).sessions).toEqual([]);

    await new Promise((r) => setTimeout(r, 5));
    await send("POST", "/v1/sessions", { ...session, summary: "あとから更新" });
    const body = (await (await send("GET", `/v1/sessions?since=${encodeURIComponent(server_time)}`)).json()) as any;
    expect(body.sessions.map((s: any) => s.summary)).toEqual(["あとから更新"]);
  });

  it("limit で件数を絞れる", async () => {
    const body = (await (await send("GET", "/v1/sessions?limit=1")).json()) as any;
    expect(body.sessions).toHaveLength(1);
  });

  it.each(["since=yesterday", "limit=0", "limit=201"])("%s は 400", async (q) => {
    expect((await send("GET", `/v1/sessions?${q}`)).status).toBe(400);
  });
});

describe("/v1/memory", () => {
  it("カテゴリごとに入れ替えて、一覧で返す", async () => {
    let res = await send("PUT", "/v1/memory", {
      category: "likes",
      items: [{ content: "サッカー" }, { content: "猫のミケ" }],
    });
    expect(res.status).toBe(200);
    expect(((await res.json()) as any).memories.map((m: any) => m.content)).toEqual(["サッカー", "猫のミケ"]);

    await send("PUT", "/v1/memory", { category: "weak_points", items: [{ content: "割合" }] });
    res = await send("PUT", "/v1/memory", { category: "likes", items: [{ content: "サッカー" }] });
    expect(res.status).toBe(200);

    const all = (await (await send("GET", "/v1/memory")).json()) as any;
    expect(all.memories.map((m: any) => [m.category, m.content])).toEqual([
      ["likes", "サッカー"],
      ["weak_points", "割合"],
    ]);
    expect(all.memories[0]).toMatchObject({ child_id: "default" });
    expect(all.memories[0].id).toBeTruthy();
    expect(all.memories[0].updated_at).toMatch(/Z$/);

    const weak = (await (await send("GET", "/v1/memory?category=weak_points")).json()) as any;
    expect(weak.memories.map((m: any) => m.content)).toEqual(["割合"]);
  });

  it("items が空ならそのカテゴリを消す", async () => {
    await send("PUT", "/v1/memory", { category: "events", items: [{ content: "運動会" }] });
    await send("PUT", "/v1/memory", { category: "events", items: [] });
    expect(((await (await send("GET", "/v1/memory")).json()) as any).memories).toEqual([]);
  });

  it("別の家族の記憶は見えないし、消えない", async () => {
    await seedOtherFamily();
    expect(((await (await send("GET", "/v1/memory")).json()) as any).memories).toEqual([]);
    await send("PUT", "/v1/memory", { category: "likes", items: [] });
    const row = await d1.db().prepare("SELECT content FROM memories WHERE id = 'm-other'").first();
    expect(row).toEqual({ content: "よその好きなこと" });
    expect((await send("PUT", "/v1/memory", { child_id: "other-child", category: "likes", items: [] })).status).toBe(404);
  });

  it.each([
    ["知らないカテゴリ", { category: "secrets", items: [] }],
    ["空の content", { category: "likes", items: [{ content: "" }] }],
    ["余計なフィールド", { category: "likes", items: [{ content: "a", photo: "x" }] }],
  ])("%s は 400", async (_, body) => {
    expect((await send("PUT", "/v1/memory", body)).status).toBe(400);
  });

  it("GET の category が違えば 400", async () => {
    expect((await send("GET", "/v1/memory?category=secrets")).status).toBe(400);
  });
});
