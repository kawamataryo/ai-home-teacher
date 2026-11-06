// アプリとの同期 API（/v1/sessions, /v1/memory）。
// どのクエリも、認証で解決した家族（c.var.familyId）の子どものデータだけを読み書きする。
// 保存するのは文字の情報だけ。スキーマは .strict() なので、画像や音声のフィールドが来たら 400 にする。

import { Hono, type Context } from "hono";
import { z } from "zod";
import type { AppEnv } from "./env";

export const sync = new Hono<AppEnv>();

// ---- 入力のスキーマ ----

// UTC に正規化した ISO 8601 文字列にする（文字列のまま大小比較できるように）
const isoDateTime = z.iso.datetime({ offset: true }).transform((s) => new Date(s).toISOString());
const id = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/, "id は英数字・-・_ の 64 文字以内");

const problemInput = z
  .object({
    kind: z.enum(["reading", "thinking", "writing"]),
    summary: z.string().min(1).max(1000),
    solved_by_self: z.boolean(),
    hint_level_reached: z.int().min(0).max(4).default(0),
    created_at: isoDateTime.optional(),
  })
  .strict();

const sessionInput = z
  .object({
    id,
    child_id: id.optional(),
    started_at: isoDateTime,
    ended_at: isoDateTime,
    focus_minutes: z.int().min(0).max(24 * 60),
    summary: z.string().max(4000).default(""),
    teacher_note: z.string().max(1000).default(""),
    // 今夜の声かけ（#158）。古いアプリは送ってこない
    parent_prompt: z.string().max(500).default(""),
    flags: z.array(z.string().min(1).max(500)).max(20).default([]),
    problems: z.array(problemInput).max(100).default([]),
  })
  .strict()
  .refine((s) => s.ended_at >= s.started_at, { message: "ended_at は started_at 以降", path: ["ended_at"] });

const sessionsQuery = z.object({
  since: isoDateTime.optional(),
  child_id: id.optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  // updated: 保存した順（古い順）。アプリが since を進めながらページ送りするときに使う
  order: z.enum(["started", "updated"]).default("started"),
});

const category = z.enum(["likes", "events", "weak_points"]);

const memoryQuery = z.object({
  category: category.optional(),
  child_id: id.optional(),
});

const memoryPut = z
  .object({
    child_id: id.optional(),
    category,
    items: z.array(z.object({ content: z.string().min(1).max(500) }).strict()).max(100),
  })
  .strict();

// ---- DB の行と返す JSON ----

type SessionRow = {
  id: string;
  child_id: string;
  started_at: string;
  ended_at: string;
  focus_minutes: number;
  summary: string;
  teacher_note: string;
  parent_prompt: string;
  flags: string;
  updated_at: string;
};

type ProblemRow = {
  id: string;
  session_id: string;
  kind: string;
  summary: string;
  solved_by_self: number;
  hint_level_reached: number;
  created_at: string;
};

type MemoryRow = { id: string; child_id: string; category: string; content: string; updated_at: string };

export type SessionJson = Omit<SessionRow, "flags"> & {
  flags: string[];
  problems: Array<Omit<ProblemRow, "session_id" | "solved_by_self"> & { solved_by_self: boolean }>;
};

function toSessionJson(row: SessionRow, problems: ProblemRow[]): SessionJson {
  return {
    ...row,
    flags: parseFlags(row.flags),
    problems: problems.map(({ session_id: _, solved_by_self, ...p }) => ({
      ...p,
      solved_by_self: solved_by_self === 1,
    })),
  };
}

