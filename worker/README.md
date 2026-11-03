# Worker（中継 API）

iPad アプリの API キーを守るための Cloudflare Worker。アプリは家族トークンでこの Worker を呼び、Worker が各 API に中継する。

| エンドポイント | 中継先 | 内容 |
| --- | --- | --- |
| `POST /v1/claude` | Anthropic Messages API | body をそのまま転送。`stream: true` なら SSE をそのまま流す。`model` は `claude-haiku-5-5` / `claude-sonnet-5-5` / `claude-opus-5-5` のみ |
| `POST /v1/tts` | ElevenLabs `stream/with-timestamps` | body は `{ text, voice_id? }`。モデルは `eleven_flash_v2_5`。音声（base64）と文字タイミングの JSON をそのまま流す |
| `POST /v1/decide` | TypeSafe AI（Jev）`/v1/systemone` | body をそのまま転送 |

すべてのリクエストに `Authorization: Bearer <家族トークン>` が必要（ない、または違うと 401）。

## セットアップ

```sh
cd worker
npm install
cp .dev.vars.example .dev.vars   # 値を入れる（.dev.vars は gitignore 済み）
npm run dev                      # http://localhost:8787
```

`wrangler.jsonc` の `vars.ELEVENLABS_VOICE_ID` を、使う声の voice ID に置き換える。

## 本番の secret

```sh
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put TYPESAFE_API_KEY
npx wrangler secret put FAMILY_TOKEN
npm run deploy
```

## テスト

```sh
npm test           # vitest（fetch をモックして中継先の URL・ヘッダー・ストリームを確認）
npm run typecheck  # tsc --noEmit
```

## 動作確認の例

```sh
curl -N -X POST http://localhost:8787/v1/claude \
  -H "Authorization: Bearer $FAMILY_TOKEN" \
  -d '{"model":"claude-haiku-5-5","max_tokens":100,"stream":true,"messages":[{"role":"user","content":"こんにちは"}]}'
```
