// プロンプトの組み立て。アプリの PromptLibrary.conversationSystemPrompt（ios/HomeTeacher/Brain/PromptLibrary.swift）と揃える。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const promptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "prompts");

export const SEPARATOR = "\n\n---\n\n";
export const DEFAULT_VARIABLES = { teacher_name: "ハル" };
// アプリの SessionMode.label と揃える。
export const SESSION_MODE_LABELS = { study: "勉強中", rest: "休憩中" };
export const CONVERSATION_PARTS = ["teacher", "hint_ladder", "safety", "small_talk", "board_talk"];

export function render(template, variables) {
  return Object.entries(variables).reduce(
    (text, [key, value]) => text.replaceAll(`{{${key}}}`, value),
    template,
  );
}

export function loadPrompt(name, variables = {}) {
  const raw = readFileSync(join(promptsDir, `${name}.md`), "utf8");
  return render(raw, { ...DEFAULT_VARIABLES, ...variables });
}

export function teacherNoteSection(note) {
  return `# 先生のメモ（子どもには見せない・読み上げない）\n\n${note}`;
}

// teacher → hint_ladder → safety → small_talk → board_talk の順。前回のこと（opening.md に差し込む）があれば足し、
// 先生のメモがあれば最後に足す。
export function conversationSystemPrompt({ mode = "study", teacherNote, previousSession, variables = {} } = {}) {
  const label = SESSION_MODE_LABELS[mode];
  if (!label) throw new Error(`未知のモード: ${mode}`);
  const vars = { ...variables, session_mode: label };
  const parts = CONVERSATION_PARTS.map((name) => loadPrompt(name, vars));
  const previous = previousSession?.trim();
  if (previous) parts.push(loadPrompt("opening", { ...vars, previous_session: previous }));
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
  return [loadTool("flag_for_parent"), showBoardTool()];
}
