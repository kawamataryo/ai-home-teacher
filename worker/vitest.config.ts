import { readFileSync } from "node:fs";
import { defineConfig } from "vitest/config";

// 本番（wrangler の Text ルール）と同じく、.md を文字列として読む
export default defineConfig({
  plugins: [
    {
      name: "markdown-as-text",
      enforce: "pre",
      load(id) {
        if (id.endsWith(".md")) return `export default ${JSON.stringify(readFileSync(id, "utf8"))};`;
      },
    },
  ],
});
