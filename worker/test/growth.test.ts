import { describe, expect, it } from "vitest";
import { growthSentence, jstWeekStart, MIN_PROBLEMS_PER_WEEK, weeklyGrowth, type GrowthProblem } from "../src/dashboard/growth";

const NOW = Date.parse("2026-11-07T03:00:00Z"); // JST 11/7（土）12:00。今週の月曜は 11/2
const THIS_WEEK = "2026-11-03T07:00:00.000Z";
const LAST_WEEK = "2026-10-27T07:00:00.000Z";

function problems(at: string, solvedNoHint: number, solvedWithHint = 0, together = 0): GrowthProblem[] {
  return [
    ...Array(solvedNoHint).fill({ started_at: at, solved_by_self: 1, hint_level_reached: 0 }),
    ...Array(solvedWithHint).fill({ started_at: at, solved_by_self: 1, hint_level_reached: 2 }),
    ...Array(together).fill({ started_at: at, solved_by_self: 0, hint_level_reached: 4 }),
  ];
}

describe("JST の週の区切り", () => {
  it("月曜 0 時（JST）から新しい週になる。UTC の日付に引きずられない", () => {
    expect(jstWeekStart("2026-11-01T14:59:59.000Z")).toBe("2026-10-26"); // JST 11/1（日）23:59:59
    expect(jstWeekStart("2026-11-01T15:00:00.000Z")).toBe("2026-11-02"); // JST 11/2（月）0:00
    expect(jstWeekStart("2026-11-08T14:59:59.000Z")).toBe("2026-11-02"); // JST 11/8（日）23:59:59
  });

  it("週の境目の問題を正しい週に数える", () => {
    const weeks = weeklyGrowth(
      [
        { started_at: "2026-11-01T14:59:59.000Z", solved_by_self: 1, hint_level_reached: 0 },
        { started_at: "2026-11-01T15:00:00.000Z", solved_by_self: 1, hint_level_reached: 0 },
      ],
      NOW,
    );
    expect(weeks.at(-1)).toMatchObject({ weekStart: "2026-11-02", total: 1 });
    expect(weeks.at(-2)).toMatchObject({ weekStart: "2026-10-26", total: 1 });
  });
});

describe("週ごとの集計", () => {
  it("記録なしでも 6 週分を 0 件で返す（問題のないセッションも 0 件）", () => {
    const weeks = weeklyGrowth([], NOW);
    expect(weeks).toHaveLength(6);
    expect(weeks[0].weekStart).toBe("2026-09-28");
    expect(weeks.every((w) => w.total === 0 && !w.enough)).toBe(true);
  });

  it("ヒントなし、ヒントあり、一緒に解いた、に分ける", () => {
    const week = weeklyGrowth(problems(THIS_WEEK, 3, 2, 1), NOW).at(-1)!;
    expect(week).toMatchObject({ total: 6, solvedNoHint: 3, solvedWithHint: 2, together: 1, hintUsed: 3, enough: true });
  });

  it("範囲より古い記録は数えない", () => {
    const weeks = weeklyGrowth(problems("2026-01-01T00:00:00.000Z", 5), NOW);
    expect(weeks.reduce((n, w) => n + w.total, 0)).toBe(0);
  });
});

describe("伸びの一言", () => {
  const say = (list: GrowthProblem[]) => growthSentence(weeklyGrowth(list, NOW));

  it("記録がなければ結論を出さない", () => {
    expect(say([])).toContain("記録が少ない");
  });

  it("少ない週は比べない。数問の差を伸びと言わない", () => {
    expect(MIN_PROBLEMS_PER_WEEK).toBe(5);
    const text = say([...problems(LAST_WEEK, 1), ...problems(THIS_WEEK, 4)]);
    expect(text).toContain("記録が少ない");
    expect(text).not.toContain("増えて");
  });

  it("比べられる週が 1 つなら結論を出さない", () => {
    const text = say(problems(THIS_WEEK, 6));
    expect(text).toContain("比べられる週が増えたら");
    expect(text).not.toContain("増えて");
  });

  it("自力で解けた問題が増えたら数で伝える", () => {
    expect(say([...problems(LAST_WEEK, 3, 0, 3), ...problems(THIS_WEEK, 3, 3, 0)])).toBe("自力で解けた問題が増えています（3問から6問）。");
  });

  it("自力の数は同じでもヒントなしが増えたら伝える", () => {
    expect(say([...problems(LAST_WEEK, 2, 4), ...problems(THIS_WEEK, 5, 1)])).toBe("ヒントなしで解けた問題が増えています（2問から5問）。");
  });

  it("差が 1 問なら増えたと言わない", () => {
    const text = say([...problems(LAST_WEEK, 5), ...problems(THIS_WEEK, 6)]);
    expect(text).not.toContain("増えて");
    expect(text).toContain("同じくらい");
  });

  it("今週の記録が少なければ、十分な週同士で比べる", () => {
    const text = say([...problems("2026-10-20T07:00:00.000Z", 2, 3), ...problems(LAST_WEEK, 4, 3), ...problems(THIS_WEEK, 1)]);
    expect(text).toBe("自力で解けた問題が増えています（5問から7問）。");
  });

  it("ヒントが増えた週も悪いこととして書かない", () => {
    const text = say([...problems(LAST_WEEK, 6), ...problems(THIS_WEEK, 2, 2, 2)]);
    expect(text).toContain("大切な学び方");
    for (const bad of ["減", "下が", "悪", "できなかった", "注意", "残念", "点", "位", "%", "集中力"]) expect(text).not.toContain(bad);
  });

  it("下がった週も責めない", () => {
    const text = say([...problems(LAST_WEEK, 8), ...problems(THIS_WEEK, 5)]);
    for (const bad of ["減", "下が", "悪", "できなかった", "注意", "残念"]) expect(text).not.toContain(bad);
  });
});
