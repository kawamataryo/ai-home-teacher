// 自力で解けるようになってきた変化（#161）。problems の記録から Claude を呼ばずに集計する。
// 点数、順位、割合のスコアは作らない。下がった週を責めず、ヒントの増加を悪いこととして書かない。

export type GrowthProblem = { started_at: string; solved_by_self: number; hint_level_reached: number };

export type WeekGrowth = {
  weekStart: string; // その週の月曜（JST の YYYY-MM-DD）
  total: number;
  solvedNoHint: number; // ヒントなしで自力で解けた
  solvedWithHint: number; // ヒントを使って自力で解けた
  together: number; // 一緒に解いた・途中まで
  hintUsed: number; // ヒントを使った問題（解けたかは問わない）
  enough: boolean; // 変化を言える件数があるか
};

export const GROWTH_WEEKS = 6;
// 数問の差を「伸び」と言わない。この件数に満たない週とは比べない
export const MIN_PROBLEMS_PER_WEEK = 5;
// 週の差がこれ未満なら「増えた」と言わない
export const MIN_INCREASE = 2;

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;
const DAY_MS = 86_400_000;

// JST の月曜 0 時を週の始まりにする
export function jstWeekStart(at: string | number): string {
  const t = typeof at === "number" ? at : Date.parse(at);
  const local = new Date(t + JST_OFFSET_MS);
  const sinceMonday = (local.getUTCDay() + 6) % 7;
  return new Date(local.getTime() - sinceMonday * DAY_MS).toISOString().slice(0, 10);
}

// weeks 週分を古い順に返す（最後が今週）。記録のない週も 0 件で返す
export function weeklyGrowth(problems: GrowthProblem[], now: number, weeks = GROWTH_WEEKS): WeekGrowth[] {
  const thisWeek = Date.parse(`${jstWeekStart(now)}T00:00:00Z`);
  const out: WeekGrowth[] = [];
  for (let i = weeks - 1; i >= 0; i--) {
    const weekStart = new Date(thisWeek - i * 7 * DAY_MS).toISOString().slice(0, 10);
    out.push({ weekStart, total: 0, solvedNoHint: 0, solvedWithHint: 0, together: 0, hintUsed: 0, enough: false });
  }
  for (const p of problems) {
    const week = out.find((w) => w.weekStart === jstWeekStart(p.started_at));
    if (!week) continue;
    week.total += 1;
    if (p.hint_level_reached > 0) week.hintUsed += 1;
    if (!p.solved_by_self) week.together += 1;
    else if (p.hint_level_reached === 0) week.solvedNoHint += 1;
    else week.solvedWithHint += 1;
  }
  for (const w of out) w.enough = w.total >= MIN_PROBLEMS_PER_WEEK;
  return out;
}

const solved = (w: WeekGrowth) => w.solvedNoHint + w.solvedWithHint;

// 伸びを一言で表す。記録が少なければ結論を出さない。下がっても責めない
export function growthSentence(weeks: WeekGrowth[]): string {
  const enough = weeks.filter((w) => w.enough);
  const latest = enough.at(-1);
  if (!latest) return "まだ記録が少ない週なので、変化はもう少し続けてから見ていきます。";
  const previous = enough.at(-2);
  if (!previous) return `${latest.total}問に取り組んだ週がありました。比べられる週が増えたら、変化をお伝えします。`;

  if (solved(latest) - solved(previous) >= MIN_INCREASE) {
    return `自力で解けた問題が増えています（${solved(previous)}問から${solved(latest)}問）。`;
  }
  if (latest.solvedNoHint - previous.solvedNoHint >= MIN_INCREASE) {
    return `ヒントなしで解けた問題が増えています（${previous.solvedNoHint}問から${latest.solvedNoHint}問）。`;
  }
  if (latest.hintUsed - previous.hintUsed >= MIN_INCREASE) {
    return `ヒントを使いながら${latest.total}問に取り組みました。ヒントを手がかりに考えるのも、大切な学び方です。`;
  }
  return `${latest.total}問に取り組みました。同じくらいのペースで続いています。`;
}
