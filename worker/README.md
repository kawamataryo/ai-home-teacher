# Worker（中継 API ＋ 同期 API ＋ 親のダッシュボード）

iPad アプリの API キーを守るための Cloudflare Worker。アプリは家族トークンでこの Worker を呼び、Worker が各 API に中継する。セッションの要約と記憶は D1 に保存する（文字の情報だけ。写真・音声は保存しない）。親は `/dashboard` で学習のようすを見て、家族トークンを発行できる。

| エンドポイント | 中継先 | 内容 |
| --- | --- | --- |
| `POST /v1/claude` | Anthropic Messages API | body をそのまま転送。`stream: true` なら SSE をそのまま流す。`model` は `claude-haiku-5-5` / `claude-sonnet-5-5` / `claude-opus-5-5` のみ |
| `POST /v1/tts` | ElevenLabs `stream/with-timestamps` | body は `{ text, voice_id? }`。モデルは `eleven_flash_v2_5`。音声（base64）と文字タイミングの JSON をそのまま流す |
| `POST /v1/decide` | TypeSafe AI（Jev）`/v1/systemone` | body をそのまま転送 |
| `POST /v1/sessions` | D1 | 終わったセッションを保存（同じ `id` なら上書き） |
| `GET /v1/sessions` | D1 | セッション一覧 |
| `GET /v1/memory` / `PUT /v1/memory` | D1 | 記憶の一覧 / カテゴリごとの入れ替え |
| `GET /v1/messages` / `POST /v1/messages/:id/delivered` | D1 | まだ伝えていない親の伝言 / 伝えた印 |

`/v1/*` には `Authorization: Bearer <家族トークン>` が必要（ない、または違うと 401）。データはトークンに対応する家族の分だけ読み書きできる。家族トークンは次のどちらか。

- ダッシュボードで発行したトークン（`ht_...`）。D1 には SHA-256 のハッシュだけを保存し、再発行すると古いものは使えなくなる
- secret の `FAMILY_TOKEN`（最初の 1 台をつなぐための予備）。マイグレーションで作る家族 `default`（子ども `default`）に対応する

## 同期 API

時刻はすべて ISO 8601（タイムゾーン付き）で送る。保存時に UTC（`...Z`）に正規化して返す。
入力は厳密に検証し、知らないフィールド（`image_base64` など）があると 400 を返す。

エラーはすべて `{ "error": "..." }`。検証エラーは `{ "error": "invalid request", "issues": [{ "path": "problems.0.kind", "message": "..." }] }`（400）。

### `POST /v1/sessions`

```json
{
  "id": "6F1C2E1A-0000-4000-8000-000000000001",
  "child_id": "default",
  "started_at": "2026-11-03T16:00:00+09:00",
  "ended_at": "2026-11-03T16:40:00+09:00",
  "focus_minutes": 35,
  "summary": "割合の文章題を 3 問やった",
  "teacher_note": "今日は割合の問題を自力で解けました！",
  "parent_prompt": "「もとにする量をどうやって見つけたの？」と聞いてみてください",
  "flags": ["学校で友だちとけんかしたと話していた"],
  "problems": [
    { "kind": "thinking", "summary": "割合：もとにする量を求める", "solved_by_self": true, "hint_level_reached": 1, "created_at": "2026-11-03T16:05:00+09:00" }
  ]
}
```

| フィールド | 型 | 必須 | 内容 |
| --- | --- | --- | --- |
| `id` | string | ○ | アプリが作る UUID（英数字・`-`・`_`、64 文字まで）。同じ id で送り直すと上書き |
| `child_id` | string | | 省略すると家族の最初の子ども |
| `started_at` / `ended_at` | ISO 8601 | ○ | `ended_at >= started_at` |
| `focus_minutes` | int | ○ | 0〜1440 |
| `summary` | string | | 4000 文字まで。既定 `""` |
| `teacher_note` | string | | 先生のひとこと。1000 文字まで。既定 `""` |
| `parent_prompt` | string | | 今夜の声かけ（親が子どもにかける一言の提案）。500 文字まで。既定 `""`（古いアプリは送らない） |
| `flags` | string[] | | 「要確認」メモ。20 件・各 500 文字まで。既定 `[]` |
| `problems[].kind` | `reading` / `thinking` / `writing` | ○ | spec §3② の問題の種類 |
| `problems[].summary` | string | ○ | 1〜1000 文字 |
| `problems[].solved_by_self` | boolean | ○ | 自力で解けたか |
| `problems[].hint_level_reached` | int | | 到達したヒントの段階 0〜4（0 = ヒントなし）。既定 0 |
| `problems[].created_at` | ISO 8601 | | 省略すると `started_at` |

