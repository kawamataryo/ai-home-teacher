// 上流 API の URL と定数。
// Worker のエントリ（index.ts）からはハンドラ以外を export できないため、ここに分けている。

export const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
export const ANTHROPIC_VERSION = "2023-06-01";
export const ALLOWED_MODELS = [
  "claude-haiku-5-5",
  "claude-sonnet-5-5",
  "claude-opus-5-5",
] as const;

// ElevenLabs: 2026-11-03 に公式ドキュメント
// https://elevenlabs.io/docs/api-reference/text-to-speech/stream-with-timestamps で確認。
//   POST /v1/text-to-speech/{voice_id}/stream/with-timestamps、認証ヘッダーは xi-api-key、
//   body は { text, model_id }。レスポンスは JSON の連続（各チャンクに audio_base64 と
//   alignment.{characters, character_start_times_seconds, character_end_times_seconds}）。
//   Content-Type と改行区切りかどうかはドキュメントに明記がないため、上流の値をそのまま返す。
export const ELEVENLABS_BASE = "https://api.elevenlabs.io/v1/text-to-speech";
export const ELEVENLABS_MODEL = "eleven_flash_v2_5";

// TypeSafe AI（Jev）: 2026-11-03 に https://docs.typesafe.ai/introduction/quickstart で確認。
//   POST https://api.typesafe.ai/v1/systemone、Authorization: Bearer <API_KEY>
export const TYPESAFE_URL = "https://api.typesafe.ai/v1/systemone";
