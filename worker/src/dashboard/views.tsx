// ダッシュボードの HTML（Hono JSX でサーバー側で描画する。外部の JS / CSS は読まない）。
// スマホ幅を基本にして、広い画面では中央寄せにする。

import type { Child, FC } from "hono/jsx";
import type { MemoryRow, ParentMessageRow, SessionJson } from "../sync";

export type DayTotal = { day: string; minutes: number }; // day は JST の YYYY-MM-DD

const CSS = `
:root {
  --bg: #f7f4ee; --card: #fffdf9; --ink: #2b2a27; --muted: #6f6a60; --line: #e6e0d4;
  --accent: #2f7d6d; --accent-soft: #dcefe9; --warn: #b4531c; --warn-soft: #fff0e3; --bar: #4a9d8b;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #1b1c1b; --card: #252725; --ink: #ecebe6; --muted: #a6a39b; --line: #3a3c39;
    --accent: #7cc7b5; --accent-soft: #23403a; --warn: #f0a46c; --warn-soft: #3d2a1d; --bar: #5fb3a0;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Noto Sans JP", sans-serif;
}
main { max-width: 640px; margin: 0 auto; padding: 16px 16px 48px; }
header { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 16px; }
h1 { font-size: 20px; margin: 0; }
h2 { font-size: 16px; margin: 0 0 12px; }
.who { font-size: 12px; color: var(--muted); text-align: right; word-break: break-all; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; margin-bottom: 16px; }
.stats { display: flex; gap: 16px; margin-bottom: 8px; }
.stat b { display: block; font-size: 22px; }
.stat span { font-size: 12px; color: var(--muted); }
.chart { width: 100%; height: auto; display: block; }
.chart text { fill: var(--muted); font-size: 9px; }
.chart .val { fill: var(--ink); font-size: 9px; font-weight: 600; }
.chart .grid { stroke: var(--line); }
.chart .bar { fill: var(--bar); }
.chart .today { fill: var(--accent); }
.session { border-top: 1px solid var(--line); padding: 14px 0; }
.session:first-of-type { border-top: 0; padding-top: 0; }
.session.flagged { background: var(--warn-soft); border: 1px solid var(--warn); border-radius: 12px; padding: 12px; margin: 8px 0; }
.meta { font-size: 13px; color: var(--muted); }
.summary { margin: 4px 0 8px; }
.note { background: var(--accent-soft); border-radius: 10px; padding: 8px 12px; margin: 8px 0; }
.note::before { content: "きょうのひとこと"; display: block; font-size: 11px; color: var(--accent); font-weight: 700; }
.prompt { background: var(--accent-soft); border-color: var(--accent); }
.prompt h2 { color: var(--accent); margin-bottom: 4px; }
.prompt .line { font-size: 18px; font-weight: 600; margin: 0; }
label.field { display: block; font-size: 13px; color: var(--muted); margin: 0 0 10px; }
.input { display: block; width: 100%; margin-top: 4px; padding: 10px; border: 1px solid var(--line); border-radius: 10px;
  background: var(--bg); color: var(--ink); font: inherit; }
textarea.input { min-height: 84px; resize: vertical; }
.error { color: var(--warn); font-weight: 700; margin: 0 0 10px; }
.message { border-top: 1px solid var(--line); padding: 10px 0 0; margin-top: 10px; overflow-wrap: anywhere; }
.message p { margin: 0 0 2px; }
.status { font-size: 12px; font-weight: 700; color: var(--muted); }
.status.told { color: var(--accent); }
.memory-group { margin-top: 12px; }
.memory-group h3 { font-size: 13px; color: var(--muted); margin: 0 0 4px; }
.memory { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 8px 0; border-top: 1px solid var(--line); }
.memory span { overflow-wrap: anywhere; min-width: 0; }
.memory form { flex: none; margin: 0; }
.flags { margin: 8px 0; padding: 0; list-style: none; }
.flags li { color: var(--warn); font-weight: 600; }
.flags li::before { content: "⚠ 要確認："; }
.label { font-size: 12px; font-weight: 700; color: var(--muted); margin-top: 8px; }
ul.problems { margin: 2px 0 0; padding-left: 20px; }
.empty { color: var(--muted); }
.alert { border-color: var(--warn); }
.alert h2 { color: var(--warn); }
.btn { display: inline-block; border: 0; border-radius: 10px; padding: 12px 18px; font: inherit; font-weight: 700;
  background: var(--accent); color: #fff; text-decoration: none; cursor: pointer; }
.btn.sub { background: transparent; color: var(--muted); border: 1px solid var(--line); padding: 6px 10px; font-size: 13px; font-weight: 400; }
.token { font: 14px ui-monospace, Menlo, monospace; background: var(--bg); border: 1px dashed var(--accent);
  border-radius: 8px; padding: 10px; word-break: break-all; user-select: all; }
.small { font-size: 13px; color: var(--muted); }
.center { text-align: center; padding-top: 15vh; }
`;

