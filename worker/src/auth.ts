// 家族トークンの認証。
// トークンから「どの家族か」を解決する処理はこのファイルの resolveFamily 1 つにまとめる。
// 1. secret の FAMILY_TOKEN（最初の 1 台をつなぐための予備）→ マイグレーションで作る家族 'default'
// 2. ダッシュボードで発行して D1 に保存したトークン（SHA-256 で照合）→ その家族

import { familyIdForToken } from "./tokens";

// FAMILY_TOKEN に対応する家族（migrations/0001_init.sql で作成）
export const BOOTSTRAP_FAMILY_ID = "default";

export async function resolveFamily(
  authorizationHeader: string | undefined | null,
  env: { FAMILY_TOKEN?: string; DB?: D1Database },
): Promise<string | null> {
  const token = bearerToken(authorizationHeader);
  if (!token) return null;
  // secret が未設定なら比べない（"" と "" が一致して通ってしまうのを防ぐ）
  if (env.FAMILY_TOKEN && (await timingSafeEqualString(token, env.FAMILY_TOKEN))) {
    return BOOTSTRAP_FAMILY_ID;
  }
  // D1 は照合用のハッシュで引く（インデックスの検索なので、時間差から中身は推測できない）
  return env.DB ? familyIdForToken(env.DB, token) : null;
}

function bearerToken(header: string | undefined | null): string | null {
  const match = /^Bearer\s+(.+)$/i.exec(header ?? "");
  const token = match?.[1].trim();
  return token ? token : null;
}

// 定数時間比較。両方を SHA-256 にしてから比べるので、長さの違いも漏れない。
// crypto.subtle.timingSafeEqual は Workers 専用で Node のテストでは使えないため、自前で XOR する。
async function timingSafeEqualString(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(ha);
  const vb = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}
