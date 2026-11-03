# AI家庭教師（仮）

一人で勉強する孤独を解消する、iPad の向こうに「一緒に頑張ってくれる先生」がいる家庭学習アプリ。

共働きで親が手を離せない朝や夕方、子どもが声で話しかけると、ボクセル風の先生が見守り、わからないところは**答えを言わずにヒントと図で**導いてくれます。

[Built with Claude: Japan 2026](https://cerebralvalley.ai/events/~/e/built-with-claude-japan2026) 参加作品です。

## できること

- 声だけで会話（キーボード不要、話の途中で割り込める）
- 「これ見て」と言うと撮影し、段階的なヒントを出す。最後のひと言は子どもに言わせる
- 数直線・面積図・手順カードなどの図で説明（Generative UI）
- 休憩や集中の声かけ、休憩中の雑談、前回の内容を覚えたふり返り
- 親はスマホの Web ダッシュボードで学習の様子を確認

## 構成

- iPad アプリ：SwiftUI（iOS 26）、SpeechAnalyzer、RealityKit、Vision
- 頭脳：Claude（会話は `claude-haiku-5-5`、分析と図は `claude-sonnet-5-5`）
- 速い判断：TypeSafe AI の Jev（Decision API）
- 読み上げ：ElevenLabs（差し替え可能）
- サーバー：Cloudflare Workers ＋ D1

## ドキュメント

- [仕様書](docs/spec.md)
- [ビジョンと決定事項](docs/vision.md)
- [技術調査](docs/research-2026-11-03.md)
- [ハッカソン要項](docs/hackathon-guide.md)

## ライセンス

MIT
