// テスト用の本物のローカル D1。
// wrangler の getPlatformProxy は Miniflare（本番と同じ workerd の D1 実装）を起動して binding を返す。
// @cloudflare/vitest-pool-workers は vitest 5 に未対応（peer が ^4）なので、通常の Node 環境の vitest から使う。
// persist: false なのでディスクには残らず、envFiles: [] なので .dev.vars も読まない。

import { afterAll, beforeAll, beforeEach } from "vitest";
import { getPlatformProxy } from "wrangler";

// Vite（vitest）の import.meta.glob で SQL を文字列として読む（Node の型を Worker のコードに混ぜないため）
const migrationFiles = (
  import.meta as unknown as {
    glob: (pattern: string, opts: object) => Record<string, string>;
  }
).glob("../../migrations/*.sql", { query: "?raw", import: "default", eager: true });
const TABLES_CHILD_FIRST = ["family_tokens", "problems", "sessions", "memories", "memory_deletions", "parent_messages", "weekly_summaries", "children", "parents", "families", "d1_migrations"];

// migrations/*.sql を番号順に 1 文ずつに分ける（コメント行は捨てる。SQL のコメントに ; は書かない）
export function migrationStatements(): string[] {
  return Object.keys(migrationFiles)
    .sort()
    .flatMap((f) =>
      migrationFiles[f]
        .split("\n")
        .filter((line) => !line.trimStart().startsWith("--"))
        .join("\n")
        .split(";")
        .map((s) => s.trim())
        .filter(Boolean),
    );
}

// テストファイルごとに D1 を 1 つ起動し、テストごとにテーブルを作り直す
export function useD1(): { db: () => D1Database } {
  let proxy: Awaited<ReturnType<typeof getPlatformProxy<{ DB: D1Database }>>>;

  beforeAll(async () => {
    proxy = await getPlatformProxy<{ DB: D1Database }>({
      configPath: "wrangler.jsonc", // npm test は worker/ で実行する
      persist: false,
      envFiles: [],
    });
  });

  afterAll(async () => {
    await proxy?.dispose();
  });

  beforeEach(async () => {
    const db = proxy.env.DB;
    await db.batch(TABLES_CHILD_FIRST.map((t) => db.prepare(`DROP TABLE IF EXISTS ${t}`)));
    await db.batch(migrationStatements().map((s) => db.prepare(s)));
  });

  return { db: () => proxy.env.DB };
}
