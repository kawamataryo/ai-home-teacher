// プロンプトの組み立て。アプリの PromptLibrary.conversationSystemPrompt（ios/HomeTeacher/Brain/PromptLibrary.swift）と揃える。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const promptsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "prompts");

export const SEPARATOR = "\n\n---\n\n";
export const DEFAULT_VARIABLES = { teacher_name: "ハル" };

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

// teacher → hint_ladder → safety の順。先生のメモがあれば最後に足す。
export function conversationSystemPrompt({ teacherNote, variables = {} } = {}) {
  const parts = ["teacher", "hint_ladder", "safety"].map((name) => loadPrompt(name, variables));
  const note = teacherNote?.trim();
  if (note) parts.push(teacherNoteSection(note));
  return parts.join(SEPARATOR);
}
