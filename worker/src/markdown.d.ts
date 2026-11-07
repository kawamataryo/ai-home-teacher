// wrangler は Text、vitest は vitest.config.ts のプラグインで .md を文字列として読む
declare module "*.md" {
  const text: string;
  export default text;
}