問題は送るたびに丸ごと入れ替える（100 件まで）。別の家族のセッション id や `child_id` は 404。

レスポンス（200）:

```json
{
  "session": {
    "id": "6F1C2E1A-0000-4000-8000-000000000001",
    "child_id": "default",
    "started_at": "2026-11-03T07:00:00.000Z",
    "ended_at": "2026-11-03T07:40:00.000Z",
    "focus_minutes": 35,
    "summary": "割合の文章題を 3 問やった",
    "teacher_note": "今日は割合の問題を自力で解けました！",
    "parent_prompt": "「もとにする量をどうやって見つけたの？」と聞いてみてください",
    "flags": ["学校で友だちとけんかしたと話していた"],
    "updated_at": "2026-11-03T07:41:02.123Z",
    "problems": [
      { "id": "c1d2…", "kind": "thinking", "summary": "割合：もとにする量を求める", "solved_by_self": true, "hint_level_reached": 1, "created_at": "2026-11-03T07:05:00.000Z" }
    ]
  }
}
```

### `GET /v1/sessions?since=&limit=&child_id=&order=`

- `since`（任意, ISO 8601）: サーバーが保存した時刻 `updated_at` がこれ以降のものだけ
- `limit`（任意, 1〜200, 既定 50）
- `child_id`（任意）
- `order`（任意, `started` / `updated`, 既定 `started`）: `started` は `started_at` の新しい順、`updated` は `updated_at` の古い順

既定は `started_at` の新しい順。アプリの同期は `order=updated&limit=200` で取り、200 件返ってきたら最後の `updated_at` を次の `since` にしてページ送りする（境目の重複は id で上書きするので問題ない）。レスポンスは `{ "sessions": [<session と同じ形>], "server_time": "2026-11-03T07:45:00.000Z" }`。次の同期では `server_time` を `since` に渡せば、それ以降に保存されたものが取れる。

### `GET /v1/memory?category=&child_id=`

```json
{
  "memories": [
    { "id": "…", "child_id": "default", "category": "likes", "content": "サッカー", "updated_at": "2026-11-03T07:41:02.123Z" }
  ]
}
```

`category` は `likes`（好きなこと）/ `events`（最近の出来事）/ `weak_points`（苦手な単元）。カテゴリ順、保存した順。

### `GET /v1/messages` / `POST /v1/messages/:id/delivered`

親の伝言（#159）。`GET` はまだ伝えていない伝言を古い順に返す（`{ "messages": [{ "id", "child_id", "sender_label", "body", "created_at", "delivered_at": null }] }`）。先生が話し終えたら `POST /v1/messages/:id/delivered`（本文 `{ "delivered_at": "ISO 8601" }`、省略すると受け取った時刻）。何度送っても最初の時刻のまま。別の家族の id は 404。

### `PUT /v1/memory`

```json
{ "category": "likes", "items": [{ "content": "サッカー" }, { "content": "猫のミケ" }], "child_id": "default" }
```

そのカテゴリの記憶を `items` で丸ごと入れ替える（`items: []` で全部消す。100 件・各 500 文字まで）。`child_id` は省略可。レスポンスは入れ替えたカテゴリの `{ "memories": [...] }`。

## 親のダッシュボード（`/dashboard`）

- Google ログイン（OAuth 2.0 Authorization Code ＋ PKCE）。id_token の `iss` / `aud` / `exp` / `nonce` / `email_verified` を確かめ、`PARENT_EMAILS` にあるメールだけ通す
- ログイン後は `SESSION_SECRET` で署名した Cookie（HttpOnly・Secure・SameSite=Lax、7 日）。許可リストから外すとすぐ見られなくなる
- 表示: 要確認メモ、日ごとの学習時間（直近 14 日、JST、インライン SVG）、セッションごとの要約・つまずいたところ・自力で解けたところ・先生のひとこと
- 家族トークンの発行・再発行（表示は発行した直後の 1 回だけ）。フォームの POST は同じオリジンからだけ受け付ける

