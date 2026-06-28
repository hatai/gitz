# セッション handoff — TODO 2 phase 3b #1 ブランチフィルタ（2026-06-29）

新しいセッションがここから引き継ぐためのメモ。プロジェクト全体の規約は `CLAUDE.md`、機能の全体像は `TODO.md`、agent が踏みやすい点は `AGENTS.md` を参照。

---

## 前セッションで完了したこと

**TODO 2 phase 3b #2「フィルタ中の graph 維持」を実装 → `main` へ no-ff マージ → `origin/main` へ push 済み（`732b99b`）。**

- ワークフロー: brainstorming → spec → writing-plans → subagent-driven-development（Task 1-9 + 最終 whole-branch review）。
- spec `docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md` / plan `docs/superpowers/plans/2026-06-26-todo2-filter-graph-projection.md`。
- 核心: フィルタ適用時に全履歴 topology substrate（`git rev-list --topo-order --parents <snapshot_tip>`）を取得し、新規純粋モジュール `graph_project.project`（第一親チェーン・反復 2 パス・メモ化）が visible commit の parent を「最近親可視祖先」へ投影 → derived `[]log.Commit` を**既存 `graph.computeAll` へ入力（graph.zig 不変）**。
- 新規ファイル: `src/git/topology.zig`（substrate parse/clone）・`src/git/graph_project.zig`（投影）。
- paging は**全 loaded commits 再投影 + computeAll** で cross-page 自己補正（C1 = 部分可见集合だと永続切断するため・最終 review で発見修正）。
- **542/542 tests passing**（マージ後確認済み）。

phase 3b の残りは **#1 ブランチフィルタのみ**（これが phase 3b 最後・TODO.md:195）。

---

## 現在のリポジトリ状態

- ブランチ: `main`（`origin/main` と同期済み・HEAD `732b99b`）。feature ブランチ `feat/filter-graph-projection` はマージ後に削除済み。
- 本 #1 着手時は `main` から feature ブランチを切る（#2/#4 と同じ no-ff flow）。
- untracked: `docs/superpowers/handoffs/`（本ファイル）・`qa-results/`（本作業無関係）。
- SDD ledger: `.superpowers/sdd/progress.md`（git-ignore scratch・#2 complete 記録済み）。

---

## 次の作業: #1 ブランチフィルタ（`--branches`・phase 3b 最後）

`TODO.md:195` 参照。phase3a spec §16（`docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md:934-939`）に拡張ポイントあり。

### 現状（フィルタ基盤）
- `FilterSpec`（`src/filter.zig:20-117`）= `FilterCondition` union リスト（`author`/`since`/`until`/`paths`）。branch は `branches` variant 追加で拡張（アプローチ B・将来拡張用）。
- サーバ側フィルタ: `git/commands.zig` `appendFilterOptions`（:115-157・author/since/until）+ `appendPaths`（:159-173・`-- <paths>` argv 末尾）。`logArgv`/`logPageArgv`（:78-186）が `snapshot_tip` revision + filter を組み立て。
- `log_snapshot_tip`（`model.zig:69`）: `runLogInt` が `git rev-parse --verify HEAD` で解決した単一 tip（race 回避・phase3a B1）。paging は `load_log_page`（`tip_hash` = snapshot_tip）で同一 snapshot を参照（`handleLogPageLoaded` で tip 照合・`update.zig`）。
- filter modal: 4 欄（author/since/until/paths）・`filter_modal_focus: u2`（`model.zig:75`）・`shift_tab`/`tab` でフォーカス切替（`input.zig:182`）・main が `syncFilterModal` でプレフィル/同期。

### #1 の核心: B3 和集合問題（設計の最大分岐・brainstorming で詰める）

phase3a §16/B3（`phase3a-filter-design.md:938`）より:
> 単一 branch 選択時は選択 branch ref を `git rev-parse --verify <branch>` で hash 解決し、それ自体を snapshot_tip とする。**複数 branch は snapshot owner を単一 tip ではなく複数 hash の所有集合にする必要がある**（要件定義・codex 未解決論点 6）。

