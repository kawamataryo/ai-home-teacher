// 親の Web ダッシュボード（/dashboard）。
// Google ログイン（許可したメールのみ）→ 署名付き Cookie のセッション → 学習のようすと家族トークンの発行。

import { Hono, type Context } from "hono";
import { deleteCookie, getSignedCookie, setSignedCookie } from "hono/cookie";
import { csrf } from "hono/csrf";
import { BOOTSTRAP_FAMILY_ID } from "../auth";
import type { Env } from "../env";
import { deleteMemory, listMemories, listParentMessages, listSessions, resolveChild } from "../sync";
import { currentTokenIssuedAt, issueFamilyToken } from "../tokens";
import { ensureWeeklySummary, listWeeklySummaries, type WeeklyState } from "./weekly";
import { GROWTH_WEEKS, weeklyGrowth, type GrowthProblem } from "./growth";
import { authorizationUrl, exchangeCodeForEmail, isAllowedEmail, pkceChallenge, randomString } from "./google";
import { DashboardPage, jstDay, LoginPage, type DayTotal } from "./views";

type DashEnv = { Bindings: Env };
type Parent = { email: string; familyId: string };

export const SESSION_COOKIE = "ht_session";
export const OAUTH_COOKIE = "ht_oauth";
const SESSION_DAYS = 7;
const CHART_DAYS = 14;
const MESSAGE_LIST = 5;
// 伝えるのは 1 回の勉強で 1 つなので、たまりすぎないようにする
const MAX_UNDELIVERED_MESSAGES = 10;
export const MESSAGE_BODY_MAX = 200;
export const SENDER_LABEL_MAX = 12;
// 呼び方が空のときの言い方。先生に推測させない
export const DEFAULT_SENDER_LABEL = "おうちの人";

export const dashboard = new Hono<DashEnv>();

// フォームの POST は同じオリジンからだけ受け付ける（Origin / Sec-Fetch-Site を見る）
dashboard.use("*", csrf());
dashboard.use("*", async (c, next) => {
  await next();
  c.header("cache-control", "no-store");
  c.header("x-frame-options", "DENY");
  c.header("referrer-policy", "no-referrer");
});

dashboard.get("/", async (c) => {
  const parent = await currentParent(c);
  if (!parent) return c.html(<LoginPage />);
  return c.html(await renderDashboard(c, parent));
});

dashboard.post("/token", async (c) => {
  const parent = await currentParent(c);
  if (!parent) return c.redirect("/dashboard", 303);
  const token = await issueFamilyToken(c.env.DB, parent.familyId);
  return c.html(await renderDashboard(c, parent, { newToken: token }));
});

