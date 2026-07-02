# AGENTS.md

git-tui（Zig 0.16 + zigzag の git コミット支援 TUI）。**規約・所有権・各種 gotcha の正は `CLAUDE.md` なので、作業前に必ず読むこと。** ここには CLAUDE.md に無く agent が頻繁に踏む点のみ記す。

## ツールチェイン
- `mise.toml` が Zig 0.16.0 + zls 0.16.0 を固定。`mise install` で揃う。
- zigzag は `build.zig.zon` で v0.1.5 固定。**昇格しない**（Zig 0.16 / std.Io API の前提）。

## コマンド（agent が迷いやすい点）
- ビルド: `zig build` / 配布: `zig build -Doptimize=ReleaseFast`
- テスト: `zig build test --summary all`（**Debug 既定を維持**=実行時安全チェックを保つ。Release にしない）
- 実行: `zig build run`（git リポジトリ内で）。`--no-mouse` でマウス無効。
- ベンチマーク: `zig build bench`（Debug 既定: correctness + alloc 数）・`zig build bench -Doptimize=ReleaseFast`（fps/latency）。入力は `bench/gen-history.sh` で生成した `bench/repos/<profile>-<n>/`（git-ignore）。基線は `bench/report-before.md`。
- **lint / typecheck / format / codegen / migration の各ステップは存在しない。** 型検査と検証は `zig build test` に一本化されており、これらをでっち上げて実行しないこと。
- **単一テストのフィルタ実行は `build.zig` に未配線**（`zig build test` に `--test-filter` は無い）。個別テストを走らせるなら `zig test src/root_test.zig` を依存フラグ付きで直接実行するか、一時的に build.zig を変更する。

## テストの仕組み（ハマりどころ）
- すべて実装 `.zig` 内の `test {}` ブロック。`src/root_test.zig` が全モジュールを `@import` して一本化し、`zig build test` がそれを起動する。
- **新規 `.zig` を追加したら `src/root_test.zig` の `@import("...")` 行を足さないとテストが走らない。**
- `std.testing.allocator` 必須（リーク検出）。view の `fitPane` 等 arena 上で動く関数のテストは `std.heap.ArenaAllocator` を渡す。詳細は `CLAUDE.md`「テスト規約」。

## 編集前に必ず読むドキュメント
- `CLAUDE.md` — 規約・所有権・Zig 0.16 落とし穴・描画 gotcha の正。
- `docs/superpowers/plans/zigzag-api-notes.md` — **zigzag/std の実 API はこれが正**（計画書の擬似コードより優先）。
- `TODO.md` — 未実装機能の方式/サブタスク。**新機能着手前に該当項目を読み、影響/完了時は更新する**。
- `docs/superpowers/{specs,plans}/*.md` — 機能ごとの設計判断とタスク分解（mvp / partial-staging / auto-refresh / line-staging 等）。

## アーキテクチャの前提（詳細は CLAUDE.md）
Elm 風・副作用隔離。`model/messages/update/appcmd/git/*` が純粋層（TDD 対象）、`input/view/main` が UI 層。機能追加は**純粋層を TDD → UI 配線**の順。エントリは `src/main.zig` の `pub fn main(init: std.process.Init)`、git はワーカースレッドで実行。
- **純粋 reducer は `pub fn update(model: *Model, msg: *Msg)`（ポインタ渡し・perf phase2 §6.1）**。`Msg.LogLoaded.substrate` のみ reducer が Model へ take（move）できる（`takeSubstrate()` で disarm）。テストは literal/借用 Msg は `updateRef` helper・所有 payload は `var msg + defer msg.deinit + &msg`。詳細は `CLAUDE.md`「所有権の規約」。

## TUI の手動検証
対話 TUI は非 tty で目視不可 → 実 pty は `tmux`（`new-session -x W -y H` → `send-keys` → `capture-pane -p`）。
