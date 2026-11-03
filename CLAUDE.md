# CLAUDE.md

## プロジェクト

小5の子ども向け、音声中心の家庭学習伴走アプリ（iPad / SwiftUI）。仕様は `docs/spec.md`、背景と決定事項は `docs/vision.md`。判断に迷ったら「これで孤独は減るか？」「本物の家庭教師ならどうするか？」で決める。

## 進め方

- 作業は GitHub issue 単位。マイルストーン「11/8 提出」の issue を番号の小さい順（親 issue の順番①→⑥）に進める
- issue ごとに worktree とブランチを切る → 実装 → テスト → PR（本文に `Closes #N`）→ テストが通ったらマージ
- 完了条件を満たした証拠（テスト結果、スクリーンショット）を PR に貼る。「たぶん動く」で完了にしない
- `実機確認` ラベルの issue は、実装と PR まで進めたらマージせずに止め、issue に実機チェックリストを書いてユーザーを待つ
- 仕様と違う判断をしたら `docs/spec.md` を更新する
- issue、PR、コミットメッセージ、ドキュメントは日本語

## 守ること

- API キーや秘密情報はリポジトリに入れない。アプリ側は `Secrets.xcconfig`（gitignore 済み）、Worker 側は `wrangler secret` / `.dev.vars`
- 写真・音声はサーバーに保存しない。保存するのは文字の情報だけ
- 先生は答えをそのまま言わない（ヒントの段階は spec の §3②）
- 既存ゲームのキャラクターや素材を真似しない

## コマンド

### iOS

- プロジェクト生成（`ios/project.yml` が正。`.xcodeproj` はコミットしない）: `cd ios && xcodegen generate`
- 初回のみ: `cp ios/Config/Secrets.xcconfig.example ios/Config/Secrets.xcconfig`
- テスト: `cd ios && xcodebuild test -project HomeTeacher.xcodeproj -scheme HomeTeacher -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'`
- ファイルを追加・削除したら `xcodegen generate` をやり直す

### プロンプトの評価

- プロンプトは `prompts/`（アプリに同梱される）。会話用は teacher → hint_ladder → safety → small_talk の順につなぐ（`PromptLibrary` と `evals/prompt.mjs` で揃える）
- 判定ロジックのテスト（API 不要）: `node --test evals/*.test.mjs`
- 実際に Claude を呼ぶ評価: `WORKER_BASE_URL=... FAMILY_TOKEN=... node evals/run.mjs`（または `ANTHROPIC_API_KEY=...`）。設定がなければスキップする

### Worker

```sh
cd worker
npm install
npm test           # vitest
npm run typecheck  # tsc --noEmit
npm run dev        # wrangler dev（.dev.vars が必要。例は .dev.vars.example）
```
