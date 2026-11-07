import { beforeEach, describe, expect, it } from "vitest";
import app, { type Env } from "../src/index";
import { deleteMemory } from "../src/sync";
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

  it("今夜の声かけを保存して返す。項目なしでも空文字になる（古いアプリ）", async () => {
    const withPrompt = { ...session, parent_prompt: "「どうやって見つけたの？」と聞いてみてください" };
    const res = await send("POST", "/v1/sessions", withPrompt);
    expect(res.status).toBe(200);
    expect(((await res.json()) as any).session.parent_prompt).toBe(withPrompt.parent_prompt);

    const old = await send("POST", "/v1/sessions", { ...session, id: "old-app" });
    expect(old.status).toBe(200);
    expect(((await old.json()) as any).session.parent_prompt).toBe("");

    // 同じ id で送り直したら声かけも上書きされる
    const again = await send("POST", "/v1/sessions", { ...withPrompt, parent_prompt: "「図はどうかいたの？」と聞いてみてください" });
    expect(((await again.json()) as any).session.parent_prompt).toBe("「図はどうかいたの？」と聞いてみてください");

    const tooLong = await send("POST", "/v1/sessions", { ...session, parent_prompt: "あ".repeat(501) });
    expect(tooLong.status).toBe(400);
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

  it("order=updated なら保存した順（古い順）に返す", async () => {
    // started_at は 2222 のほうが新しいが、保存したのは session（1111）が先
    const byUpdated = (await (await send("GET", "/v1/sessions?order=updated")).json()) as any;
    expect(byUpdated.sessions.map((s: any) => s.id)).toEqual([session.id, "22222222-2222-4222-8222-222222222222"]);

    // 1111 を更新すると最後に来る
    await new Promise((r) => setTimeout(r, 5));
    await send("POST", "/v1/sessions", { ...session, summary: "あとから更新" });
    const again = (await (await send("GET", "/v1/sessions?order=updated")).json()) as any;
    expect(again.sessions.map((s: any) => s.id)).toEqual(["22222222-2222-4222-8222-222222222222", session.id]);
  });

  it.each(["since=yesterday", "limit=0", "limit=201", "order=random"])("%s は 400", async (q) => {
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

describe("/v1/messages（親の伝言）", () => {
  async function seedMessages() {
    await seedOtherFamily();
    const db = d1.db();
    const insert = (id: string, child: string, body: string, created: string, delivered: string | null = null) =>
      db
        .prepare("INSERT INTO parent_messages (id, child_id, sender_label, body, created_at, delivered_at) VALUES (?, ?, 'お母さん', ?, ?, ?)")
        .bind(id, child, body, created, delivered);
    await db.batch([
      insert("new", "default", "新しい伝言", "2026-11-03T02:00:00.000Z"),
      insert("old", "default", "古い伝言", "2026-11-03T01:00:00.000Z"),
      insert("told", "default", "伝えた伝言", "2026-11-02T01:00:00.000Z", "2026-11-02T07:00:00.000Z"),
      insert("other-msg", "other-child", "よその伝言", "2026-11-03T00:00:00.000Z"),
    ]);
  }

  it("まだ伝えていない自分の家族の伝言だけを古い順に返す", async () => {
    await seedMessages();
    const res = await send("GET", "/v1/messages");
    expect(res.status).toBe(200);
    const { messages } = (await res.json()) as any;
    expect(messages.map((m: any) => m.id)).toEqual(["old", "new"]);
    expect(messages[0]).toMatchObject({ sender_label: "お母さん", body: "古い伝言", delivered_at: null });
  });

  it("伝えた印を付けると返さなくなる。送り直しても最初の時刻のまま", async () => {
    await seedMessages();
    const first = await send("POST", "/v1/messages/old/delivered", { delivered_at: "2026-11-03T07:00:00+09:00" });
    expect(first.status).toBe(200);
    const again = await send("POST", "/v1/messages/old/delivered", { delivered_at: "2026-11-04T07:00:00+09:00" });
    expect(again.status).toBe(200);
    const row = await d1.db().prepare("SELECT delivered_at FROM parent_messages WHERE id = 'old'").first<{ delivered_at: string }>();
    expect(row?.delivered_at).toBe("2026-11-02T22:00:00.000Z");
    const { messages } = (await (await send("GET", "/v1/messages")).json()) as any;
    expect(messages.map((m: any) => m.id)).toEqual(["new"]);
  });

  it("別の家族の伝言は既読にできない（存在も明かさない）", async () => {
    await seedMessages();
    const res = await send("POST", "/v1/messages/other-msg/delivered", {});
    expect(res.status).toBe(404);
    const row = await d1.db().prepare("SELECT delivered_at FROM parent_messages WHERE id = 'other-msg'").first<{ delivered_at: string | null }>();
    expect(row?.delivered_at).toBeNull();
  });

  it("トークンなしは 401", async () => {
    const res = await app.request("/v1/messages", {}, env());
    expect(res.status).toBe(401);
  });
});

describe("親が消した記憶を PUT /v1/memory で復活させない", () => {
  const put = (items: string[], basedOn?: string, extra: Record<string, unknown> = {}) =>
    send("PUT", "/v1/memory", {
      category: "likes",
      items: items.map((content) => ({ content })),
      ...(basedOn ? { based_on: basedOn } : {}),
      ...extra,
    });
  const contents = async (res: Response) => ((await res.json()) as any).memories.map((m: any) => m.content);

  it("端末が消す前の内容で送ってきたら、消した記憶だけを除いて新しい記憶は残す", async () => {
    await put(["サッカー", "猫のミケ"]);
    const { server_time: base } = (await (await send("GET", "/v1/memory")).json()) as any;
    // 親が消す
    await new Promise((r) => setTimeout(r, 5));
    expect(await deleteMemory(d1.db(), "default", "likes", "猫のミケ")).toBe(1);

    // 端末には未送信の変更がある（消す前の内容に、新しく覚えたことを足したもの）
    const res = await put(["サッカー", "猫のミケ", "マイクラ"], base);
    expect(res.status).toBe(200);
    expect(await contents(res)).toEqual(["サッカー", "マイクラ"]);
    expect(await contents(await send("GET", "/v1/memory"))).toEqual(["サッカー", "マイクラ"]);
  });

  it("表記の違い（全角半角・大文字小文字・空白）でも復活しない", async () => {
    await put(["Ｍinecraft  の 建築"]);
    await deleteMemory(d1.db(), "default", "likes", "minecraft の建築".replace("の建築", "の 建築"));
    expect(await contents(await put(["MINECRAFT の 建築", "サッカー"]))).toEqual(["サッカー"]);
  });

  it("based_on がなければ（古いアプリ）消した記憶はすべて復活しない", async () => {
    await put(["猫のミケ"]);
    await deleteMemory(d1.db(), "default", "likes", "猫のミケ");
    expect(await contents(await put(["猫のミケ", "サッカー"]))).toEqual(["サッカー"]);
  });

  it("端末が消えたことを知ったあとに子どもがまた話した記憶は受け入れる", async () => {
    await put(["猫のミケ"]);
    await deleteMemory(d1.db(), "default", "likes", "猫のミケ");
    await new Promise((r) => setTimeout(r, 5));
    const { server_time: base, memories } = (await (await send("GET", "/v1/memory")).json()) as any;
    expect(memories).toEqual([]);
    await new Promise((r) => setTimeout(r, 5));
    expect(await contents(await put(["猫のミケ"], base))).toEqual(["猫のミケ"]);
  });

  it("消した時刻と based_on が同じなら、まだ知らないとみなす", async () => {
    await put(["猫のミケ"]);
    await deleteMemory(d1.db(), "default", "likes", "猫のミケ");
    const { deleted_at } = (await d1.db().prepare("SELECT deleted_at FROM memory_deletions").first<{ deleted_at: string }>())!;
    expect(await contents(await put(["猫のミケ"], deleted_at))).toEqual([]);
  });

  it("別のカテゴリの同じ言葉には効かない", async () => {
    await put(["割合"]);
    await send("PUT", "/v1/memory", { category: "weak_points", items: [{ content: "割合" }] });
    await deleteMemory(d1.db(), "default", "likes", "割合");
    const res = await send("PUT", "/v1/memory", { category: "weak_points", items: [{ content: "割合" }] });
    expect(await contents(res)).toEqual(["割合"]);
  });

  it("消した言葉そのものは印に残さない", async () => {
    await put(["猫のミケ"]);
    await deleteMemory(d1.db(), "default", "likes", "猫のミケ");
    const row = await d1.db().prepare("SELECT * FROM memory_deletions").first<Record<string, string>>();
    expect(JSON.stringify(row)).not.toContain("ミケ");
    expect(row?.content_hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it("別の家族の記憶は消せない", async () => {
    await seedOtherFamily();
    expect(await deleteMemory(d1.db(), "default", "likes", "よその好きなこと")).toBe(0);
    const row = await d1.db().prepare("SELECT content FROM memories WHERE id = 'm-other'").first();
    expect(row).toEqual({ content: "よその好きなこと" });
    expect((await d1.db().prepare("SELECT count(*) AS n FROM memory_deletions").first<{ n: number }>())!.n).toBe(0);
  });

  it("based_on が時刻でなければ 400", async () => {
    expect((await put(["a"], "きのう")).status).toBe(400);
  });
});
