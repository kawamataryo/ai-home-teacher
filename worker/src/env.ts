// Worker の binding / secret / var の型と、Hono のコンテキストの型。

export type Env = {
  ANTHROPIC_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  TYPESAFE_API_KEY: string;
  FAMILY_TOKEN: string;
  ELEVENLABS_VOICE_ID: string;
  DB: D1Database;
};

export type AppEnv = {
  Bindings: Env;
  // 認証ミドルウェアが家族トークンから解決した家族の id
  Variables: { familyId: string };
};
