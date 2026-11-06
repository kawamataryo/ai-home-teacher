-- 親の伝言（#159）。親がダッシュボードで書き、次の勉強の始まりに先生が子どもへ伝える
-- 記憶（memories）は入れ替わるカテゴリの情報で、伝言は一度伝えたら終わりなので、テーブルを分ける
-- delivered_at は先生が話し終えた時刻。NULL の間はアプリが取ってきて伝える
CREATE TABLE parent_messages (
  id TEXT PRIMARY KEY,
  child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
  sender_label TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  delivered_at TEXT
);
CREATE INDEX parent_messages_child_created ON parent_messages(child_id, created_at);
