-- spec §5 のデータモデル。保存するのは文字の情報だけ（写真・音声の列は作らない）
-- 時刻はすべて UTC の ISO 8601 文字列（例 2026-11-03T10:00:00.000Z）。文字列のまま大小比較できる

CREATE TABLE families (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE parents (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  email TEXT NOT NULL UNIQUE
);

CREATE TABLE children (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  nickname TEXT NOT NULL,
  grade INTEGER,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX children_family ON children(family_id);

-- id はアプリが作る UUID。同じ id で送り直すと上書きになる（同期をやり直しても重複しない）
-- flags は「要確認」メモの JSON 配列（文字列の配列）
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
  started_at TEXT NOT NULL,
  ended_at TEXT NOT NULL,
  focus_minutes INTEGER NOT NULL DEFAULT 0 CHECK (focus_minutes >= 0),
  summary TEXT NOT NULL DEFAULT '',
  teacher_note TEXT NOT NULL DEFAULT '',
  flags TEXT NOT NULL DEFAULT '[]',
  updated_at TEXT NOT NULL
);
CREATE INDEX sessions_child_started ON sessions(child_id, started_at);
CREATE INDEX sessions_updated ON sessions(updated_at);

-- kind は spec §3② の問題の種類。hint_level_reached は到達したヒントの段階（0 = ヒントなし、最大 4）
CREATE TABLE problems (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('reading', 'thinking', 'writing')),
  summary TEXT NOT NULL,
  solved_by_self INTEGER NOT NULL CHECK (solved_by_self IN (0, 1)),
  hint_level_reached INTEGER NOT NULL DEFAULT 0 CHECK (hint_level_reached BETWEEN 0 AND 4),
  created_at TEXT NOT NULL
);
CREATE INDEX problems_session ON problems(session_id);

CREATE TABLE memories (
  id TEXT PRIMARY KEY,
  child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
  category TEXT NOT NULL CHECK (category IN ('likes', 'events', 'weak_points')),
  content TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX memories_child_category ON memories(child_id, category);

-- 11/8 時点は 1 家庭だけ。secret の FAMILY_TOKEN はこの家族に対応する（src/auth.ts）
INSERT INTO families (id, name) VALUES ('default', 'わが家');
INSERT INTO children (id, family_id, nickname, grade) VALUES ('default', 'default', 'こども', 5);
