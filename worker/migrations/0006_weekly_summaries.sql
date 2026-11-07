-- 週のまとめ（#162）。週と子どもごとに 1 件。保存するのは文字だけ
-- status: pending（作っている） / ready（できた） / failed（作れなかった）
-- 呼ぶ前に行を確保するので、同じ週に Claude を重ねて呼ばない。attempts は呼んだ回数
CREATE TABLE weekly_summaries (
  child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
  week_start TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'failed')),
  grown TEXT NOT NULL DEFAULT '',
  next_focus TEXT NOT NULL DEFAULT '',
  attempts INTEGER NOT NULL DEFAULT 1,
  claimed_at TEXT NOT NULL,
  PRIMARY KEY (child_id, week_start)
);
