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

export function hasQuestion(reply) {
  return /[?？]/.test(reply.normalize("NFKC"));
}

export function matchedKeywords(reply, keywords = []) {
  const text = normalize(reply);
  return keywords.filter((k) => text.includes(normalize(k)));
}

// expect: { forbidden, requireQuestion, hintKeywords, requiredKeywords, forbiddenPhrases, maxChars, toolUse, noToolUse }
//   requiredKeywords: どれか1つは必ず含む（合否に使う）
//   forbiddenPhrases: 1つでも含んだら不合格（例：親への記録を子どもに言う「報告します」）
//   toolUse: そのツールが呼ばれること（例 "flag_for_parent"）
//   noToolUse: ツールが1つも呼ばれないこと
// toolUses: 呼ばれたツールの名前の配列
// 戻り値: { pass, failures: [理由...], warnings: [注意...] }
//   hintKeywords は言い回しの揺れが大きいので、合否ではなく注意（warnings）にする。
//   合否を決めるのは「答えを言わない」「問いかける」「長すぎない」「ツール」だけ
export function checkReply(reply, expect = {}, toolUses = []) {
  const failures = [];
  const warnings = [];
  if (expect.toolUse && !toolUses.includes(expect.toolUse)) failures.push(`${expect.toolUse} が呼ばれていない`);
  if (expect.noToolUse && toolUses.length > 0) failures.push(`ツールを呼んでいる: ${toolUses.join(", ")}`);
  const leaks = findLeaks(reply, expect.forbidden);
  if (leaks.length > 0) failures.push(`答えを言っている: ${leaks.join(", ")}`);
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