function parseFlags(raw: string): string[] {
  try {
    const v: unknown = JSON.parse(raw);
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

// ---- ルート ----

sync.post("/sessions", async (c) => {
  const input = await parseBody(c, sessionInput);
  if (input instanceof Response) return input;
  const db = c.env.DB;
  const familyId = c.var.familyId;

  // 同じ id のセッションが別の家族のものなら触らない（存在も明かさない）
  const owner = await db
    .prepare("SELECT c.family_id FROM sessions s JOIN children c ON c.id = s.child_id WHERE s.id = ?")
    .bind(input.id)
    .first<{ family_id: string }>();
  if (owner && owner.family_id !== familyId) return c.json({ error: "session not found" }, 404);

  const childId = await resolveChild(db, familyId, input.child_id);
  if (!childId) return c.json({ error: "child not found" }, 404);

  const now = new Date().toISOString();
  // batch は 1 つのトランザクションで実行される。問題は毎回入れ替える（送り直しても重複しない）
  await db.batch([
    db
      .prepare(
        `INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, summary, teacher_note, parent_prompt, flags, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           child_id = excluded.child_id, started_at = excluded.started_at, ended_at = excluded.ended_at,
           focus_minutes = excluded.focus_minutes, summary = excluded.summary,
           teacher_note = excluded.teacher_note, parent_prompt = excluded.parent_prompt, flags = excluded.flags, updated_at = excluded.updated_at`,
      )
      .bind(
        input.id,
        childId,
        input.started_at,
        input.ended_at,
        input.focus_minutes,
        input.summary,
        input.teacher_note,
        input.parent_prompt,
        JSON.stringify(input.flags),
        now,
      ),
    db.prepare("DELETE FROM problems WHERE session_id = ?").bind(input.id),
    ...input.problems.map((p) =>
      db
        .prepare(
          `INSERT INTO problems (id, session_id, kind, summary, solved_by_self, hint_level_reached, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          crypto.randomUUID(),
          input.id,
          p.kind,
          p.summary,
          p.solved_by_self ? 1 : 0,
          p.hint_level_reached,
          p.created_at ?? input.started_at,
        ),
    ),
  ]);

  const [session] = await listSessions(db, familyId, { sessionId: input.id, limit: 1 });
  return c.json({ session });
});

sync.get("/sessions", async (c) => {
  const q = sessionsQuery.safeParse(c.req.query());
  if (!q.success) return invalid(c, q.error);
  const serverTime = new Date().toISOString();
  const sessions = await listSessions(c.env.DB, c.var.familyId, q.data);
  return c.json({ sessions, server_time: serverTime });
});

sync.get("/memory", async (c) => {
  const q = memoryQuery.safeParse(c.req.query());
  if (!q.success) return invalid(c, q.error);
  const memories = await listMemories(c.env.DB, c.var.familyId, q.data);
  return c.json({ memories });
});

sync.put("/memory", async (c) => {
  const input = await parseBody(c, memoryPut);
  if (input instanceof Response) return input;
  const db = c.env.DB;
  const childId = await resolveChild(db, c.var.familyId, input.child_id);
  if (!childId) return c.json({ error: "child not found" }, 404);

  // そのカテゴリの記憶をまるごと入れ替える（PUT なので何度送っても同じ結果になる）
  const now = new Date().toISOString();
  await db.batch([
    db.prepare("DELETE FROM memories WHERE child_id = ? AND category = ?").bind(childId, input.category),
    ...input.items.map((item) =>
      db
        .prepare("INSERT INTO memories (id, child_id, category, content, updated_at) VALUES (?, ?, ?, ?, ?)")
        .bind(crypto.randomUUID(), childId, input.category, item.content, now),
    ),
  ]);
  const memories = await listMemories(db, c.var.familyId, { child_id: childId, category: input.category });
  return c.json({ memories });
});

// ---- クエリ ----

// child_id の指定がなければ家族の最初の子ども。指定があれば、その家族の子どもかを確かめる
async function resolveChild(db: D1Database, familyId: string, childId?: string): Promise<string | null> {
  const row = childId
    ? await db.prepare("SELECT id FROM children WHERE id = ? AND family_id = ?").bind(childId, familyId).first<{ id: string }>()
    : await db
        .prepare("SELECT id FROM children WHERE family_id = ? ORDER BY created_at, id LIMIT 1")
        .bind(familyId)
        .first<{ id: string }>();
  return row?.id ?? null;
}

// 既定は started_at の新しい順。order: "updated" なら updated_at の古い順（ページ送り用）。
// since は updated_at（サーバーが保存した時刻）で絞る
export async function listSessions(
  db: D1Database,
  familyId: string,
  opts: { since?: string; child_id?: string; sessionId?: string; limit: number; order?: "started" | "updated" },
): Promise<SessionJson[]> {
  const where = ["c.family_id = ?"];
  const params: unknown[] = [familyId];
  if (opts.since) (where.push("s.updated_at >= ?"), params.push(opts.since));
  if (opts.child_id) (where.push("s.child_id = ?"), params.push(opts.child_id));
  if (opts.sessionId) (where.push("s.id = ?"), params.push(opts.sessionId));

  const orderBy = opts.order === "updated" ? "s.updated_at ASC, s.id" : "s.started_at DESC, s.id";
  const { results: sessions } = await db
    .prepare(
      `SELECT s.* FROM sessions s JOIN children c ON c.id = s.child_id
       WHERE ${where.join(" AND ")} ORDER BY ${orderBy} LIMIT ?`,
    )
    .bind(...params, opts.limit)
    .all<SessionRow>();
  if (sessions.length === 0) return [];

  const ids = sessions.map((s) => s.id);
  const { results: problems } = await db
    .prepare(
      `SELECT * FROM problems WHERE session_id IN (${ids.map(() => "?").join(", ")})
       ORDER BY created_at, rowid`,
    )
    .bind(...ids)
    .all<ProblemRow>();
  return sessions.map((s) =>
    toSessionJson(
      s,
      problems.filter((p) => p.session_id === s.id),
    ),
  );
}

async function listMemories(
  db: D1Database,
  familyId: string,
  opts: { category?: string; child_id?: string },
): Promise<MemoryRow[]> {
  const where = ["c.family_id = ?"];
  const params: unknown[] = [familyId];
  if (opts.category) (where.push("m.category = ?"), params.push(opts.category));
  if (opts.child_id) (where.push("m.child_id = ?"), params.push(opts.child_id));
  const { results } = await db
    .prepare(
      `SELECT m.id, m.child_id, m.category, m.content, m.updated_at
       FROM memories m JOIN children c ON c.id = m.child_id
       WHERE ${where.join(" AND ")} ORDER BY m.category, m.rowid`,
    )
    .bind(...params)
    .all<MemoryRow>();
  return results;
}

// ---- 入力の読み取り ----

async function parseBody<T extends z.ZodType>(c: Context<AppEnv>, schema: T): Promise<z.output<T> | Response> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    return c.json({ error: "invalid json" }, 400);
  }
  const parsed = schema.safeParse(raw);
  return parsed.success ? parsed.data : invalid(c, parsed.error);
}

function invalid(c: Context<AppEnv>, error: z.ZodError): Response {
  return c.json(
    {
      error: "invalid request",
      issues: error.issues.map((i) => ({ path: i.path.join("."), message: i.message })),
    },
    400,
  );
}
