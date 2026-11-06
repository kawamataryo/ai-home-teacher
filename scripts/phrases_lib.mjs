// 定型句の書き出しのきまり。アプリの PhraseCache と揃える。

// 同梱の音声の名前。今の先生は今までの名前のまま（アプリの PhraseCache.bundledURL）
export function bundledPhraseName(characterId, key) {
  return characterId === "haru" ? `phrase_${key}` : `phrase_${characterId}_${key}`;
}

// キャラの言い替えを当てた一覧。自己紹介とあいさつも足す（アプリの PhraseCache.init と同じ）
export function phrasesFor(character, base) {
  const own = [["intro", character.intro], ["greeting", character.greeting]]
    .filter(([, text]) => text)
    .map(([key, text]) => ({ key, text }));
  return [...base.map((phrase) => ({ key: phrase.key, text: character.phrases?.[phrase.key] ?? phrase.text })), ...own];
}

// 自己紹介とあいさつ。選ぶ画面で最初から待たないように同梱する（アプリの PhraseCache の convenience init と同じ）
export function ownPhrases(character) {
  return [
    { key: "intro", text: character.intro },
    { key: "greeting", text: character.greeting },
  ].filter((phrase) => phrase.text);
}

// Azure の音声（worker の AZURE_OUTPUT_FORMAT：48kbps の固定ビットレート）の長さ
export const AZURE_BITS_PER_SECOND = 48_000;
export function azureDuration(byteLength) {
  return (byteLength * 8) / AZURE_BITS_PER_SECOND;
}

// 音声の長さを文字数で均等に割る（アプリの TTSAlignment.evenlySpaced と同じ。キーも TTSAlignment の Codable と同じ）
export function azureAlignment(text, byteLength) {
  const characters = [...text];
  const duration = azureDuration(byteLength);
  if (characters.length === 0 || duration <= 0) return null;
  const step = duration / characters.length;
  return {
    characters,
    character_start_times_seconds: characters.map((_, i) => i * step),
    character_end_times_seconds: characters.map((_, i) => (i + 1) * step),
  };
}
