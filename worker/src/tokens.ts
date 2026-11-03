// D1 に保存する家族トークン（ダッシュボードで発行・再発行する）。
// トークンは 32 バイトの乱数なので、保存はソルトなしの SHA-256 で十分（総当たりできない）。

export async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// 新しいトークンを発行し、その家族の古いトークンは消す。平文を返すのはこのときだけ
export async function issueFamilyToken(db: D1Database, familyId: string): Promise<string> {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = "ht_" + base64url(bytes);
  await db.batch([
    db.prepare("DELETE FROM family_tokens WHERE family_id = ?").bind(familyId),
    db
      .prepare("INSERT INTO family_tokens (token_hash, family_id) VALUES (?, ?)")
      .bind(await sha256Hex(token), familyId),
  ]);
  return token;
}

export async function familyIdForToken(db: D1Database, token: string): Promise<string | null> {
  const row = await db
    .prepare("SELECT family_id FROM family_tokens WHERE token_hash = ?")
    .bind(await sha256Hex(token))
    .first<{ family_id: string }>();
  return row?.family_id ?? null;
}

export async function currentTokenIssuedAt(db: D1Database, familyId: string): Promise<string | null> {
  const row = await db
    .prepare("SELECT created_at FROM family_tokens WHERE family_id = ? ORDER BY created_at DESC LIMIT 1")
    .bind(familyId)
    .first<{ created_at: string }>();
  return row?.created_at ?? null;
}

export function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
