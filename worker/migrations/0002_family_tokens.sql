-- 親のダッシュボードで発行する家族トークン（#29）
-- トークンそのものは保存しない。SHA-256 の 16 進文字列だけを持つ
-- 再発行すると、その家族の古いトークンは消す（1 家族 1 トークン）

CREATE TABLE family_tokens (
  token_hash TEXT PRIMARY KEY,
  family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX family_tokens_family ON family_tokens(family_id);
