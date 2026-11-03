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

// Azure Neural TTS: 2026-11-03 に公式ドキュメント
// https://learn.microsoft.com/azure/ai-services/speech-service/rest-text-to-speech で確認。
//   POST https://{region}.tts.speech.microsoft.com/cognitiveservices/v1、認証ヘッダーは
//   Ocp-Apim-Subscription-Key、body は SSML（Content-Type: application/ssml+xml）。
//   X-Microsoft-OutputFormat と User-Agent は必須。レスポンスは音声のバイト列だけで、文字タイミングは返らない。
//   無料枠（F0）は 1 分に 20 リクエストまで（speech-services-quotas-and-limits）。
export const AZURE_DEFAULT_REGION = "japaneast";
export const AZURE_DEFAULT_VOICE = "ja-JP-NanamiNeural";
export const AZURE_OUTPUT_FORMAT = "audio-24khz-48kbitrate-mono-mp3";
export const AZURE_USER_AGENT = "ai-home-teacher-worker";

export function azureTtsUrl(region: string): string {
  return `https://${encodeURIComponent(region)}.tts.speech.microsoft.com/cognitiveservices/v1`;
}

// 声の名前（ja-JP-NanamiNeural など）。SSML の属性に入れるので、形が違うものは受け付けない
export function isAzureVoiceName(name: string): boolean {
  return /^[a-z]{2,3}-[A-Z]{2}-[A-Za-z0-9]+Neural$/.test(name);
}

// 1 文を SSML にする。算数の「3 < 5」などで SSML が壊れないよう、本文は XML の特殊文字を逃がす
export function azureSsml(text: string, voice: string): string {
  const lang = voice.split("-").slice(0, 2).join("-");
  return `<speak version="1.0" xml:lang="${lang}"><voice name="${voice}">${escapeXml(text)}</voice></speak>`;
}

export function escapeXml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}