const Layout: FC<{ title: string; children?: Child }> = ({ title, children }) => (
  <html lang="ja">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="robots" content="noindex" />
      <title>{title}</title>
      <style dangerouslySetInnerHTML={{ __html: CSS }} />
    </head>
    <body>
      <main>{children}</main>
    </body>
  </html>
);

export const LoginPage: FC<{ message?: string }> = ({ message }) => (
  <Layout title="ログイン｜AI家庭教師">
    <div class="center">
      <h1>AI家庭教師 ダッシュボード</h1>
      <p class="small">保護者の Google アカウントでログインしてください。</p>
      {message && <p style="color: var(--warn); font-weight: 700">{message}</p>}
      <p>
        <a class="btn" href="/dashboard/auth/login">
          Google でログイン
        </a>
      </p>
    </div>
  </Layout>
);

export const DashboardPage: FC<{
  email: string;
  days: DayTotal[];
  today: string;
  sessions: SessionJson[];
  tokenIssuedAt: string | null;
  messages: ParentMessageRow[];
  memories: MemoryRow[];
  memoryError?: string;
  newToken?: string;
  messageError?: string;
  messageDraft?: { sender: string; body: string };
}> = ({ email, days, today, sessions, tokenIssuedAt, messages, memories, memoryError, newToken, messageError, messageDraft }) => {
  const flagged = sessions.filter((s) => s.flags.length > 0);
  const week = days.slice(-7).reduce((sum, d) => sum + d.minutes, 0);
  const todayMinutes = days.find((d) => d.day === today)?.minutes ?? 0;
  return (
    <Layout title="学習のようす｜AI家庭教師">
      <header>
        <h1>学習のようす</h1>
        <div class="who">
          {email}
          <form method="post" action="/dashboard/logout" style="margin: 4px 0 0">
            <button class="btn sub" type="submit">
              ログアウト
            </button>
          </form>
        </div>
      </header>

      {newToken && (
        <section class="card alert">
          <h2>新しい家族トークン</h2>
          <p class="small">この画面を閉じると二度と表示されません。iPad のアプリの設定に貼り付けてください。</p>
          <div class="token">{newToken}</div>
        </section>
      )}

      <ParentPromptCard session={sessions[0]} today={today} />

      {flagged.length > 0 && (
        <section class="card alert">
          <h2>要確認（{flagged.length} 件）</h2>
          <ul class="flags">
            {flagged.flatMap((s) =>
              s.flags.map((f) => (
                <li>
                  {f}
                  <span class="meta">（{formatDate(s.started_at)}）</span>
                </li>
              )),
            )}
          </ul>
        </section>
      )}

      <MessageCard messages={messages} error={messageError} draft={messageDraft} />

      <section class="card">
        <h2>日ごとの学習時間</h2>
        <div class="stats">
          <div class="stat">
            <b>{todayMinutes} 分</b>
            <span>今日</span>
          </div>
          <div class="stat">
            <b>{week} 分</b>
            <span>最近 7 日</span>
          </div>
        </div>
        <StudyChart days={days} today={today} />
      </section>

      <section class="card">
        <h2>セッション</h2>
        {sessions.length === 0 && <p class="empty">まだ記録がありません。</p>}
        {sessions.map((s) => (
          <SessionItem s={s} />
        ))}
      </section>

      <MemoryCard memories={memories} error={memoryError} />

      <section class="card">
        <h2>家族トークン</h2>
        <p class="small">
          iPad のアプリがこの Worker を使うための合言葉です。
          {tokenIssuedAt
            ? `発行済み（${formatDate(tokenIssuedAt)} ${formatTime(tokenIssuedAt)}）。再発行すると今までのトークンは使えなくなります。`
            : "まだ発行していません。"}
        </p>
        <form method="post" action="/dashboard/token">
          <button class="btn" type="submit">
            {tokenIssuedAt ? "再発行する" : "発行する"}
          </button>
        </form>
      </section>
    </Layout>
  );
};