// 親の伝言（#159）。次の勉強の始まりに先生が伝える
dashboard.post("/messages", async (c) => {
  const parent = await currentParent(c);
  if (!parent) return c.redirect("/dashboard", 303);
  const form = await c.req.parseBody();
  // 読み上げるので、改行は空白にする
  const body = (typeof form.body === "string" ? form.body : "").replace(/\s+/g, " ").trim();
  const sender = (typeof form.sender === "string" ? form.sender : "").replace(/\s+/g, " ").trim();
  const draft = { sender, body };
  const fail = async (error: string) => c.html(await renderDashboard(c, parent, { messageError: error, messageDraft: draft }), 400);
  if ([...body].length === 0) return fail("伝言を書いてください。");
  if ([...body].length > MESSAGE_BODY_MAX) return fail(`伝言は ${MESSAGE_BODY_MAX} 文字までです。`);
  if ([...sender].length > SENDER_LABEL_MAX) return fail(`呼び方は ${SENDER_LABEL_MAX} 文字までです。`);

  const db = c.env.DB;
  const childId = await resolveChild(db, parent.familyId);
  if (!childId) return fail("お子さんの登録が見つかりませんでした。");
  const pending = await listParentMessages(db, parent.familyId, { undeliveredOnly: true, limit: MAX_UNDELIVERED_MESSAGES });
  if (pending.length >= MAX_UNDELIVERED_MESSAGES) return fail("まだ伝えていない伝言がたまっています。先生が伝えてから、また書いてください。");
  await db
    .prepare("INSERT INTO parent_messages (id, child_id, sender_label, body, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(crypto.randomUUID(), childId, sender || DEFAULT_SENDER_LABEL, body, new Date().toISOString())
    .run();
  return c.redirect("/dashboard", 303);
});

// 先生が覚えていることを親が消す（#160）。行の id は同期のたびに変わるので、カテゴリと内容で指定する
dashboard.post("/memories/delete", async (c) => {
  const parent = await currentParent(c);
  if (!parent) return c.redirect("/dashboard", 303);
  const form = await c.req.parseBody();
  const category = form.category;
  const content = form.content;
  if (
    (category !== "likes" && category !== "events" && category !== "weak_points") ||
    typeof content !== "string" ||
    content.length === 0
  ) {
    return c.html(await renderDashboard(c, parent, { memoryError: "消す記憶が分かりませんでした。" }), 400);
  }
  // もうなくても（同期で先に消えていても）、見たい結果は同じなので画面に戻る
  await deleteMemory(c.env.DB, parent.familyId, category, content);
  return c.redirect("/dashboard#memory", 303);
});

dashboard.post("/logout", (c) => {
  deleteCookie(c, SESSION_COOKIE, { path: "/dashboard", secure: true });
  return c.redirect("/dashboard", 303);
});

// ---- Google ログイン ----

dashboard.get("/auth/login", async (c) => {
  const { GOOGLE_CLIENT_ID, SESSION_SECRET } = c.env;
  if (!GOOGLE_CLIENT_ID || !SESSION_SECRET) return notConfigured(c);
  const state = randomString();
  const nonce = randomString();
  const verifier = randomString(48);
  // state / nonce / PKCE の verifier は 10 分だけ有効な署名付き Cookie に入れる。
  // Google からのリダイレクト（別サイトからのトップレベル GET）でも送られるよう SameSite=Lax
  await setSignedCookie(c, OAUTH_COOKIE, JSON.stringify({ state, nonce, verifier }), SESSION_SECRET, {
    path: "/dashboard/auth",
    httpOnly: true,
    secure: true,
    sameSite: "Lax",
    maxAge: 600,
  });
  return c.redirect(
    authorizationUrl({
      clientId: GOOGLE_CLIENT_ID,
      redirectUri: redirectUri(c),
      state,
      nonce,
      codeChallenge: await pkceChallenge(verifier),
    }),
    302,
  );
});

dashboard.get("/auth/callback", async (c) => {
  const { GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, SESSION_SECRET } = c.env;
  if (!GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET || !SESSION_SECRET) return notConfigured(c);

  const saved = parseJson<{ state: string; nonce: string; verifier: string }>(
    await getSignedCookie(c, SESSION_SECRET, OAUTH_COOKIE),
  );
  deleteCookie(c, OAUTH_COOKIE, { path: "/dashboard/auth", secure: true });
  const code = c.req.query("code");
  if (!saved || !code || c.req.query("state") !== saved.state) {
    return c.html(<LoginPage message="ログインをやり直してください。" />, 400);
  }

  const email = await exchangeCodeForEmail({
    code,
    codeVerifier: saved.verifier,
    clientId: GOOGLE_CLIENT_ID,
    clientSecret: GOOGLE_CLIENT_SECRET,
    redirectUri: redirectUri(c),
    nonce: saved.nonce,
  });
  if (!email) return c.html(<LoginPage message="Google での確認に失敗しました。" />, 401);
  if (!isAllowedEmail(email, c.env.PARENT_EMAILS)) {
    return c.html(<LoginPage message="このアカウントは許可されていません。" />, 403);
  }

  const familyId = await familyForParent(c.env.DB, email);
  const exp = Date.now() + SESSION_DAYS * 24 * 60 * 60 * 1000;
  await setSignedCookie(c, SESSION_COOKIE, JSON.stringify({ email, familyId, exp }), SESSION_SECRET, {
    path: "/dashboard",
    httpOnly: true,
    secure: true,
    sameSite: "Lax",
    maxAge: SESSION_DAYS * 24 * 60 * 60,
  });
  return c.redirect("/dashboard", 302);
});

// ---- ログイン状態 ----

async function currentParent(c: Context<DashEnv>): Promise<Parent | null> {
  if (devAuthBypass(c)) return { email: "dev@localhost（開発用）", familyId: BOOTSTRAP_FAMILY_ID };
  const secret = c.env.SESSION_SECRET;
  if (!secret) return null;
  const s = parseJson<{ email: string; familyId: string; exp: number }>(
    await getSignedCookie(c, secret, SESSION_COOKIE),
  );
  if (!s || typeof s.exp !== "number" || s.exp < Date.now()) return null;
  // 許可リストから外したら、ログイン中でもすぐに見られなくする
  if (!isAllowedEmail(s.email, c.env.PARENT_EMAILS)) return null;
  return { email: s.email, familyId: s.familyId };
}

// スクリーンショット用。.dev.vars の DEV_AUTH_BYPASS=1 と localhost の両方がそろったときだけ
function devAuthBypass(c: Context<DashEnv>): boolean {
  if (c.env.DEV_AUTH_BYPASS !== "1") return false;
  const host = new URL(c.req.url).hostname;
  return host === "localhost" || host === "127.0.0.1";
}

// 11/8 時点は 1 家庭だけなので、初めてログインした親は家族 'default' に入れる
async function familyForParent(db: D1Database, email: string): Promise<string> {
  await db
    .prepare("INSERT INTO parents (id, family_id, email) VALUES (?, ?, ?) ON CONFLICT(email) DO NOTHING")
    .bind(crypto.randomUUID(), BOOTSTRAP_FAMILY_ID, email)
    .run();
  const row = await db.prepare("SELECT family_id FROM parents WHERE email = ?").bind(email).first<{ family_id: string }>();
  return row?.family_id ?? BOOTSTRAP_FAMILY_ID;
}

// ---- 表示 ----

type RenderOptions = { memoryError?: string; newToken?: string; messageError?: string; messageDraft?: { sender: string; body: string } };

async function renderDashboard(c: Context<DashEnv>, parent: Parent, options: RenderOptions = {}) {
  const db = c.env.DB;
  const now = Date.now();
  const today = jstDay(now);
  const days: DayTotal[] = [];
  for (let i = CHART_DAYS - 1; i >= 0; i--) days.push({ day: jstDay(now - i * 86_400_000), minutes: 0 });
  // JST の 0 時を UTC にして絞り込む
  const fromUtc = new Date(Date.parse(`${days[0].day}T00:00:00Z`) - 9 * 3_600_000).toISOString();

    const growthFrom = new Date(now - GROWTH_WEEKS * 7 * 86_400_000).toISOString();
  const weekly = await loadWeeklyState(c, parent, now);
  const [chartRows, sessions, tokenIssuedAt, messages, memories, growthRows] = await Promise.all([
    db
      .prepare(
        `SELECT s.started_at, s.focus_minutes FROM sessions s JOIN children c ON c.id = s.child_id
         WHERE c.family_id = ? AND s.started_at >= ?`,
      )
      .bind(parent.familyId, fromUtc)
      .all<{ started_at: string; focus_minutes: number }>(),
    listSessions(db, parent.familyId, { limit: 30 }),
    currentTokenIssuedAt(db, parent.familyId),
    listParentMessages(db, parent.familyId, { limit: MESSAGE_LIST }),
    listMemories(db, parent.familyId, {}),
    db
      .prepare(
        `SELECT s.started_at, p.solved_by_self, p.hint_level_reached
         FROM problems p JOIN sessions s ON s.id = p.session_id JOIN children c ON c.id = s.child_id
         WHERE c.family_id = ? AND s.started_at >= ?`,
      )
      .bind(parent.familyId, growthFrom)
      .all<GrowthProblem>(),
  ]);
  for (const r of chartRows.results) {
    const d = days.find((x) => x.day === jstDay(r.started_at));
    if (d) d.minutes += r.focus_minutes;
  }

  return (
    <DashboardPage
      email={parent.email}
      days={days}
      today={today}
      sessions={sessions}
      tokenIssuedAt={tokenIssuedAt}
      growth={weeklyGrowth(growthRows.results, now)}
      weekly={weekly}
      messages={messages}
      memories={memories}
      memoryError={options.memoryError}
      newToken={options.newToken}
      messageError={options.messageError}
      messageDraft={options.messageDraft}
    />
  );
}

// 週のまとめ（#162）。ここで失敗しても画面は普通に開く
async function loadWeeklyState(c: Context<DashEnv>, parent: Parent, now: number): Promise<WeeklyState> {
  try {
    const childId = await resolveChild(c.env.DB, parent.familyId);
    if (!childId) return { summaries: [], generating: false };
    const generating = await ensureWeeklySummary(c.env, childId, now, (task) => c.executionCtx.waitUntil(task));
    return { summaries: await listWeeklySummaries(c.env.DB, childId), generating };
  } catch {
    return { summaries: [], generating: false };
  }
}

function redirectUri(c: Context<DashEnv>): string {
  return new URL("/dashboard/auth/callback", c.req.url).toString();
}

function notConfigured(c: Context<DashEnv>) {
  return c.html(<LoginPage message="ログインの設定（Google のクライアント ID など）がまだです。" />, 500);
}

function parseJson<T>(raw: string | false | undefined): T | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}
