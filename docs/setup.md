# セットアップ手順（本物のサービスにつなぐ）

ここまでのコードは、Claude・ElevenLabs・TypeSafe AI（Jev）・Google ログインのどれとも**実際には通信していない**（テストはすべてモック）。動かすには、下の順に設定する。詳しい説明は [worker/README.md](../worker/README.md)。

## 1. Cloudflare（Worker と D1）

```bash
cd worker && npm ci
```

```bash
npx wrangler d1 create ai-home-teacher
```

出力された `database_id` を `worker/wrangler.jsonc` の `REPLACE_WITH_DATABASE_ID` に書く（秘密情報ではない）。

```bash
npx wrangler d1 migrations apply DB --remote
```

## 2. 先生の声（ElevenLabs）

ElevenLabs で日本語に合う声を選び、その voice ID を `worker/wrangler.jsonc` の `REPLACE_WITH_VOICE_ID` に書く。

## 3. Google ログイン（親のダッシュボード）

Google Cloud Console で OAuth クライアント（種類: ウェブ アプリケーション）を作り、承認済みのリダイレクト URI に次を追加する。

- `https://<Worker のホスト>/dashboard/auth/callback`
- `http://localhost:8787/dashboard/auth/callback`

## 4. 秘密情報を登録する

1つずつ値を聞かれるので入力する。リポジトリには入らない。

```bash
npx wrangler secret put ANTHROPIC_API_KEY
```

同じように次も登録する。

| 名前 | 中身 |
| --- | --- |
| `ANTHROPIC_API_KEY` | ハッカソンのクレジットを入れた組織の API キー |
| `ELEVENLABS_API_KEY` | ElevenLabs の API キー |
| `AZURE_SPEECH_KEY` | Azure の Speech リソースのキー（先生の声を Azure にするときだけ。下の「先生の声を Azure にする」） |
| `TYPESAFE_API_KEY` | TypeSafe AI の API キー |
| `FAMILY_TOKEN` | 最初の iPad をつなぐ予備のトークン（長いランダムな文字列） |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | 3 で作った OAuth クライアント |
| `SESSION_SECRET` | `openssl rand -base64 32` などで作る |
| `PARENT_EMAILS` | ダッシュボードに入れるメールアドレス（カンマ区切り） |

## 5. 公開する

```bash
npm run deploy
```

同期で 200 件を超えるときのページ送り（`order=updated`）も、この公開で有効になる。

## 6. iPad アプリをつなぐ

`ios/Config/Secrets.xcconfig` に Worker の URL と家族トークンを書く（URL は `https:/$()/...` と書く）。家族トークンはダッシュボード（`/dashboard`）で発行したものを使うか、4 の `FAMILY_TOKEN` を使う。

### 先生の声を Azure にする（任意）

ElevenLabs より安い（無料枠は月 50 万字。超えても 100 万字あたり $15）。いつでも ElevenLabs に戻せる。

1. Azure ポータルで「Speech」リソースを作る（地域: Japan East。お試しは価格レベル Free F0、日常使いは Standard S0）
2. リソースの「キーとエンドポイント」のキーを Worker に登録して公開する

   ```bash
   npx wrangler secret put AZURE_SPEECH_KEY
   npm run deploy
   ```

   地域と声は `worker/wrangler.jsonc` の `AZURE_SPEECH_REGION`（既定 `japaneast`）と `AZURE_TTS_VOICE`（既定 `ja-JP-NanamiNeural`）
3. `ios/Config/Secrets.xcconfig` に `TTS_PROVIDER = azure` と書いてビルドし直す。戻すときは `elevenlabs` にする

F0 は 1 分に 20 リクエストまで。初回起動時に定型句（17 個）を Azure の声で作り直すので、最初の 1 分ほどは待ってから話しかける。

## 7. つないだら最初にやる確認

一部の API の形が違うだけで、いくつもの機能がまとめて動かなくなるので、実機の確認より先にこれを行う。

1. 評価スクリプトを流す（Claude が答えを言わずにヒントを出すか、要確認フラグを出すか）

   ```bash
   WORKER_BASE_URL=https://<Worker のホスト> FAMILY_TOKEN=<トークン> node evals/run.mjs
   ```

2. 次の4つを1回ずつ呼んで確かめる

   | 呼び先 | 確かめること |
   | --- | --- |
   | `/v1/claude` | ストリーミング応答が届く。strict な tool と `tool_choice` の指定が通る |
   | `/v1/tts` | 音声と文字タイミングが届く（ストリームの区切り方は未確認） |
   | `/v1/tts/azure` | （Azure を使うときだけ）MP3 が届く |
   | `/v1/decide` | Jev の `noul` 型の質問が通る |
   | `/dashboard` | Google ログインが通る |

3. 定型句の音声を ElevenLabs の声で作り直す

   ```bash
   node scripts/generate_phrases.mjs
   ```
