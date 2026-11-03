import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app, { type Env } from "../src/index";
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