問題: 現状の `log_snapshot_tip` は**単一 tip 前提**。`--branches=<glob>` で複数 branch にマッチすると:
- `git log <snapshot_tip> --branches=...` は複数 tip の和集合を返すが、paging の `log_snapshot_tip` 単一 tip 照合（`handleLogPageLoaded` の `request_tip == log_snapshot_tip`・`update.zig:612-617`）と衝突。
- #2 の substrate/投影は **`snapshot_tip` が単一 tip の限り再利用可能**（`rev-list --parents <snapshot_tip>`）。複数 tip なら substrate も `rev-list --parents <tip1> <tip2> ...` へ拡張必要。

### 設計判断の未決点（brainstorming で詰める）
1. **単一 vs 複数 branch**: 単一 branch のみサポート（hash 解決して snapshot_tip へ・B3 単純化）にするか、複数 branch の所有集合まで扱うか。
2. **`--branches=<glob>` の argv 形式**: git は `--branches[=<pattern>]`（refnames マッチ）と `--branches` 単体（全 refs/heads）。`--fixed-strings` は `--branches` に影響しない（`--author`/`--grep` のみ・phase3a M8 前提）。
3. **graph 投影との整合**: 単一 branch なら #2 の substrate/投影がそのまま動く（snapshot_tip = branch hash）。複数 branch なら substrate を複数 tip 対応へ拡張。
4. **UI**: modal 5 欄化（`filter_modal_focus` を `u2`→`u3` へ・`shift_tab` cycle 拡張）。

### phase3a §16 の他の拡張ポイント（branch と同時に検討可）
- `--grep`（コミットメッセージ検索）: `--fixed-strings` が `--grep` にも効くため再検証必要（phase3a は `--author` のみで副作用なし・phase3a §2）。

---

## 着手時の進め方（このプロジェクトの確立した流れ）

1. **`TODO.md` の該当項目（`:195`）と phase3a §16/B3 を必読**。
2. **brainstorming スキル**でスコープ確認（単一/複数 branch・argv 形式・graph 投影との整合）→ spec を `docs/superpowers/specs/YYYY-MM-DD-*.md` へ。
3. **節目で独立サブエージェントレビュー**（spec/plan とも codex レビュー: `codex-plan-reviewer`）— #2/#3b spec/plan は全て codex レビュー済み（#4/#2 はスキップしたが、#1 は B3 未解決論点付きで推奨）。
4. writing-plans → subagent-driven-development（fresh subagent/タスク + タスクレビュー + 最終 whole-branch review）。
5. 純粋層（filter.zig の branches variant・model/messages/appcmd/update/commands）を TDD → UI 配線、の順（CLAUDE.md「進め方」）。
6. 最終 whole-branch review → `main` へ no-ff マージ → push（ユーザ確認後）。

---

## #2 のインフラ再利用メモ（branch が単一 tip に解決される場合）

- `topology.fetchSubstrate`（`appcmd.zig`）: `rev-list --parents <snapshot_tip>`。単一 branch なら snapshot_tip = branch hash でそのまま動く。
- `graph_project.project`（`src/git/graph_project.zig`）: substrate + visible → 投影。branch フィルタでも visible 集合の定義が変わるのみでロジック不変。
- `handleLogLoaded`/`handleLogPageLoaded`（`update.zig`）: filter 活性 + substrate 有 → 投影 computeAll（paging は全再投影・C1 自己補正）。branch フィルタも `filter_state.isEmpty()` で分岐するため、branches variant 追加だけで投影経路へ乗る。

## Zig 0.16 / テストの要点（CLAUDE.md 抜粋・編集前に必読）

- 実 API は `docs/superpowers/plans/zigzag-api-notes.md` が正。
- テストは実装と同じ `.zig` の `test {}`。`std.testing.allocator`（リーク検出）必須。新規 `.zig` は `src/root_test.zig` へ import 追加（**忘れるとテスト非実行**）。
- `zig build test --summary all`（Debug 既定維持・`--test-filter` 未配線）。**lint/format/typecheck は存在しない**（`zig build test` が型検査も兼ねる）。
- **OOM 教訓（#2 で踏んだ）**: `toOwnedSlice` 後は元 ArrayList の errdefer が無害化するため、新 slice 用の errdefer を再登録（contents も deinit する）。`addCondition` の OOM 時 payload 自動 deinit（phase3b M3）も踏襲。

---

## phase 3b 完了条件（#1 で達成）

phase 3b の 4 フィルタ種（author / date / path / **branch**）全て実装 + フィルタ中 graph 維持。#1 完了で phase 3b 全完了 → TODO 2（log view）の残りは TODO 3（interactive rebase）等へ。
