import { Hono } from "hono";
import { resolveFamily } from "./auth";
import type { AppEnv } from "./env";
import { sync } from "./sync";
import {
  ALLOWED_MODELS,
  ANTHROPIC_URL,
  ANTHROPIC_VERSION,
  ELEVENLABS_BASE,
  ELEVENLABS_MODEL,
  TYPESAFE_URL,
} from "./upstream";

export type { Env } from "./env";

const app = new Hono<AppEnv>();

app.use("/v1/*", async (c, next) => {
  const familyId = await resolveFamily(c.req.header("Authorization"), c.env);
  if (!familyId) return c.json({ error: "unauthorized" }, 401);
  c.set("familyId", familyId);
  await next();
});

app.route("/v1", sync);

app.post("/v1/claude", async (c) => {
  const body = await readJson(c.req.raw);
  if (!body) return c.json({ error: "invalid json" }, 400);
  if (!ALLOWED_MODELS.includes(body.model as (typeof ALLOWED_MODELS)[number])) {
    return c.json({ error: "model not allowed" }, 400);
  }
  // 受け取ったヘッダーは転送しない（家族トークンを上流に流さない）
  return relay(ANTHROPIC_URL, {
    "content-type": "application/json",
    "x-api-key": c.env.ANTHROPIC_API_KEY,
    "anthropic-version": ANTHROPIC_VERSION,
  }, body);
});

app.post("/v1/tts", async (c) => {
  const body = await readJson(c.req.raw);
  if (!body || typeof body.text !== "string" || body.text.length === 0) {
    return c.json({ error: "text is required" }, 400);
  }
  const voiceId =
    typeof body.voice_id === "string" && body.voice_id ? body.voice_id : c.env.ELEVENLABS_VOICE_ID;
  const url = `${ELEVENLABS_BASE}/${encodeURIComponent(voiceId)}/stream/with-timestamps`;
  return relay(url, {
    "content-type": "application/json",
    "xi-api-key": c.env.ELEVENLABS_API_KEY,
  }, { text: body.text, model_id: ELEVENLABS_MODEL });
});

app.post("/v1/decide", async (c) => {
  const body = await readJson(c.req.raw);
  if (!body) return c.json({ error: "invalid json" }, 400);
  return relay(TYPESAFE_URL, {
    "content-type": "application/json",
    authorization: `Bearer ${c.env.TYPESAFE_API_KEY}`,
  }, body);
});

app.notFound((c) => c.json({ error: "not found" }, 404));

async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const v: unknown = await req.json();
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

// 上流を呼んで、ステータスと本文のストリームをそのまま返す（バッファしない）。
async function relay(url: string, headers: Record<string, string>, body: unknown): Promise<Response> {
  let upstream: Response;
  try {
    upstream = await fetch(url, { method: "POST", headers, body: JSON.stringify(body) });
  } catch {
    return Response.json({ error: "upstream unreachable" }, { status: 502 });
  }
  const out = new Headers();
  const contentType = upstream.headers.get("content-type");
  if (contentType) out.set("content-type", contentType);
  out.set("cache-control", "no-cache");
  return new Response(upstream.body, { status: upstream.status, headers: out });
}

export default app;
