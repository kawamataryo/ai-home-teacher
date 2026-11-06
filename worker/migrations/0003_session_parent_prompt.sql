-- 今夜の声かけ（#158）。先生が親に提案する、その日の夜に子どもへかける一言
-- 古いアプリから項目なしで送られても同期が壊れないよう、既定は空文字にする
ALTER TABLE sessions ADD COLUMN parent_prompt TEXT NOT NULL DEFAULT '';
