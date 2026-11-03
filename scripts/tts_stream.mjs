// ElevenLabs の stream/with-timestamps（Worker の /v1/tts）の本文を読む。
// iOS の ElevenLabsStreamParser / TTSAlignmentMerger と同じ考え方:
// - JSON オブジェクトが改行区切りでも、くっついていても読む（かっこの深さを数え、文字列の中は数えない）
// - チャンクの時刻が前のチャンクの終わりより戻っていたら「チャンクの先頭から」とみなして足す

export function createObjectScanner() {
  let buffer = "";
  let depth = 0;
  let inString = false;
  let escaped = false;
  return {
    // 届いた文字列を入れて、できあがったオブジェクトの文字列を返す
    feed(text) {
      const objects = [];
      for (const ch of text) {
        if (depth === 0) {
          if (ch !== "{") continue;
          buffer = ch;
          depth = 1;
          inString = false;
          escaped = false;
          continue;
        }
        buffer += ch;
        if (inString) {
          if (escaped) escaped = false;
          else if (ch === "\\") escaped = true;
          else if (ch === '"') inString = false;
          continue;
        }
        if (ch === '"') inString = true;
        else if (ch === "{") depth += 1;
        else if (ch === "}") {
          depth -= 1;
          if (depth === 0) {
            objects.push(buffer);
            buffer = "";
          }
        }
      }
      return objects;
    },
    get hasPartialObject() {
      return depth > 0;
    },
  };
}

const TOLERANCE = 0.05;

// 文字タイミングをつなげる
export function mergeAlignment(merged, alignment) {
  if (!alignment) return merged;
  const n = Math.min(
    alignment.characters.length,
    alignment.character_start_times_seconds.length,
    alignment.character_end_times_seconds.length,
  );
  if (n === 0) return merged;
  let starts = alignment.character_start_times_seconds.slice(0, n);
  let ends = alignment.character_end_times_seconds.slice(0, n);
  const characters = alignment.characters.slice(0, n);
  if (!merged) return { characters, character_start_times_seconds: starts, character_end_times_seconds: ends };
  const lastEnd = merged.character_end_times_seconds.at(-1) ?? 0;
  if (starts[0] < lastEnd - TOLERANCE) {
    starts = starts.map((t) => t + lastEnd);
    ends = ends.map((t) => t + lastEnd);
  }
  return {
    characters: [...merged.characters, ...characters],
    character_start_times_seconds: [...merged.character_start_times_seconds, ...starts],
    character_end_times_seconds: [...merged.character_end_times_seconds, ...ends],
  };
}

// 本文の文字列（の断片の並び）を、音声（Buffer）と文字タイミングにまとめる
export function parseTTSStream(pieces) {
  const scanner = createObjectScanner();
  const audio = [];
  let alignment = null;
  for (const piece of pieces) {
    for (const text of scanner.feed(piece)) {
      const object = JSON.parse(text);
      if (!object.audio_base64 && !object.alignment && (object.error || object.detail)) {
        throw new Error(`upstream error: ${JSON.stringify(object.error ?? object.detail)}`);
      }
      if (object.audio_base64) audio.push(Buffer.from(object.audio_base64, "base64"));
      alignment = mergeAlignment(alignment, object.alignment);
    }
  }
  if (scanner.hasPartialObject) throw new Error("stream ended in the middle of a JSON object");
  return { audio: Buffer.concat(audio), alignment };
}
