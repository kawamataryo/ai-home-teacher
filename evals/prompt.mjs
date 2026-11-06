// プロンプトの組み立て。アプリの PromptLibrary.conversationSystemPrompt（ios/HomeTeacher/Brain/PromptLibrary.swift）と揃える。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const promptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "prompts");

export const SEPARATOR = "\n\n---\n\n";
// キャラの一覧。アプリの CharacterCatalog と同じファイル（既定の先生は先頭の haru）。
export const CHARACTERS = JSON.parse(readFileSync(join(promptsDir, "characters", "characters.json"), "utf8"));
export const DEFAULT_CHARACTER = CHARACTERS.find((c) => c.id === "haru");

// アプリの TeacherCharacter.promptVariables と揃える。
export function characterVariables(character = DEFAULT_CHARACTER) {
  return {
    teacher_name: character.name,
    honorific: character.honorific,
    role_line: character.roleLine,
    role_noun: character.roleNoun,
    nudge_tone: character.nudgeTone,
  };
}
// アプリの SessionMode.label と揃える。
export const SESSION_MODE_LABELS = { study: "勉強中", rest: "休憩中" };
export const CONVERSATION_PARTS = ["teacher", "hint_ladder", "safety", "small_talk", "board_talk", "web_search"];

// アプリの PromptLibrary.todayLabel と揃える（日本時間の「2026年11月6日（金）」）。
export function todayLabel(date = new Date()) {
  const parts = new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", year: "numeric", month: "numeric", day: "numeric", weekday: "short" }).formatToParts(date);
  const get = (type) => parts.find((p) => p.type === type).value;
  return `${get("year")}年${get("month")}月${get("day")}日（${get("weekday")}）`;
}

export function render(template, variables) {
  return Object.entries(variables).reduce(
    (text, [key, value]) => text.replaceAll(`{{${key}}}`, value),
    template,
  );
}

// キャラごとの性格（prompts/characters/<id>.md）。アプリの PromptLibrary.characterProfile と揃える。
export function characterProfile(character = DEFAULT_CHARACTER) {
  return readFileSync(join(promptsDir, "characters", `${character.id}.md`), "utf8").trim();
}

export function characterById(id) {
  const character = CHARACTERS.find((c) => c.id === id);
  if (!character) throw new Error(`知らないキャラ: ${id}`);
  return character;
}

export function loadPrompt(name, variables = {}, character = DEFAULT_CHARACTER) {
  // キャラごとの性格を先に入れる。中の {{key}} も下で差し込む
  const raw = readFileSync(join(promptsDir, `${name}.md`), "utf8").replaceAll("{{character_profile}}", () => characterProfile(character));
  return render(raw, { ...characterVariables(character), ...variables });
}

export function teacherNoteSection(note) {
  return `# 先生のメモ（子どもには見せない・読み上げない）\n\n${note}`;
}

// 親の伝言の差し込み。アプリの PromptLibrary.parentMessageVariables と揃える（区切りや差し込みの印を作らせない）
export function parentMessageVariables({ sender, body }) {
  const neutralize = (text) => text.replaceAll("<", "＜").replaceAll(">", "＞").replaceAll("{", "｛").replaceAll("}", "｝").replaceAll('"', "”");
  return { parent_message_sender: neutralize(sender), parent_message_body: neutralize(body) };
}

// teacher → hint_ladder → safety → small_talk → board_talk → web_search の順。前回のこと（opening.md に差し込む）があれば足し、親の伝言（parent_message.md）があれば足し、
// 先生のメモがあれば最後に足す。
export function conversationSystemPrompt({ mode = "study", teacherNote, previousSession, parentMessage, variables = {}, character = DEFAULT_CHARACTER } = {}) {
  const label = SESSION_MODE_LABELS[mode];
  if (!label) throw new Error(`未知のモード: ${mode}`);
  const vars = { today: todayLabel(), ...variables, session_mode: label };
  const parts = CONVERSATION_PARTS.map((name) => loadPrompt(name, vars, character));
  const previous = previousSession?.trim();
  if (previous) parts.push(loadPrompt("opening", { ...vars, previous_session: previous }, character));
  if (parentMessage) parts.push(loadPrompt("parent_message", { ...vars, ...parentMessageVariables(parentMessage) }, character));
  const note = teacherNote?.trim();
  if (note) parts.push(teacherNoteSection(note));
  return parts.join(SEPARATOR);
}

// 同梱のツール定義（prompts/tools/<name>.json）。アプリの PromptLibrary.tool(named:) と同じファイル。
export function loadTool(name) {
  return JSON.parse(readFileSync(join(promptsDir, "tools", `${name}.json`), "utf8"));
}

// 黒板の show_board。アプリの BoardTools.conversationTool と同じもの（Swift から書き出した evals/fixtures/board_tools.json）。
export function showBoardTool() {
  const fixture = JSON.parse(readFileSync(join(promptsDir, "..", "evals", "fixtures", "board_tools.json"), "utf8"));
  return fixture.analyzer_request.tools.find((t) => t.name === "show_board");
}

// アプリの PromptLibrary.conversationTools と同じ順。
export function conversationTools() {
  return [loadTool("flag_for_parent"), showBoardTool(), loadTool("show_reference_image"), loadTool("web_search")];
}
