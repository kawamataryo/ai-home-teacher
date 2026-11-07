-- 親が消した記憶の印（#160）。端末に未送信の変更があると PUT /v1/memory の丸ごと入れ替えで復活するので、これと照らして取り除く
-- 消した言葉そのものは残さず、正規化した文の SHA-256 だけを持つ
CREATE TABLE memory_deletions (
  child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
  category TEXT NOT NULL CHECK (category IN ('likes', 'events', 'weak_points')),
  content_hash TEXT NOT NULL,
  deleted_at TEXT NOT NULL,
  PRIMARY KEY (child_id, category, content_hash)
);
