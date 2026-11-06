// 先生の返事を検査する。API を呼ばずにテストできるように、判定だけをここに置く。

// 全角数字・全角記号をそろえ、空白と数字の桁区切りを取る。
export function normalize(text) {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/\s+/g, "")
    .replace(/(\d),(?=\d{3})/g, "$1");
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// 返事に含まれてはいけない言葉（正答など）を探す。
// 数字だけの言葉は、前後が数字でないときだけ一致とする（"48" は "148" や "480" に一致しない）。
export function findLeaks(reply, forbidden = []) {
  const text = normalize(reply);
  return forbidden.filter((word) => {
    const w = normalize(word);
    if (!w) return false;
    if (/^\d+(\.\d+)?$/.test(w)) {
      return new RegExp(`(?<![\\d.])${escapeRegExp(w)}(?![\\d]|\\.\\d)`).test(text);
    }
    return text.includes(w);
  });
}

// 自由に描く図（chalk_drawing）の図形が持つ、位置や大きさの数を取り除く。座標の 48 は答えの 48 ではない。
// 図の文字（text）と、ほかの部品の数は残す。部品が文字列の JSON で返ることがある。読めなければそのまま返す
const DRAWING_NUMBER_KEYS = new Set(["points", "radius", "size", "step"]);

function dropDrawingNumbers(value, inShapes = false) {
  if (typeof value === "string") {
    if (!/^\s*[{[]/.test(value)) return value;
    try {
      return JSON.stringify(dropDrawingNumbers(JSON.parse(value)));
    } catch {
      return value;
    }
  }
  if (Array.isArray(value)) return value.map((v) => dropDrawingNumbers(v, inShapes));
  if (value === null || typeof value !== "object") return value;
  const entries = Object.entries(value).filter(([key]) => !(inShapes && DRAWING_NUMBER_KEYS.has(key)));
  return Object.fromEntries(entries.map(([key, v]) => [key, dropDrawingNumbers(v, inShapes || key === "shapes")]));
}

function withoutDrawingCoordinates(boardText) {
  return boardText
    .split("\n")
    .map((line) => {
      try {
        return JSON.stringify(dropDrawingNumbers(JSON.parse(line)));
      } catch {
        return line;
      }
    })
    .join("\n");
}

export function hasQuestion(reply) {
  return /[?？]/.test(reply.normalize("NFKC"));
}

export function matchedKeywords(reply, keywords = []) {
  const text = normalize(reply);
  return keywords.filter((k) => text.includes(normalize(k)));
}

// 返事の先頭などに付く気持ちのしるし（[praise] / [encourage] / [neutral]、prompts/teacher.md）。
// アプリの EmotionTag（ios/HomeTeacher/Brain/EmotionTag.swift）と揃える：知っているしるしは全部取り除き、最初のものを表情にする。
const EMOTION_TAG = /[\[［]\s*(praise|encourage|neutral)\s*[\]］]/gi;

export function parseEmotion(reply) {
  const first = [...reply.matchAll(EMOTION_TAG)][0];
  return { emotion: first ? first[1].toLowerCase() : null, text: reply.replace(EMOTION_TAG, "").trim() };
}

// expect: { forbidden, requireQuestion, hintKeywords, requiredKeywords, forbiddenPhrases, maxChars, toolUse, noToolUse, allowTools, emotion, boardComponent }
//   requiredKeywords: どれか1つは必ず含む（合否に使う）
//   forbiddenPhrases: 1つでも含んだら不合格（例：親への記録を子どもに言う「報告します」）
//   emotion: 気持ちのしるし（"praise" など）。しるしがないときも違うとみなす（アプリは neutral の顔で話す）
//   toolUse: そのツールが呼ばれること（例 "flag_for_parent"、"show_board"）
//   noToolUse: ツールが1つも呼ばれないこと（allowTools にあるツールは数えない）
// boardText: 黒板に出した図の文字（JSON）。正答が入っていないかも見る
// toolUses: 呼ばれたツールの名前の配列
// 戻り値: { pass, failures: [理由...], warnings: [注意...] }
//   hintKeywords は言い回しの揺れが大きいので、合否ではなく注意（warnings）にする。
//   合否を決めるのは「答えを言わない」「問いかける」「長すぎない」「ツール」だけ
export function checkReply(rawReply, expect = {}, toolUses = [], boardText = "") {
  const failures = [];
  const warnings = [];
  // しるしは読み上げないので、ほかの検査はしるしを除いた文で行う
  const { emotion, text: reply } = parseEmotion(rawReply);
  if (expect.emotion && emotion !== expect.emotion) failures.push(`しるしが違う: ${emotion ?? "なし"}（期待 ${expect.emotion}）`);
  if (expect.toolUse && !toolUses.includes(expect.toolUse)) failures.push(`${expect.toolUse} が呼ばれていない`);
  // boardComponent: 黒板の部品の種類（例 "chalk_drawing"）。部品が文字列の JSON で返っても見つかるよう、文字で探す
  if (expect.boardComponent && !boardText.includes(expect.boardComponent)) failures.push(`黒板の部品が ${expect.boardComponent} ではない`);
  const counted = toolUses.filter((t) => !(expect.allowTools ?? []).includes(t));
  if (expect.noToolUse && counted.length > 0) failures.push(`ツールを呼んでいる: ${counted.join(", ")}`);
  const leaks = findLeaks(reply, expect.forbidden);
  if (leaks.length > 0) failures.push(`答えを言っている: ${leaks.join(", ")}`);
  const boardLeaks = boardText ? findLeaks(withoutDrawingCoordinates(boardText), expect.forbidden) : [];
  if (boardLeaks.length > 0) failures.push(`黒板に答えを書いている: ${boardLeaks.join(", ")}`);
  if (expect.requireQuestion && !hasQuestion(reply)) failures.push("問いかけがない");
  if (expect.requiredKeywords?.length && matchedKeywords(reply, expect.requiredKeywords).length === 0) {
    failures.push(`必要な言葉がない（どれか: ${expect.requiredKeywords.join(" / ")}）`);
  }
  if (expect.forbiddenPhrases?.length) {
    const said = expect.forbiddenPhrases.filter((w) => reply.includes(w));
    if (said.length > 0) failures.push(`言ってはいけない言葉: ${said.join(", ")}`);
  }
  if (expect.hintKeywords?.length && matchedKeywords(reply, expect.hintKeywords).length === 0) {
    warnings.push(`ヒントの言葉がない（どれか: ${expect.hintKeywords.join(" / ")}）`);
  }
  if (expect.maxChars && [...reply].length > expect.maxChars) {
    failures.push(`長すぎる: ${[...reply].length} > ${expect.maxChars} 文字`);
  }
  return { pass: failures.length === 0, failures, warnings };
}
