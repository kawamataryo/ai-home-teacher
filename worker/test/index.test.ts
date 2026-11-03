import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app, { type Env } from "../src/index";

const env: Env = {
  ANTHROPIC_API_KEY: "test-anthropic",
  ELEVENLABS_API_KEY: "test-eleven",
  TYPESAFE_API_KEY: "test-typesafe",
  FAMILY_TOKEN: "family-secret",
  ELEVENLABS_VOICE_ID: "default-voice",
};

const AUTH = { Authorization: "Bearer family-secret" };

function post(path: string, body: unknown, headers: Record<string, string> = AUTH, e: Env = env) {
  return app.request(
    path,
    {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: typeof body === "string" ? body : JSON.stringify(body),
    },
    e,
  );
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn(async () => Response.json({ ok: true }));
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function upstreamCall(): { url: string; init: RequestInit; headers: Headers; body: any } {
  expect(fetchMock).toHaveBeenCalledTimes(1);
  const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
  return { url, init, headers: new Headers(init.headers), body: JSON.parse(init.body as string) };
}

describe("認証", () => {
  it("トークンなしは 401", async () => {
    const res = await post("/v1/claude", { model: "claude-haiku-5-5" }, {});
    expect(res.status).toBe(401);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("違うトークンは 401", async () => {
    const res = await post("/v1/tts", { text: "こんにちは" }, { Authorization: "Bearer wrong" });
    expect(res.status).toBe(401);
  });

  it("FAMILY_TOKEN が未設定なら空トークンでも 401", async () => {
    const res = await post("/v1/decide", {}, { Authorization: "Bearer " }, { ...env, FAMILY_TOKEN: "" });
    expect(res.status).toBe(401);
    const res2 = await post("/v1/decide", {}, AUTH, { ...env, FAMILY_TOKEN: "" });
    expect(res2.status).toBe(401);
  });

  it("正しいトークンなら通る", async () => {
    const res = await post("/v1/decide", { state: "x", questions: {} });
    expect(res.status).toBe(200);
  });
});

describe("/v1/claude", () => {
  it("許可されていないモデルは 400", async () => {
    const res = await post("/v1/claude", { model: "claude-3-opus", messages: [] });
    expect(res.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("model がない場合も 400", async () => {
    const res = await post("/v1/claude", { messages: [] });
    expect(res.status).toBe(400);
  });

  it("壊れた JSON は 400", async () => {
    const res = await post("/v1/claude", "{not json");
    expect(res.status).toBe(400);
  });

  it.each(["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])(
    "%s は Anthropic に正しいヘッダーで転送する",
    async (model) => {
      const req = { model, max_tokens: 10, messages: [{ role: "user", content: "hi" }] };
      const res = await post("/v1/claude", req);
      expect(res.status).toBe(200);
      const call = upstreamCall();
      expect(call.url).toBe("https://api.anthropic.com/v1/messages");
      expect(call.init.method).toBe("POST");
      expect(call.headers.get("x-api-key")).toBe("test-anthropic");
      expect(call.headers.get("anthropic-version")).toBe("2023-06-01");
      expect(call.headers.get("authorization")).toBeNull();
      expect(call.body).toEqual(req);
    },
  );

  it("上流のエラーステータスをそのまま返す", async () => {
    fetchMock.mockResolvedValueOnce(Response.json({ type: "error" }, { status: 429 }));
    const res = await post("/v1/claude", { model: "claude-haiku-5-5", messages: [] });
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ type: "error" });
  });

  it("上流に届かなければ 502", async () => {
    fetchMock.mockRejectedValueOnce(new TypeError("network"));
    const res = await post("/v1/claude", { model: "claude-haiku-5-5", messages: [] });
    expect(res.status).toBe(502);
  });

  it("stream: true の SSE をバッファせずに流す", async () => {
    const enc = new TextEncoder();
    const chunk1 = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n";
    const chunk2 = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    let releaseSecond!: () => void;
    const secondGate = new Promise<void>((r) => (releaseSecond = r));

    const upstreamBody = new ReadableStream<Uint8Array>({
      async start(controller) {
        controller.enqueue(enc.encode(chunk1));
        await secondGate; // テスト側が 1 つ目を読むまで 2 つ目を出さない
        controller.enqueue(enc.encode(chunk2));
        controller.close();
      },
    });
    fetchMock.mockResolvedValueOnce(
      new Response(upstreamBody, { status: 200, headers: { "content-type": "text/event-stream" } }),
    );

    const res = await post("/v1/claude", { model: "claude-haiku-5-5", stream: true, messages: [] });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    expect(res.headers.get("cache-control")).toBe("no-cache");
    expect(upstreamCall().body.stream).toBe(true);

    const reader = res.body!.getReader();
    const dec = new TextDecoder();
    // 上流がまだ閉じていない状態で 1 つ目のチャンクが届く = バッファしていない
    const first = await reader.read();
    expect(first.done).toBe(false);
    expect(dec.decode(first.value)).toBe(chunk1);

    releaseSecond();
    let rest = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      rest += dec.decode(value, { stream: true });
    }
    expect(rest).toBe(chunk2);
  });
});

describe("/v1/tts", () => {
  it("既定の voice ID で ElevenLabs の with-timestamps を呼ぶ", async () => {
    const line =
      JSON.stringify({
        audio_base64: "AAAA",
        alignment: { characters: ["こ"], character_start_times_seconds: [0], character_end_times_seconds: [0.1] },
      }) + "\n";
    fetchMock.mockResolvedValueOnce(
      new Response(line, { status: 200, headers: { "content-type": "application/json" } }),
    );
    const res = await post("/v1/tts", { text: "こんにちは" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(await res.text()).toBe(line);

    const call = upstreamCall();
    expect(call.url).toBe(
      "https://api.elevenlabs.io/v1/text-to-speech/default-voice/stream/with-timestamps",
    );
    expect(call.headers.get("xi-api-key")).toBe("test-eleven");
    expect(call.headers.get("authorization")).toBeNull();
    expect(call.body).toEqual({ text: "こんにちは", model_id: "eleven_flash_v2_5" });
  });

  it("voice_id を指定すると差し替わる", async () => {
    await post("/v1/tts", { text: "はい", voice_id: "other-voice" });
    expect(upstreamCall().url).toBe(
      "https://api.elevenlabs.io/v1/text-to-speech/other-voice/stream/with-timestamps",
    );
  });

  it("text がなければ 400", async () => {
    const res = await post("/v1/tts", {});
    expect(res.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("/v1/decide", () => {
  it("TypeSafe AI に TypeSafe のキーで転送する（家族トークンは流さない）", async () => {
    const req = {
      state: "先生、これわかんない",
      model: "jev-latest",
      questions: { to_teacher: { type: "noul", instructions: "先生への発話か" } },
    };
    fetchMock.mockResolvedValueOnce(Response.json({ answers: { to_teacher: { noul: 0.9 } } }));
    const res = await post("/v1/decide", req);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ answers: { to_teacher: { noul: 0.9 } } });

    const call = upstreamCall();
    expect(call.url).toBe("https://api.typesafe.ai/v1/systemone");
    expect(call.headers.get("authorization")).toBe("Bearer test-typesafe");
    expect(call.headers.get("content-type")).toBe("application/json");
    expect(call.body).toEqual(req);
  });
});

describe("その他", () => {
  it("知らないパスは 404", async () => {
    const res = await post("/v1/unknown", {});
    expect(res.status).toBe(404);
  });
});