// 最新のセッションの声かけ（#158）。項目のないセッション（古いアプリ・ふり返りが作れなかったとき）なら何も出さない。
// 古いセッションの声かけは「今夜」に見えないよう、いつの勉強かを見出しに書く
const ParentPromptCard: FC<{ session?: SessionJson; today: string }> = ({ session, today }) => {
  const prompt = session?.parent_prompt.trim();
  if (!session || !prompt) return null;
  return (
    <section class="card prompt">
      <h2>{jstDay(session.started_at) === today ? "今夜の声かけ" : `${formatDate(session.started_at)}の勉強から、声かけ`}</h2>
      <p class="line">{prompt}</p>
    </section>
  );
};

// 親の伝言（#159）。書く欄と、送った伝言が伝わったかどうか
const MessageCard: FC<{
  messages: ParentMessageRow[];
  error?: string;
  draft?: { sender: string; body: string };
}> = ({ messages, error, draft }) => {
  const lastSender = messages[0]?.sender_label ?? "";
  return (
    <section class="card" id="message">
      <h2>先生にことづける</h2>
      <p class="small">次の勉強の始まりに、先生が子どもに伝えます。1 回の勉強で 1 つずつ、書いた順に伝えます。</p>
      {error && <p class="error">{error}</p>}
      <form method="post" action="/dashboard/messages">
        <label class="field">
          伝言（200 文字まで）
          <textarea class="input" name="body" maxlength={200} required>
            {draft?.body ?? ""}
          </textarea>
        </label>
        <label class="field">
          先生が言う呼び方（お母さん、パパなど。空なら「おうちの人」）
          <input class="input" name="sender" maxlength={12} value={draft?.sender ?? lastSender} autocomplete="off" />
        </label>
        <button class="btn" type="submit">
          伝言を送る
        </button>
      </form>
      {messages.map((m) => (
        <div class="message">
          <p>{m.body}</p>
          <div class="meta">
            {m.sender_label}から・{formatDate(m.created_at)} {formatTime(m.created_at)}
          </div>
          {m.delivered_at ? (
            <div class="status told">
              {formatDate(m.delivered_at)} {formatTime(m.delivered_at)} に伝えました
            </div>
          ) : (
            <div class="status">まだ伝えていません</div>
          )}
        </div>
      ))}
    </section>
  );
};

const MEMORY_GROUPS = [
  { category: "likes", label: "好きなこと" },
  { category: "events", label: "最近の出来事" },
  { category: "weak_points", label: "苦手な単元" },
];

// 先生が覚えていること（#160）。短い言葉のまま見せて、言い換えも評価もしない
const MemoryCard: FC<{ memories: MemoryRow[]; error?: string }> = ({ memories, error }) => (
  <section class="card" id="memory">
    <h2>先生が覚えていること</h2>
    <p class="small">間違いや古くなった内容は消せます。消すと、次の勉強から先生は使いません。</p>
    {error && <p class="error">{error}</p>}
    {memories.length === 0 && <p class="empty">まだ覚えていることはありません。</p>}
    {MEMORY_GROUPS.map(({ category, label }) => {
      const items = memories.filter((m) => m.category === category);
      if (items.length === 0) return null;
      return (
        <div class="memory-group">
          <h3>{label}</h3>
          {items.map((m) => (
            <div class="memory">
              <span>{m.content}</span>
              <form method="post" action="/dashboard/memories/delete">
                <input type="hidden" name="category" value={m.category} />
                <input type="hidden" name="content" value={m.content} />
                <button class="btn sub" type="submit" aria-label={`${m.content} を消す`}>
                  消す
                </button>
              </form>
            </div>
          ))}
        </div>
      );
    })}
  </section>
);

