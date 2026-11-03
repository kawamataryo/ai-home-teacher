# Lessons

ユーザーから受けた修正と、そこから得たルールを記録する。

- 2026-11-03: TTS の月額を「数千円」と過大に見積もった。実際は月15万字で ElevenLabs 約900円。→ 費用の見積もりは単価と使用量から計算してから伝える
- 2026-11-03: `git add -A` でサブエージェントの worktree（.claude/worktrees/）を gitlink としてコミットしてしまった。→ `.claude/worktrees/` を .gitignore に入れておく。add の前に `git status --short` を確認する