スマホ幅の画面: [`docs/screenshots/dashboard-mobile.png`](../docs/screenshots/dashboard-mobile.png)（全体は `dashboard-mobile-full.png`）

### Google OAuth クライアントの作り方

1. [Google Cloud Console](https://console.cloud.google.com/) でプロジェクトを作る（既存のものでもよい）
2. 「Google Auth Platform」→「Branding」でアプリ名とサポートメールを入れる。「Audience」はテスト中なら「External ＋ Testing」にして、テストユーザーに親のメールを追加する
3. 「Clients」→「Create client」→ 種類は「Web application」
4. 「Authorized redirect URIs」に次を追加する
   - 本番: `https://<worker 名>.<アカウントのサブドメイン>.workers.dev/dashboard/auth/callback`（カスタムドメインならそのドメイン）
   - ローカル: `http://localhost:8787/dashboard/auth/callback`
5. 表示されたクライアント ID とシークレットを `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` にする。スコープは `openid email` だけを使う

### ローカルで画面だけ確かめる

```sh
npx wrangler d1 migrations apply DB --local
npx wrangler d1 execute DB --local --file seed/sample.sql   # サンプルデータ
echo 'DEV_AUTH_BYPASS=1' >> .dev.vars                       # localhost だけログインを省く
npm run dev                                                 # http://localhost:8787/dashboard
```

`DEV_AUTH_BYPASS` は `.dev.vars` にだけ書く。値が `1` でも、ホストが `localhost` / `127.0.0.1` 以外ならログインを省かない。

## セットアップ

```sh
cd worker
npm install
cp .dev.vars.example .dev.vars              # 値を入れる（.dev.vars は gitignore 済み）
npx wrangler d1 migrations apply DB --local # ローカルの D1（.wrangler/ に保存）にテーブルを作る
npm run dev                                 # http://localhost:8787
```

`wrangler.jsonc` の `vars.ELEVENLABS_VOICE_ID` を、使う声の voice ID に置き換える。

## 本番の D1

```sh
npx wrangler d1 create ai-home-teacher
```

出力された `database_id` を `wrangler.jsonc` の `d1_databases[0].database_id`（`REPLACE_WITH_DATABASE_ID`）に書く（秘密情報ではない）。そのあとテーブルを作る:

```sh
npx wrangler d1 migrations apply DB --remote
```

マイグレーションは `migrations/` に番号順で置く。

## 本番の secret

```sh
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put TYPESAFE_API_KEY
npx wrangler secret put FAMILY_TOKEN
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put SESSION_SECRET   # openssl rand -base64 32 などで作る
npx wrangler secret put PARENT_EMAILS    # 例: mama@example.com,papa@example.com
npm run deploy
```

## テスト

```sh
npm test           # vitest
npm run typecheck  # tsc --noEmit
```

- 中継 API（`test/index.test.ts`）: fetch をモックして中継先の URL・ヘッダー・ストリームを確認
- ダッシュボード（`test/dashboard.test.ts`）: Google のトークンエンドポイントを fetch のモックにして、コールバック・許可リスト・id_token の検証・家族トークンの発行と認証・画面の中身を確認
- 同期 API（`test/sync.test.ts`）: wrangler の `getPlatformProxy` で本物のローカル D1（Miniflare / workerd）を起動し、`migrations/*.sql` をそのまま流してから API を叩く。`@cloudflare/vitest-pool-workers` は vitest 5 に未対応のため使っていない

## 動作確認の例

```sh
curl -N -X POST http://localhost:8787/v1/claude \
  -H "Authorization: Bearer $FAMILY_TOKEN" \
  -d '{"model":"claude-haiku-5-5","max_tokens":100,"stream":true,"messages":[{"role":"user","content":"こんにちは"}]}'

curl -X POST http://localhost:8787/v1/sessions \
  -H "Authorization: Bearer $FAMILY_TOKEN" \
  -d '{"id":"test-1","started_at":"2026-11-03T16:00:00+09:00","ended_at":"2026-11-03T16:30:00+09:00","focus_minutes":25,"summary":"割合"}'
```