const SessionItem: FC<{ s: SessionJson }> = ({ s }) => {
  const stuck = s.problems.filter((p) => !p.solved_by_self);
  const solved = s.problems.filter((p) => p.solved_by_self);
  return (
    <article class={s.flags.length > 0 ? "session flagged" : "session"}>
      <div class="meta">
        {formatDate(s.started_at)} {formatTime(s.started_at)}〜{formatTime(s.ended_at)}・集中 {s.focus_minutes} 分
      </div>
      {s.summary && <p class="summary">{s.summary}</p>}
      {s.flags.length > 0 && (
        <ul class="flags">
          {s.flags.map((f) => (
            <li>{f}</li>
          ))}
        </ul>
      )}
      {stuck.length > 0 && (
        <>
          <div class="label">つまずいたところ</div>
          <ul class="problems">
            {stuck.map((p) => (
              <li>
                {p.summary}
                <span class="meta">（ヒント {p.hint_level_reached} 段階）</span>
              </li>
            ))}
          </ul>
        </>
      )}
      {solved.length > 0 && (
        <>
          <div class="label">自力で解けたところ</div>
          <ul class="problems">
            {solved.map((p) => (
              <li>{p.summary}</li>
            ))}
          </ul>
        </>
      )}
      {s.teacher_note && <div class="note">{s.teacher_note}</div>}
    </article>
  );
};

// 棒グラフ（インライン SVG）。今日の棒だけ色を変える
const StudyChart: FC<{ days: DayTotal[]; today: string }> = ({ days, today }) => {
  const W = 340;
  const H = 150;
  const top = 14;
  const bottom = 20;
  const left = 4;
  const plotH = H - top - bottom;
  const max = Math.max(30, Math.ceil(Math.max(...days.map((d) => d.minutes)) / 30) * 30);
  const slot = (W - left) / days.length;
  const barW = Math.max(4, slot * 0.62);
  const y = (m: number) => top + plotH - (m / max) * plotH;
  const label = days.map((d) => `${shortDay(d.day)} ${d.minutes}分`).join("、");
  return (
    <svg class="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`日ごとの学習時間：${label}`}>
      <line class="grid" x1={left} x2={W} y1={y(max)} y2={y(max)} />
      <line class="grid" x1={left} x2={W} y1={y(max / 2)} y2={y(max / 2)} />
      <line class="grid" x1={left} x2={W} y1={y(0)} y2={y(0)} />
      <text x={W} y={y(max) - 3} text-anchor="end">
        {max} 分
      </text>
      {days.map((d, i) => {
        const x = left + i * slot + (slot - barW) / 2;
        const h = y(0) - y(d.minutes);
        return (
          <g>
            <rect class={d.day === today ? "today" : "bar"} x={x} y={y(d.minutes)} width={barW} height={h} rx="2" />
            {d.minutes > 0 && (
              <text class="val" x={x + barW / 2} y={y(d.minutes) - 3} text-anchor="middle">
                {d.minutes}
              </text>
            )}
            {/* 日付は 1 日おき。最後（今日）から数えるので今日には必ず付く */}
            {(days.length - 1 - i) % 2 === 0 && (
              <text x={x + barW / 2} y={H - 6} text-anchor="middle">
                {shortDay(d.day)}
              </text>
            )}
          </g>
        );
      })}
    </svg>
  );
};

// ---- 日時の表示（JST） ----

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

export function jstDay(iso: string | number): string {
  const t = typeof iso === "number" ? iso : Date.parse(iso);
  return new Date(t + JST_OFFSET_MS).toISOString().slice(0, 10);
}

function shortDay(day: string): string {
  const [, m, d] = day.split("-");
  return `${Number(m)}/${Number(d)}`;
}

function formatDate(iso: string): string {
  const day = jstDay(iso);
  const w = "日月火水木金土"[new Date(`${day}T00:00:00Z`).getUTCDay()];
  return `${shortDay(day)}（${w}）`;
}

function formatTime(iso: string): string {
  return new Date(Date.parse(iso) + JST_OFFSET_MS).toISOString().slice(11, 16);
}
