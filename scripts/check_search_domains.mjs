#!/usr/bin/env node
// prompts/tools/web_search.json の許可リストを 1 つずつ本番の API に当てて確かめる。
// クロールを断っているドメインが 1 つでも入っていると、会話のリクエスト全体が 400 になるので、リストを変えたら必ず走らせる。
//
// 使い方: WORKER_BASE_URL=... FAMILY_TOKEN=... node scripts/check_search_domains.mjs
// 設定がなければ何もせずに終了する（exit 0）。断られたドメインがあれば exit 1。
import { readFileSync } from "node:fs";

const { WORKER_BASE_URL: base, FAMILY_TOKEN: token } = process.env;
if (!base || !token) {
  console.log("WORKER_BASE_URL と FAMILY_TOKEN がないのでスキップします");
  process.exit(0);
}
const tool = JSON.parse(readFileSync(new URL("../prompts/tools/web_search.json", import.meta.url), "utf8"));

async function check(domain) {
  const res = await fetch(new URL("/v1/claude", base), {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({
      model: "claude-haiku-5-5",
      max_tokens: 8,
      thinking: { type: "disabled" },
      messages: [{ role: "user", content: "hi" }],
      tools: [{ ...tool, max_uses: 1, allowed_domains: [domain] }],
    }),
  });
  return res.ok ? null : (await res.text()).slice(0, 200);
}

let failed = 0;
for (const domain of tool.allowed_domains) {
  const problem = await check(domain);
  if (problem) failed += 1;
  console.log(`${problem ? "NG" : "OK"} ${domain}${problem ? ` ${problem}` : ""}`);
}
console.log(`${tool.allowed_domains.length - failed}/${tool.allowed_domains.length} 件 OK`);
process.exit(failed ? 1 : 0);
