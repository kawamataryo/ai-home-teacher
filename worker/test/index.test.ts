import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import app, { type Env } from "../src/index";

const env: Env = {
  ANTHROPIC_API_KEY: "test-anthropic",
  ELEVENLABS_API_KEY: "test-eleven",
  TYPESAFE_API_KEY: "test-typesafe",
  FAMILY_TOKEN: "family-secret",
  ELEVENLABS_VOICE_ID: "default-voice",
  // 中継のテストでは D1 を使わない（同期 API は sync.test.ts で本物のローカル D1 を使う）。
  // 発行済みトークンの照合は常に「見つからない」にする
  DB: {
    prepare: () => ({ bind: () => ({ first: async () => null }) }),
  } as unknown as D1Database,
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

describe("/v1/tts/azure", () => {
  const azureEnv: Env = { ...env, AZURE_SPEECH_KEY: "test-azure" };

  function azureCall(): { url: string; headers: Headers; body: string } {
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    return { url, headers: new Headers(init.headers), body: init.body as string };
  }

  it("既定の地域と声で Azure の REST を呼び、MP3 をそのまま返す", async () => {
    const mp3 = new Uint8Array([0xff, 0xfb, 0x10, 0xc4]);
    fetchMock.mockResolvedValueOnce(new Response(mp3, { status: 200, headers: { "content-type": "audio/mpeg" } }));
    const res = await post("/v1/tts/azure", { text: "こんにちは" }, AUTH, azureEnv);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("audio/mpeg");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(mp3);

    const call = azureCall();
    expect(call.url).toBe("https://japaneast.tts.speech.microsoft.com/cognitiveservices/v1");
    expect(call.headers.get("ocp-apim-subscription-key")).toBe("test-azure");
    expect(call.headers.get("content-type")).toBe("application/ssml+xml");
    expect(call.headers.get("x-microsoft-outputformat")).toBe("audio-24khz-48kbitrate-mono-mp3");
    expect(call.headers.get("user-agent")).toBeTruthy();
    expect(call.headers.get("authorization")).toBeNull();
    expect(call.body).toBe(
      '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="ja-JP">' +
        '<voice name="ja-JP-NanamiNeural">' +
        '<mstts:silence type="Leading-exact" value="0ms"/>' +
        '<mstts:silence type="Tailing-exact" value="0ms"/>' +
        '<mstts:silence type="Sentenceboundary-exact" value="200ms"/>' +
        "こんにちは</voice></speak>",
    );
  });

  it("本文の XML の特殊文字を逃がす（算数の不等号で SSML が壊れない）", async () => {
    await post("/v1/tts/azure", { text: "3 < 5 & 5 > 3 \"だよ\" 'ね'" }, AUTH, azureEnv);
    expect(azureCall().body).toContain(">3 &lt; 5 &amp; 5 &gt; 3 &quot;だよ&quot; &apos;ね&apos;</voice>");
  });

  it("vars の地域と声、リクエストの voice で差し替わる", async () => {
    const e: Env = { ...azureEnv, AZURE_SPEECH_REGION: "eastus", AZURE_TTS_VOICE: "ja-JP-KeitaNeural" };
    await post("/v1/tts/azure", { text: "はい" }, AUTH, e);
    const first = azureCall();
    expect(first.url).toBe("https://eastus.tts.speech.microsoft.com/cognitiveservices/v1");
    expect(first.body).toContain('<voice name="ja-JP-KeitaNeural">');

    fetchMock.mockClear();
    await post("/v1/tts/azure", { text: "はい", voice: "ja-JP-AoiNeural" }, AUTH, e);
    expect(azureCall().body).toContain('<voice name="ja-JP-AoiNeural">');
  });

  it("声の名前の形が違えば 400（SSML の属性に入れないため）", async () => {
    const res = await post("/v1/tts/azure", { text: "はい", voice: '"><x/>' }, AUTH, azureEnv);
    expect(res.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("text がなければ 400", async () => {
    const res = await post("/v1/tts/azure", {}, AUTH, azureEnv);
    expect(res.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("キーが未設定なら上流を呼ばずに 503", async () => {
    const res = await post("/v1/tts/azure", { text: "はい" });
    expect(res.status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("上流の 429 をそのまま返す（アプリは端末の声に切り替える）", async () => {
    fetchMock.mockResolvedValueOnce(new Response("", { status: 429 }));
    const res = await post("/v1/tts/azure", { text: "はい" }, AUTH, azureEnv);
    expect(res.status).toBe(429);
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
