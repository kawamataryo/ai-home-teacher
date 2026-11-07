import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app, { type Env } from "../src/index";
import { jstWeekStart } from "../src/dashboard/growth";
import { useD1 } from "./helpers/d1";

const d1 = useD1();
const CLIENT_ID = "test-client.apps.googleusercontent.com";
const PARENT = "parent@example.com";

function env(overrides: Partial<Env> = {}): Env {
  return {
    ANTHROPIC_API_KEY: "x",
    ELEVENLABS_API_KEY: "x",
    TYPESAFE_API_KEY: "x",
    FAMILY_TOKEN: "bootstrap-secret",
    ELEVENLABS_VOICE_ID: "x",
    DB: d1.db(),
    GOOGLE_CLIENT_ID: CLIENT_ID,
    GOOGLE_CLIENT_SECRET: "test-google-secret",
    SESSION_SECRET: "test-session-secret",
    PARENT_EMAILS: ` Parent@Example.com , other-parent@example.com`,
    ...overrides,
  };
}

function req(path: string, init: RequestInit = {}, e: Env = env()) {
  return app.request(path, init, e);
}

// Set-Cookie から「名前=値」だけを取り出す
function cookie(res: Response, name: string): string | undefined {
  return res.headers
    .getSetCookie()
    .map((c) => c.split(";")[0])
    .find((c) => c.startsWith(`${name}=`) && c.length > name.length + 1);
}

function setCookieLine(res: Response, name: string): string | undefined {
  return res.headers.getSetCookie().find((c) => c.startsWith(`${name}=`));
}

