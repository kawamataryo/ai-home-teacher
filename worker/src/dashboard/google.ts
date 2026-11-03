// Google の OAuth 2.0（Authorization Code ＋ PKCE）と id_token の検証。
// エンドポイントは 2026-11-03 に https://developers.google.com/identity/openid-connect/openid-connect で確認。
// id_token はトークンエンドポイントから TLS で直接受け取るので、署名の検証は省いてよい（同ページの記載）。
// その代わりに iss / aud / exp / nonce / email_verified を必ず確かめる。

import { base64url } from "../tokens";

export const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];

export function randomString(bytes = 32): string {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function pkceChallenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

export function authorizationUrl(p: {
  clientId: string;
  redirectUri: string;
  state: string;
  nonce: string;
  codeChallenge: string;
}): string {
  const q = new URLSearchParams({
    response_type: "code",
    client_id: p.clientId,
    redirect_uri: p.redirectUri,
    scope: "openid email",
    state: p.state,
    nonce: p.nonce,
    code_challenge: p.codeChallenge,
    code_challenge_method: "S256",
    prompt: "select_account",
  });
  return `${GOOGLE_AUTH_URL}?${q}`;
}

// 認可コードを id_token に換えて、確かめたメールアドレス（小文字）を返す。だめなら null
export async function exchangeCodeForEmail(p: {
  code: string;
  codeVerifier: string;
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  nonce: string;
}): Promise<string | null> {
  let res: Response;
  try {
    res = await fetch(GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code: p.code,
        code_verifier: p.codeVerifier,
        client_id: p.clientId,
        client_secret: p.clientSecret,
        redirect_uri: p.redirectUri,
      }),
    });
  } catch {
    return null;
  }
  if (!res.ok) return null;
  const body = (await res.json().catch(() => null)) as { id_token?: unknown } | null;
  if (typeof body?.id_token !== "string") return null;

  const claims = decodeJwtPayload(body.id_token);
  if (!claims) return null;
  const now = Math.floor(Date.now() / 1000);
  if (!GOOGLE_ISSUERS.includes(claims.iss as string)) return null;
  if (claims.aud !== p.clientId) return null;
  if (typeof claims.exp !== "number" || claims.exp < now) return null;
  if (claims.nonce !== p.nonce) return null;
  if (claims.email_verified !== true) return null;
  if (typeof claims.email !== "string" || !claims.email) return null;
  return claims.email.toLowerCase();
}

function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const part = jwt.split(".")[1];
  if (!part) return null;
  try {
    const bin = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
    const json = new TextDecoder().decode(Uint8Array.from(bin, (ch) => ch.charCodeAt(0)));
    const v: unknown = JSON.parse(json);
    return v && typeof v === "object" ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export function isAllowedEmail(email: string, allowlist: string | undefined): boolean {
  const allowed = (allowlist ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return allowed.includes(email.toLowerCase());
}
