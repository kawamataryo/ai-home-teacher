-- ダッシュボードの見た目を確かめるためのサンプルデータ（ローカルの D1 専用。本番には流さない）
--   npx wrangler d1 migrations apply DB --local
--   npx wrangler d1 execute DB --local --file seed/sample.sql
-- 日付は実行した日を基準にする（JST の夕方 16 時台 = UTC 7 時台）。何度流しても同じ結果になる

DELETE FROM problems WHERE session_id LIKE 'sample-%';
DELETE FROM sessions WHERE id LIKE 'sample-%';
DELETE FROM memories WHERE id LIKE 'sample-%';
UPDATE children SET nickname = 'たろう', grade = 5 WHERE id = 'default';

INSERT INTO sessions (id, child_id, started_at, ended_at, focus_minutes, summary, teacher_note, flags, updated_at) VALUES
('sample-0', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now'), strftime('%Y-%m-%dT07:42:00.000Z', 'now'), 38,
 '割合の文章題を 3 問。もとにする量を求める問題で、線分図を使って考えた。',
 '今日は割合の問題を自力で解けました！線分図の使い方がどんどん上手になっています。',
 '["学校で友だちとけんかしたと話していました。様子を聞いてあげてください"]', strftime('%Y-%m-%dT07:43:00.000Z', 'now')),
('sample-1', 'default', strftime('%Y-%m-%dT07:10:00.000Z', 'now', '-1 day'), strftime('%Y-%m-%dT07:35:00.000Z', 'now', '-1 day'), 25,
 '社会の資料の読み取り。米の生産量のグラフから変化を説明した。',
 'グラフの読み取りは、目盛りを確かめてから答えられるようになってきました。', '[]', strftime('%Y-%m-%dT07:36:00.000Z', 'now', '-1 day')),
('sample-2', 'default', strftime('%Y-%m-%dT06:30:00.000Z', 'now', '-2 day'), strftime('%Y-%m-%dT07:20:00.000Z', 'now', '-2 day'), 45,
 '作文「夏休みの思い出」の構成メモを作り、書き出しを書いた。',
 '書きたいことを 3 つにしぼれたのがよかったです。', '[]', strftime('%Y-%m-%dT07:21:00.000Z', 'now', '-2 day')),
('sample-3', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now', '-4 day'), strftime('%Y-%m-%dT07:20:00.000Z', 'now', '-4 day'), 15,
 '分数のたし算・ひき算（通分）。', '', '["「疲れた」と何度か言っていました"]', strftime('%Y-%m-%dT07:21:00.000Z', 'now', '-4 day')),
('sample-4', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now', '-5 day'), strftime('%Y-%m-%dT07:30:00.000Z', 'now', '-5 day'), 30,
 '小数のかけ算の計算練習。', '筆算の位をそろえるのが正確になりました。', '[]', strftime('%Y-%m-%dT07:31:00.000Z', 'now', '-5 day')),
('sample-5', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now', '-7 day'), strftime('%Y-%m-%dT07:25:00.000Z', 'now', '-7 day'), 20,
 '理科：ふりこの実験のまとめ。', '', '[]', strftime('%Y-%m-%dT07:26:00.000Z', 'now', '-7 day')),
('sample-6', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now', '-8 day'), strftime('%Y-%m-%dT07:40:00.000Z', 'now', '-8 day'), 35,
 '割合の基本（くらべる量・もとにする量）。', '', '[]', strftime('%Y-%m-%dT07:41:00.000Z', 'now', '-8 day')),
('sample-7', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now', '-10 day'), strftime('%Y-%m-%dT07:20:00.000Z', 'now', '-10 day'), 18,
 '漢字の書き取り。', '', '[]', strftime('%Y-%m-%dT07:21:00.000Z', 'now', '-10 day')),
('sample-8', 'default', strftime('%Y-%m-%dT07:00:00.000Z', 'now', '-12 day'), strftime('%Y-%m-%dT07:30:00.000Z', 'now', '-12 day'), 28,
 '面積の求め方（台形）。', '', '[]', strftime('%Y-%m-%dT07:31:00.000Z', 'now', '-12 day'));

INSERT INTO problems (id, session_id, kind, summary, solved_by_self, hint_level_reached, created_at) VALUES
('sample-p0a', 'sample-0', 'thinking', '定価の 30% 引きの値段を求める', 1, 0, strftime('%Y-%m-%dT07:05:00.000Z', 'now')),
('sample-p0b', 'sample-0', 'thinking', 'もとにする量を求める（線分図）', 1, 1, strftime('%Y-%m-%dT07:15:00.000Z', 'now')),
('sample-p0c', 'sample-0', 'thinking', '割合が 1 を超える場合の文章題', 0, 3, strftime('%Y-%m-%dT07:30:00.000Z', 'now')),
('sample-p1a', 'sample-1', 'reading', '米の生産量が一番多い年を読み取る', 1, 0, strftime('%Y-%m-%dT07:12:00.000Z', 'now', '-1 day')),
('sample-p1b', 'sample-1', 'reading', '2 つのグラフを組み合わせて理由を説明する', 0, 2, strftime('%Y-%m-%dT07:25:00.000Z', 'now', '-1 day')),
('sample-p2a', 'sample-2', 'writing', '作文の構成メモ（はじめ・なか・おわり）', 1, 1, strftime('%Y-%m-%dT06:40:00.000Z', 'now', '-2 day')),
('sample-p3a', 'sample-3', 'thinking', '分母がちがう分数のひき算', 0, 4, strftime('%Y-%m-%dT07:05:00.000Z', 'now', '-4 day'));

INSERT INTO memories (id, child_id, category, content, updated_at) VALUES
('sample-m1', 'default', 'likes', 'サッカー（ポジションはキーパー）', strftime('%Y-%m-%dT07:43:00.000Z', 'now')),
('sample-m2', 'default', 'events', '週末に運動会がある', strftime('%Y-%m-%dT07:43:00.000Z', 'now')),
('sample-m3', 'default', 'weak_points', '割合（もとにする量）', strftime('%Y-%m-%dT07:43:00.000Z', 'now'));

-- 今夜の声かけ（#158）。いちばん新しいセッションにだけ入れる
UPDATE sessions SET parent_prompt = '「もとにする量をどうやって見つけたの？」と聞いてみてください' WHERE id = 'sample-0';
-- 「今夜の声かけ」と出るように、いちばん新しいセッションをさっき終わったことにする
UPDATE sessions SET started_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-45 minutes'), ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-3 minutes') WHERE id = 'sample-0';