function b64url(s: string): string {
  return btoa(String.fromCharCode(...new TextEncoder().encode(s)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function idToken(claims: Record<string, unknown>): string {
  return `${b64url(JSON.stringify({ alg: "RS256" }))}.${b64url(JSON.stringify(claims))}.sig`;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

// ログインを始めて、Google が返すはずの id_token の中身を指定してコールバックまで進める
async function login(claimsOverride: Record<string, unknown> = {}, e: Env = env()) {
  const start = await req("/dashboard/auth/login", {}, e);
  const location = new URL(start.headers.get("location")!);
  const oauthCookie = cookie(start, "ht_oauth")!;
  const claims = {
    iss: "https://accounts.google.com",
    aud: CLIENT_ID,
    exp: Math.floor(Date.now() / 1000) + 600,
    nonce: location.searchParams.get("nonce"),
    email: PARENT,
    email_verified: true,
    ...claimsOverride,
  };
  fetchMock.mockResolvedValueOnce(Response.json({ id_token: idToken(claims), access_token: "unused" }));
  const callback = await req(
    `/dashboard/auth/callback?code=auth-code&state=${location.searchParams.get("state")}`,
    { headers: { cookie: oauthCookie } },
    e,
  );
  return { start, location, oauthCookie, callback };
}

async function loggedInCookie(): Promise<string> {
  const { callback } = await login();
  expect(callback.status).toBe(302);
  return cookie(callback, "ht_session")!;
}

function postForm(path: string, sessionCookie: string, origin = "http://localhost") {
  return req(path, {
    method: "POST",
    headers: { cookie: sessionCookie, origin, "content-type": "application/x-www-form-urlencoded" },
    body: "",
  });
}

describe("Google ログイン", () => {
  it("ログイン開始で PKCE 付きの Google の認可 URL にリダイレクトする", async () => {
    const res = await req("/dashboard/auth/login");
    expect(res.status).toBe(302);
    const url = new URL(res.headers.get("location")!);
    expect(url.origin + url.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    const p = url.searchParams;
    expect(p.get("response_type")).toBe("code");
    expect(p.get("client_id")).toBe(CLIENT_ID);
    expect(p.get("redirect_uri")).toBe("http://localhost/dashboard/auth/callback");
    expect(p.get("scope")).toBe("openid email");
    expect(p.get("code_challenge_method")).toBe("S256");
    expect(p.get("code_challenge")).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(p.get("state")).toBeTruthy();
    expect(p.get("nonce")).toBeTruthy();
    const line = setCookieLine(res, "ht_oauth")!;
    expect(line).toMatch(/HttpOnly/);
    expect(line).toMatch(/Secure/);
    expect(line).toMatch(/SameSite=Lax/);
    expect(line).toMatch(/Path=\/dashboard\/auth/);
  });

  it("コールバックでコードを交換し、許可されたメールならセッション Cookie を発行する", async () => {
    const { location, callback } = await login({ email: "PARENT@example.com" });
    expect(callback.status).toBe(302);
    expect(callback.headers.get("location")).toBe("/dashboard");
    const line = setCookieLine(callback, "ht_session")!;
    expect(line).toMatch(/HttpOnly/);
    expect(line).toMatch(/Secure/);
    expect(line).toMatch(/SameSite=Lax/);

    // Google のトークンエンドポイントに PKCE の verifier とシークレットを送っている
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://oauth2.googleapis.com/token");
    expect(init.method).toBe("POST");
    const body = new URLSearchParams(init.body as URLSearchParams);
    expect(body.get("grant_type")).toBe("authorization_code");
    expect(body.get("code")).toBe("auth-code");
    expect(body.get("client_id")).toBe(CLIENT_ID);
    expect(body.get("client_secret")).toBe("test-google-secret");
    expect(body.get("redirect_uri")).toBe("http://localhost/dashboard/auth/callback");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body.get("code_verifier")!));
    const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    expect(challenge).toBe(location.searchParams.get("code_challenge"));

    // 親が家族 default に登録される
    const parent = await d1.db().prepare("SELECT family_id FROM parents WHERE email = ?").bind(PARENT).first();
    expect(parent).toEqual({ family_id: "default" });

    const page = await req("/dashboard", { headers: { cookie: cookie(callback, "ht_session")! } });
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain("学習のようす");
    expect(html).toContain(PARENT);
  });

  it("許可リストにないメールは 403 でセッションを作らない", async () => {
    const { callback } = await login({ email: "stranger@example.com" });
    expect(callback.status).toBe(403);
    expect(await callback.text()).toContain("このアカウントは許可されていません");
    expect(cookie(callback, "ht_session")).toBeUndefined();
    const { count } = (await d1.db().prepare("SELECT count(*) AS count FROM parents").first<{ count: number }>())!;
    expect(count).toBe(0);
  });

  it("PARENT_EMAILS が未設定なら誰も入れない", async () => {
    const { callback } = await login({}, env({ PARENT_EMAILS: "" }));
    expect(callback.status).toBe(403);
  });

  it.each([
    ["email_verified が false", { email_verified: false }],
    ["aud が違う", { aud: "someone-else" }],
    ["iss が違う", { iss: "https://evil.example" }],
    ["期限切れ", { exp: Math.floor(Date.now() / 1000) - 10 }],
    ["nonce が違う", { nonce: "other" }],
  ])("id_token の %s なら 401", async (_, claims) => {
    const { callback } = await login(claims);
    expect(callback.status).toBe(401);
    expect(cookie(callback, "ht_session")).toBeUndefined();
  });

  it("Google のトークンエンドポイントがエラーなら 401", async () => {
    const start = await req("/dashboard/auth/login");
    const state = new URL(start.headers.get("location")!).searchParams.get("state");
    fetchMock.mockResolvedValueOnce(Response.json({ error: "invalid_grant" }, { status: 400 }));
    const res = await req(`/dashboard/auth/callback?code=x&state=${state}`, {
      headers: { cookie: cookie(start, "ht_oauth")! },
    });
    expect(res.status).toBe(401);
  });

  it("state が違う・Cookie がないならコードを交換しない", async () => {
    const start = await req("/dashboard/auth/login");
    const res = await req("/dashboard/auth/callback?code=x&state=wrong", {
      headers: { cookie: cookie(start, "ht_oauth")! },
    });
    expect(res.status).toBe(400);
    const res2 = await req("/dashboard/auth/callback?code=x&state=whatever");
    expect(res2.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("署名が合わないセッション Cookie はログイン画面になる", async () => {
    const forged = `ht_session=${encodeURIComponent(JSON.stringify({ email: PARENT, familyId: "default", exp: Date.now() + 1e6 }))}.AAAA`;
    const html = await (await req("/dashboard", { headers: { cookie: forged } })).text();
    expect(html).toContain("Google でログイン");
    expect(html).not.toContain("学習のようす");
  });

  it("ログイン後に許可リストから外すと見られなくなる", async () => {
    const session = await loggedInCookie();
    const html = await (
      await req("/dashboard", { headers: { cookie: session } }, env({ PARENT_EMAILS: "other-parent@example.com" }))
    ).text();
    expect(html).toContain("Google でログイン");
  });

  it("Google の設定がなければログインを始めない", async () => {
    const res = await req("/dashboard/auth/login", {}, env({ GOOGLE_CLIENT_ID: undefined }));
    expect(res.status).toBe(500);
  });

  it("ログアウトでセッション Cookie を消す", async () => {
    const session = await loggedInCookie();
    const res = await postForm("/dashboard/logout", session);
    expect(res.status).toBe(303);
    expect(setCookieLine(res, "ht_session")).toMatch(/Max-Age=0/);
  });
});

describe("家族トークンの発行", () => {
  async function issue(session: string): Promise<string> {
    const res = await postForm("/dashboard/token", session);
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    const token = /ht_[A-Za-z0-9_-]{43}/.exec(await res.text())?.[0];
    expect(token).toBeTruthy();
    return token!;
  }

  function sync(token: string) {
    return req("/v1/memory", { headers: { Authorization: `Bearer ${token}` } });
  }

  it("発行したトークンで /v1 が使え、D1 にはハッシュだけが残る", async () => {
    const session = await loggedInCookie();
    const token = await issue(session);
    expect((await sync(token)).status).toBe(200);

    const rows = (await d1.db().prepare("SELECT * FROM family_tokens").all<{ token_hash: string; family_id: string }>())
      .results;
    expect(rows).toHaveLength(1);
    expect(rows[0].family_id).toBe("default");
    expect(rows[0].token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(rows)).not.toContain(token);

    // 発行後の画面では「再発行する」になり、トークンそのものは二度と出ない
    const html = await (await req("/dashboard", { headers: { cookie: session } })).text();
    expect(html).toContain("再発行する");
    expect(html).not.toContain(token);
  });

  it("再発行すると古いトークンは使えなくなる", async () => {
    const session = await loggedInCookie();
    const first = await issue(session);
    const second = await issue(session);
    expect(second).not.toBe(first);
    expect((await sync(first)).status).toBe(401);
    expect((await sync(second)).status).toBe(200);
  });

  it("FAMILY_TOKEN（予備）は発行後も使える", async () => {
    await issue(await loggedInCookie());
    expect((await sync("bootstrap-secret")).status).toBe(200);
    expect((await sync("ht_not-issued")).status).toBe(401);
  });

  it("別のサイトからの POST は拒否する（CSRF）", async () => {
    const session = await loggedInCookie();
    const res = await postForm("/dashboard/token", session, "https://evil.example");
    expect(res.status).toBe(403);
    const { count } = (await d1.db().prepare("SELECT count(*) AS count FROM family_tokens").first<{ count: number }>())!;
    expect(count).toBe(0);
  });

  it("ログインしていなければ発行しない", async () => {
    const res = await postForm("/dashboard/token", "");
    expect(res.status).toBe(303);
    const { count } = (await d1.db().prepare("SELECT count(*) AS count FROM family_tokens").first<{ count: number }>())!;
    expect(count).toBe(0);
  });
});

describe("ダッシュボードの表示", () => {
  it("ログインしていなければ Google ログインのボタンを出す", async () => {
    const res = await req("/dashboard");
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('href="/dashboard/auth/login"');
    expect(html).toContain('<meta name="viewport" content="width=device-width, initial-scale=1"');
  });

  it("学習時間のグラフ、セッションの要約、つまずき、自力で解けたところ、先生のひとこと、要確認を出す", async () => {
    const now = Date.now();
    const iso = (offsetMin: number) => new Date(now + offsetMin * 60_000).toISOString();
    const post = (body: unknown) =>
      req("/v1/sessions", {
        method: "POST",
        headers: { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    expect(
      (
        await post({
          id: "s1",
          started_at: iso(-40),
          ended_at: iso(-5),
          focus_minutes: 35,
          summary: "割合の文章題を 3 問",
          teacher_note: "今日は割合の問題を自力で解けました！",
          flags: ["学校で友だちとけんかしたと話していた"],
          problems: [
            { kind: "thinking", summary: "もとにする量を求める", solved_by_self: true },
            { kind: "reading", summary: "グラフから割合を読む", solved_by_self: false, hint_level_reached: 3 },
          ],
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await post({
          id: "s2",
          started_at: iso(-60 * 24 * 2),
          ended_at: iso(-60 * 24 * 2 + 20),
          focus_minutes: 20,
          summary: "漢字の書き取り",
        })
      ).status,
    ).toBe(200);

    const session = await loggedInCookie();
    const res = await req("/dashboard", { headers: { cookie: session } });
    const html = await res.text();
    expect(html).toContain("<svg");
    expect(html).toMatch(/aria-label="日ごとの学習時間：[^"]*35分/);
    expect(html).toContain("割合の文章題を 3 問");
    expect(html).toContain("漢字の書き取り");
    expect(html).toContain("つまずいたところ");
    expect(html).toContain("グラフから割合を読む");
    expect(html).toContain("自力で解けたところ");
    expect(html).toContain("もとにする量を求める");
    expect(html).toContain("今日は割合の問題を自力で解けました！");
    expect(html).toContain("要確認（1 件）");
    expect(html).toContain('class="session flagged"');
    expect(html).toContain("55 分"); // 最近 7 日の合計
    expect(html).toContain("発行する");
    // 外部のスクリプトは読まない
    expect(html).not.toMatch(/<script/i);
  });

  describe("週のまとめ", () => {
    const lastWeek = (day: number) => {
      const monday = Date.parse(`${jstWeekStart(Date.now())}T00:00:00Z`) - 7 * 86_400_000 - 9 * 3_600_000;
      return new Date(monday + day * 86_400_000 + 7 * 3_600_000).toISOString();
    };
    const post = (id: string, at: string) =>
      req("/v1/sessions", {
        method: "POST",
        headers: { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" },
        body: JSON.stringify({
          id, started_at: at, ended_at: at, focus_minutes: 20, summary: `${id}の要約`, flags: ["友だちとけんかした"],
          problems: [{ kind: "thinking", summary: "問題", solved_by_self: true }, { kind: "reading", summary: "問題2", solved_by_self: false, hint_level_reached: 2 }],
        }),
      });
    const open = (c: string, tasks: Promise<unknown>[]) =>
      app.request("/dashboard", { headers: { cookie: c } }, env(), {
        waitUntil: (t: Promise<unknown>) => tasks.push(t),
        passThroughOnException: () => {},
        props: {},
      } as unknown as ExecutionContext);
    const claudeOk = () =>
      Response.json({ stop_reason: "tool_use", content: [{ type: "tool_use", name: "record_weekly_summary", input: { grown: "割合で図をかいて考えました。", next_focus: "線分図に注目してみてください。" } }] });

    it("画面を待たせずに作り、次に開くと出る。要確認は別の枠のまま", async () => {
      await post("w1", lastWeek(1));
      await post("w2", lastWeek(2));
      const c = await loggedInCookie();
      fetchMock.mockResolvedValueOnce(claudeOk());
      const tasks: Promise<unknown>[] = [];
      const first = await (await open(c, tasks)).text();
      expect(first).toContain("先週のまとめを作っています");
      expect(tasks).toHaveLength(1);
      await Promise.all(tasks);

      const second = await (await open(c, tasks)).text();
      expect(second).toContain("割合で図をかいて考えました。");
      expect(second).toContain("線分図に注目してみてください。");
      expect(second).not.toContain("先週のまとめを作っています");
      // 週のまとめのカードに要確認を混ぜない
      const card = second.slice(second.indexOf('id="weekly"'), second.indexOf("日ごとの学習時間"));
      expect(card).not.toContain("けんか");
      expect(second).toContain("要確認（");
      // Google ログインの 1 回 + Claude の 1 回
      expect(fetchMock).toHaveBeenCalledTimes(2);
    });

    it("Claude に失敗してもダッシュボードが開く", async () => {
      vi.spyOn(console, "error").mockImplementation(() => {});
      await post("w1", lastWeek(1));
      await post("w2", lastWeek(2));
      const c = await loggedInCookie();
      fetchMock.mockRejectedValueOnce(new Error("network"));
      const tasks: Promise<unknown>[] = [];
      const res = await open(c, tasks);
      expect(res.status).toBe(200);
      await Promise.all(tasks);
      const again = await open(c, tasks);
      expect(again.status).toBe(200);
      const html = await again.text();
      expect(html).toContain("日ごとの学習時間");
      expect(html).not.toContain('id="weekly"');
      vi.restoreAllMocks();
    });

    it("過去の週も見られる", async () => {
      const db = d1.db();
      await db.batch([
        db.prepare("INSERT INTO weekly_summaries (child_id, week_start, status, grown, next_focus, claimed_at) VALUES ('default', '2026-10-19', 'ready', '古い週の伸び', '古い週の見どころ', '2026-10-26T00:00:00.000Z')"),
        db.prepare("INSERT INTO weekly_summaries (child_id, week_start, status, grown, next_focus, claimed_at) VALUES ('default', '2026-10-26', 'ready', '新しい週の伸び', '新しい週の見どころ', '2026-11-02T00:00:00.000Z')"),
      ]);
      const c = await loggedInCookie();
      const html = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(html.indexOf("新しい週の伸び")).toBeLessThan(html.indexOf("古い週の伸び"));
      expect(html).toContain("<details>");
      expect(html).toContain("10/19〜10/25のまとめ");
    });

    it("別の家族のまとめは見えない", async () => {
      const db = d1.db();
      await db.batch([
        db.prepare("INSERT INTO families (id, name) VALUES ('other', 'よその家')"),
        db.prepare("INSERT INTO children (id, family_id, nickname) VALUES ('other-child', 'other', 'よそ')"),
        db.prepare("INSERT INTO weekly_summaries (child_id, week_start, status, grown, next_focus, claimed_at) VALUES ('other-child', '2026-10-26', 'ready', 'よその伸び', 'よその見どころ', '2026-11-02T00:00:00.000Z')"),
      ]);
      const c = await loggedInCookie();
      expect(await (await req("/dashboard", { headers: { cookie: c } })).text()).not.toContain("よその伸び");
    });
  });

  describe("自力で解けた問題の変化", () => {
    it("週ごとの数を出し、点数やスコアを出さない。問題のないセッションでも崩れない", async () => {
      const at = new Date().toISOString();
      const problem = (solved: boolean, hint: number) => ({ kind: "thinking", summary: "問題", solved_by_self: solved, hint_level_reached: hint });
      const res = await req("/v1/sessions", {
        method: "POST",
        headers: { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" },
        body: JSON.stringify({ id: "g1", started_at: at, ended_at: at, focus_minutes: 10, problems: [problem(true, 0), problem(true, 2), problem(false, 4)] }),
      });
      expect(res.status).toBe(200);
      await req("/v1/sessions", {
        method: "POST",
        headers: { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" },
        body: JSON.stringify({ id: "g2", started_at: at, ended_at: at, focus_minutes: 10 }),
      });
      const c = await loggedInCookie();
      const html = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(html).toContain("自力で解けた問題の変化");
      expect(html).toContain("2問を自力で（全3問）・記録が少ない週");
      expect(html).toContain("記録なし");
      expect(html).toContain("まだ記録が少ない週");
      for (const bad of ["スコア", "順位", "集中力"]) expect(html).not.toContain(bad);
    });

    it("記録がなくても開ける", async () => {
      const c = await loggedInCookie();
      const res = await req("/dashboard", { headers: { cookie: c } });
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("自力で解けた問題の変化");
    });
  });

  describe("先生が覚えていること", () => {
    const auth = { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" };
    const putMemory = (category: string, items: string[]) =>
      req("/v1/memory", { method: "PUT", headers: auth, body: JSON.stringify({ category, items: items.map((content) => ({ content })) }) });
    const del = (fields: Record<string, string>, cookieValue: string, origin = "http://localhost") =>
      req("/dashboard/memories/delete", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", origin, cookie: cookieValue },
        body: new URLSearchParams(fields).toString(),
      });
    const list = async () => ((await (await req("/v1/memory", { headers: auth })).json()) as any).memories.map((m: any) => m.content);

    it("カテゴリごとに、短い言葉のまま見せる", async () => {
      await putMemory("likes", ["サッカー"]);
      await putMemory("events", ["週末に水族館に行った"]);
      await putMemory("weak_points", ["割合の文章題"]);
      const c = await loggedInCookie();
      const html = await (await req("/dashboard", { headers: { cookie: c } })).text();
      for (const text of ["好きなこと", "最近の出来事", "苦手な単元", "サッカー", "週末に水族館に行った", "割合の文章題"]) {
        expect(html).toContain(text);
      }
    });

    it("記憶がなくても崩れない", async () => {
      const c = await loggedInCookie();
      const html = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(html).toContain("まだ覚えていることはありません");
    });

    it("消すとアプリの同期でも消え、未送信の変更でも復活しない", async () => {
      await putMemory("likes", ["サッカー", "猫のミケ"]);
      const c = await loggedInCookie();
      const res = await del({ category: "likes", content: "猫のミケ" }, c);
      expect(res.status).toBe(303);
      expect(await list()).toEqual(["サッカー"]);
      await putMemory("likes", ["サッカー", "猫のミケ", "マイクラ"]);
      expect(await list()).toEqual(["サッカー", "マイクラ"]);
    });

    it("ログインしていなければ消さない。別のサイトからの POST も拒否する（CSRF）", async () => {
      await putMemory("likes", ["サッカー"]);
      expect((await del({ category: "likes", content: "サッカー" }, "")).status).toBe(303);
      const c = await loggedInCookie();
      expect((await del({ category: "likes", content: "サッカー" }, c, "https://evil.example")).status).toBe(403);
      expect(await list()).toEqual(["サッカー"]);
    });

    it("他の家族の記憶は、同じ言葉を送っても消せない", async () => {
      const db = d1.db();
      await db.batch([
        db.prepare("INSERT INTO families (id, name) VALUES ('other', 'よその家')"),
        db.prepare("INSERT INTO children (id, family_id, nickname) VALUES ('other-child', 'other', 'よそ')"),
        db.prepare("INSERT INTO memories (id, child_id, category, content, updated_at) VALUES ('m', 'other-child', 'likes', 'よその記憶', '2026-11-03T00:00:00.000Z')"),
      ]);
      const c = await loggedInCookie();
      const html = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(html).not.toContain("よその記憶");
      expect((await del({ category: "likes", content: "よその記憶" }, c)).status).toBe(303);
      expect(await db.prepare("SELECT id FROM memories WHERE id = 'm'").first()).toEqual({ id: "m" });
      expect((await db.prepare("SELECT count(*) AS n FROM memory_deletions").first<{ n: number }>())!.n).toBe(0);
    });

    it("カテゴリが違えば 400", async () => {
      const c = await loggedInCookie();
      expect((await del({ category: "secret", content: "x" }, c)).status).toBe(400);
    });
  });

  describe("親の伝言", () => {
    const send = (fields: Record<string, string>, cookieValue: string, headers: Record<string, string> = {}) =>
      req("/dashboard/messages", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded", origin: "http://localhost", cookie: cookieValue, ...headers },
        body: new URLSearchParams(fields).toString(),
      });
    const rows = async () =>
      (await d1.db().prepare("SELECT * FROM parent_messages ORDER BY created_at").all<any>()).results;

    it("書いた伝言を保存し、まだ伝えていないと出す。アプリに渡り、伝えたら表示が変わる", async () => {
      const c = await loggedInCookie();
      const res = await send({ body: "割合がんばったね\n応援してるよ", sender: "お母さん" }, c);
      expect(res.status).toBe(303);
      const [row] = await rows();
      expect(row).toMatchObject({ child_id: "default", sender_label: "お母さん", body: "割合がんばったね 応援してるよ", delivered_at: null });

      const before = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(before).toContain("割合がんばったね 応援してるよ");
      expect(before).toContain("まだ伝えていません");

      const auth = { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" };
      const { messages } = (await (await req("/v1/messages", { headers: auth })).json()) as any;
      expect(messages.map((m: any) => m.id)).toEqual([row.id]);
      await req(`/v1/messages/${row.id}/delivered`, { method: "POST", headers: auth, body: "{}" });

      const after = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(after).not.toContain("まだ伝えていません");
      expect(after).toContain("に伝えました");
    });

    it("呼び方が空なら「おうちの人」にする（先生に推測させない）", async () => {
      const c = await loggedInCookie();
      await send({ body: "がんばってね", sender: "  " }, c);
      expect((await rows())[0].sender_label).toBe("おうちの人");
    });

    it("空や長すぎる伝言は保存せず、書いた内容を残して理由を出す", async () => {
      const c = await loggedInCookie();
      const empty = await send({ body: "   ", sender: "パパ" }, c);
      expect(empty.status).toBe(400);
      expect(await empty.text()).toContain("伝言を書いてください");

      const long = await send({ body: "あ".repeat(201), sender: "パパ" }, c);
      expect(long.status).toBe(400);
      const html = await long.text();
      expect(html).toContain("200 文字まで");
      expect(html).toContain("あ".repeat(201));

      const longSender = await send({ body: "がんばって", sender: "あ".repeat(13) }, c);
      expect(longSender.status).toBe(400);
      expect(await rows()).toEqual([]);
    });

    it("たまりすぎたら新しい伝言は受け付けない", async () => {
      const c = await loggedInCookie();
      for (let i = 0; i < 10; i++) expect((await send({ body: `伝言${i}`, sender: "" }, c)).status).toBe(303);
      expect((await send({ body: "もう1つ", sender: "" }, c)).status).toBe(400);
      expect(await rows()).toHaveLength(10);
    });

    it("ログインしていなければ保存しない。別のサイトからの POST も拒否する（CSRF）", async () => {
      const anon = await send({ body: "がんばって", sender: "" }, "");
      expect(anon.status).toBe(303);
      const c = await loggedInCookie();
      const cross = await send({ body: "がんばって", sender: "" }, c, { origin: "https://evil.example.com" });
      expect(cross.status).toBe(403);
      expect(await rows()).toEqual([]);
    });

    it("伝言はエスケープして出す", async () => {
      const c = await loggedInCookie();
      await send({ body: "<script>alert(1)</script>", sender: "" }, c);
      const html = await (await req("/dashboard", { headers: { cookie: c } })).text();
      expect(html).not.toContain("<script>alert(1)</script>");
      expect(html).toContain("&lt;script&gt;");
    });

    it("別の家族の伝言は見えない", async () => {
      const db = d1.db();
      await db.batch([
        db.prepare("INSERT INTO families (id, name) VALUES ('other', 'よその家')"),
        db.prepare("INSERT INTO children (id, family_id, nickname) VALUES ('other-child', 'other', 'よそ')"),
        db.prepare("INSERT INTO parent_messages (id, child_id, sender_label, body, created_at) VALUES ('x', 'other-child', 'よそ', 'よその伝言', '2026-11-03T00:00:00.000Z')"),
      ]);
      const c = await loggedInCookie();
      expect(await (await req("/dashboard", { headers: { cookie: c } })).text()).not.toContain("よその伝言");
    });
  });

  describe("今夜の声かけ", () => {
    const post = (body: unknown) =>
      req("/v1/sessions", {
        method: "POST",
        headers: { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    const at = (daysAgo: number) => new Date(Date.now() - daysAgo * 86_400_000).toISOString();
    const dashboardHtml = async () => {
      const c = await loggedInCookie();
      return (await req("/dashboard", { headers: { cookie: c } })).text();
    };

    it("今日のセッションなら一番上に「今夜の声かけ」を出す", async () => {
      await post({ id: "s1", started_at: at(0), ended_at: at(0), focus_minutes: 10, summary: "要約", flags: ["確認してほしいこと"], parent_prompt: "「図はどうかいたの？」と聞いてみてください" });
      const html = await dashboardHtml();
      expect(html).toContain("今夜の声かけ");
      expect(html).toContain("「図はどうかいたの？」と聞いてみてください");
      // 要確認やグラフより上
      expect(html.indexOf("今夜の声かけ")).toBeLessThan(html.indexOf("要確認（"));
      expect(html.indexOf("今夜の声かけ")).toBeLessThan(html.indexOf("日ごとの学習時間"));
    });

    it("昨日より前のセッションなら「今夜」と言わず、いつの勉強かを書く", async () => {
      await post({ id: "s1", started_at: at(3), ended_at: at(3), focus_minutes: 10, parent_prompt: "「図はどうかいたの？」と聞いてみてください" });
      const html = await dashboardHtml();
      expect(html).not.toContain("今夜の声かけ");
      expect(html).toContain("の勉強から、声かけ");
    });

    it("最新のセッションに声かけがなければ、カードごと出さず古い声かけも出さない", async () => {
      await post({ id: "old", started_at: at(2), ended_at: at(2), focus_minutes: 10, parent_prompt: "古い声かけ" });
      await post({ id: "new", started_at: at(0), ended_at: at(0), focus_minutes: 10 });
      const html = await dashboardHtml();
      expect(html).not.toContain("今夜の声かけ");
      expect(html).not.toContain("古い声かけ");
      expect(html).toContain("日ごとの学習時間");
    });

    it("セッションがなくても崩れない", async () => {
      const html = await dashboardHtml();
      expect(html).not.toContain("声かけ");
      expect(html).toContain("まだ記録がありません");
    });
  });

  it("文字はエスケープして出す", async () => {
    await req("/v1/sessions", {
      method: "POST",
      headers: { Authorization: "Bearer bootstrap-secret", "content-type": "application/json" },
      body: JSON.stringify({
        id: "x",
        started_at: new Date().toISOString(),
        ended_at: new Date().toISOString(),
        focus_minutes: 1,
        summary: "<img src=x onerror=alert(1)>",
      }),
    });
    const html = await (await req("/dashboard", { headers: { cookie: await loggedInCookie() } })).text();
    expect(html).not.toContain("<img src=x");
    expect(html).toContain("&lt;img src=x");
  });

  it("DEV_AUTH_BYPASS=1 は localhost のときだけログインを省く", async () => {
    const e = env({ DEV_AUTH_BYPASS: "1" });
    expect(await (await req("http://localhost/dashboard", {}, e)).text()).toContain("学習のようす");
    expect(await (await req("https://teacher.example.workers.dev/dashboard", {}, e)).text()).toContain(
      "Google でログイン",
    );
    expect(await (await req("http://localhost/dashboard")).text()).toContain("Google でログイン");
  });
});
