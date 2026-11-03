// Worker の binding / secret / var の型と、Hono のコンテキストの型。

export type Env = {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  TYPESAFE_API_KEY: string;
  FAMILY_TOKEN: string;
  ELEVENLABS_VOICE_ID: string;
  // Azure Neural TTS（/v1/tts/azure）。キーは secret、地域と声は vars（なければ japaneast / ja-JP-NanamiNeural）
  AZURE_SPEECH_KEY?: string;
  AZURE_SPEECH_REGION?: string;
  AZURE_TTS_VOICE?: string;
  DB: D1Database;
  // 親のダッシュボード（#29）。すべて secret（ローカルは .dev.vars）
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  SESSION_SECRET?: string;
  // ログインを許可するメールアドレス（カンマ区切り）。公開リポジトリなので vars には書かない
  PARENT_EMAILS?: string;
  // "1" のとき localhost からのアクセスだけログインを省く（スクリーンショット用）。.dev.vars にだけ書く
  DEV_AUTH_BYPASS?: string;
};

export type AppEnv = {
  Bindings: Env;
  // 認証ミドルウェアが家族トークンから解決した家族の id
  Variables: { familyId: string };
};
