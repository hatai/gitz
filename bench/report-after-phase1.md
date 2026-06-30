# パフォーマンス計渻 after レポート（Phase 1 Task 10 Step 5）

Phase 1（低リスク局所最適化）完了後の計測。`bench/report-before.md`（commit `0775bbc`）との比較で spec §2.4 Phase 1 exit gate を検証する。

## 再現性メタデータ

- after 計測時 commit: `16beaa2`（feat/perf-phase0-1 ブランチ・Phase 1 Task 5-9 完了後）
- before 基線 commit: `0775bbc`（Phase 0 完了時・Task 4 Step 2 の計測コード）
- Zig version: 0.16.0
- 計測対象: 同一 `bench/repos/*-1000`（6 プロファイル・1000 コミット・再生成なし）
- 計測 API: `std.Io.Clock.now(.awake, io)` timestamp 差分

---

## ReleaseFast before/after 比較（代表: linear・1000コミット）

| fence | before ms | after ms | before allocs | after allocs | Δ allocs | peak 変化 |
|---|---|---|---|---|---|---|
| topology.parse | 0.691 | 0.304 | 4016 | 4016 | 0 | 同 |
| graph.computeAll | 0.398 | 0.148 | 4007 | 4007 | 0 | 同 |
| graph.computeIncremental | 0.159 | 0.031 | 808 | 808 | 0 | 同 |
| **graph_project.project** | 1.463 | 0.620 | **7021** | **5023** | **−1998** | 同 |
| runLogInt (no-filter) | 51.531 | 32.508 | 6030 | 6030 | 0 | 同 |
| runLogInt (filter) | 84.353 | 39.228 | 10061 | 10061 | 0 | 同 |
| **view.render 系** | 0.095 | 0.070 | **154** | **104** | **−50** | 15366→7169 |

> `topology.parse` / `computeAll` / `computeIncremental` / `runLogInt` の allocs は不変（Phase 1 対象外・Phase 2 で topology substrate arena 化が対象）。ms の変動は子プロセス実行（runLogInt）や測定誤差による。

## 全プロファイル・最適化対象フェンスの before/after（ReleaseFast）

### graph_project.project（Task 8/M8・mkDerived proj consume）

| profile | before allocs | after allocs | Δ |
|---|---|---|---|
| linear | 7021 | 5023 | −1998 |
| wide-branches | 6985 | 4996 | −1989 |
| periodic-merge | 7243 | 5134 | −2109 |
| path-filter-sparse | 7021 | 5023 | −1998 |
| author-filter-sparse | 7021 | 5023 | −1998 |
| long-subject-refs | 7021 | 5023 | −1998 |

1000 visible commits で −1998〜−2109 allocs（≈2 allocs/commit・parents slice 再確保 + 各 parent の再 dupe 廃止）。

### view.render 系（Task 7/M7・renderGraphCells ANSI 有限集合キャッシュ）

| profile | before allocs | after allocs | Δ | peak 変化 |
|---|---|---|---|---|
| linear | 154 | 104 | −50 | 15366→7169 |
| wide-branches | 206 | 104 | −102 | 17066→7766 |
| periodic-merge | 165 | 104 | −61 | 15706→7086 |
| path-filter-sparse | 154 | 104 | −50 | 15366→7169 |
| author-filter-sparse | 154 | 104 | −50 | 15366→7169 |
| long-subject-refs | 154 | 104 | −50 | 15366→7169 |

50 行窓で per-cell `style.render` がキャッシュ参照へ（2 回目以降 alloc ゼロ）。残り 104 allocs = 50 join(1/行) + fitPane 系 + 初回 4 cache miss。peak_heap も約半減（セル ANSI 文字列の再確保廃止）。wide-branches は分岐セル種が多く before 206 → after 104（差が大きい）。

---

## spec §2.4 Phase 1 exit gate 検証

| gate | 結果 | 根拠 |
|---|---|---|
| `appendLogCommits` paging alloc ≤ 新規件数 + O(1)（Task 5/M6） | **達成** | unit test「ptr 安定性」で既存 items 再 dup 無しを検証・checkAllAllocationFailures で OOM 強例外保証。paging シナリオで既存 N 件の再 clone が消え新規件数のみ（bench 非表示・paging を直接計測しないため unit test で担保） |
| `graph_project.project` allocs 減少（Task 8/M8） | **達成** | 7021 → 5023（−28%）・1000 visible で −1998 allocs |
| `view.render 系` per-cell alloc ゼロ化（Task 7/M7） | **達成** | per-cell `style.render` はキャッシュ参照へ（154→104、残りは構造的 join）。ANSI 文字列の毎フレーム再確保廃止 |
| `renderDiff` 1 回走査化（Task 6/§5.2） | **達成** | total 事前カウント（splitScalar 全走査）廃止・ensureVisible 不変条件で clampScroll 削除。unit test で根拠検証・全テスト緑で出力等価 |

---

## Phase 1 完了判定

- [x] Task 5-9 全完了・現行全テスト + 新規テスト緑（578/578）・リークゼロ
- [x] 所有権規約不改変（Msg/AppCmd ペイロード複製所有・move semantics は Phase 2）
- [x] after 計測で spec §2.4 Phase 1 exit gate 達成
- [x] `zig build bench` 動作（Debug + ReleaseFast）
- [ ] tmux pty で描画崩れなし（手動検証・Task 10 Step 4 review で確認）
- [ ] whole-branch review 合格・main へ no-ff マージ（user 確認後）

## Phase 2/3 への引き継ぎ（Phase 1 完了後）

Phase 1 は局所最適化（alloc 削除中心）で、runLogInt（43-137ms・子プロセス実行が支配的）や topology.parse（allocs 4016・個別 dupe）は未改善。これらは Phase 2/3（未固定）の対象:
- **topology.parse / TopologySubstrate**: arena 化（§6.2）で 4016 allocs → O(1)を目指す。peak heap ~200KB/1000commits → 10万で ~20MB。
- **processCommit frontier**: SBO + HashMap 化（§6.3/§6.4）。frontier max 実測 = 1-3（1000コミット）。
- **projection cache**: §7（cache key 仕様は別途設計セッション）。

Phase 2 plan 執筆前に spec §6.2/§6.4/§7 の設計セッションが必要（codex 第2回 spec レビュー BLOCKER 2 件対応）。
