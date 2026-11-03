// 家族トークンの認証。
// いまは secret の FAMILY_TOKEN と比べるだけ。#29 で D1 発行のトークンに置き換える予定なので、
// 判定はこの関数 1 つにまとめておく。

export async function isAuthorized(
  authorizationHeader: string | undefined | null,
  expectedToken: string | undefined,
): Promise<boolean> {
  // secret が未設定なら必ず拒否する（"" と "" が一致して通ってしまうのを防ぐ）
  if (!expectedToken) return false;
  const match = /^Bearer\s+(.+)$/i.exec(authorizationHeader ?? "");
  if (!match) return false;
  return timingSafeEqualString(match[1].trim(), expectedToken);
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
