# パフォーマンス計渻 after レポート（Phase 2）

Phase 2（所有権 / arena 統合）完了後の計測。`bench/report-before.md`（Phase 0 基線・commit `0775bbc`）および Phase 1 後（`16beaa2`）との比較。spec §6.2/§6.3 の効果を定量検証。

## 再現性メタデータ

- after 計測時 commit: `e895859`（feat/perf-phase2 ブランチ・Phase 2 Task 1-3 完了後）
- before（Phase 0）commit: `0775bbc` / Phase 1 後 commit: `16beaa2`
- Zig version: 0.16.0 / 対象: 同一 `bench/repos/*-1000`（6 プロファイル・1000 コミット）
- 計測 API: `std.Io.Clock.now(.awake, io)` timestamp 差分

## Phase 2 スコープ（設計セッション 2026-07-02 固定）

- **§6.1**: `update(*Model, *Msg)` API（171 テスト呼出点 + main 4 点更新）
- **§6.2**: `TopologySubstrate` arena backing + clone 廃止 + `Msg.LogLoaded.substrate` → Model へ take（move）
- **§6.3**: `processCommit` SBO（match_lanes/before_has/agg_lanes・bound=32 + heap fallback）
- **§6.4 frontier HashMap は延期**（Phase 0 データ frontier max=1-3 で効果薄・計測で热点なら再評価）
- §7 projection cache は Phase 3

---

## ReleaseFast before/after 比較（代表: linear・1000コミット）

| fence | Phase 0 allocs | Phase 1 allocs | **Phase 2 allocs** | Δ (P0→P2) | peak 変化 |
|---|---|---|---|---|---|
| topology.parse | 4016 | 4016 | **20** | **−3996 (−99.5%)** | 204792→468412 ※ |
| graph.computeAll | 4007 | 4007 | **2009** | **−1998 (−50%)** | 同 |
| graph.computeIncremental | 808 | 808 | **408** | **−400 (−50%)** | 同 |
| graph_project.project | 7021 | 5023 | 5023 | −1998 (P1 で対応) | 同 |
| runLogInt (no-filter) | 6030 | 6030 | 6030 | 0 | 同 |
| runLogInt (filter) | 10061 | 10061 | **6065** | **−3996 (−40%)** | 617022→880642 ※ |
| view.render 系 | 154 | 104 (P1) | 104 | −50 (P1) | 15366→7169 |

※ arena は chunk 単位で確保するため peak heap は上昇するが、alloc 数は劇減（10万コミットで線形効く GC/fragmentation 軽減が本命）。runLogInt filter の peak 上昇は substrate clone 廃止で take 済み substrate が model へ残る期間の影響。

## Phase 2 改善の内訳

### §6.2 topology.parse arena 化（allocs 4016 → 20）
`TopologySubstrate` へ backing arena を追加し、`parse` の O(N×P) 個別 dupe（hash/parents）を arena 配下へ集約。1000コミットで 4016 個の小アロケーションが arena chunk（≈20 個）へ。10万コミットで線形効く（fragmentation / alloc 数）。`clone` 廃止・`Msg.LogLoaded.substrate` → Model へ take（move）で `handleLogLoaded` の substrate deep-copy も消失。

### §6.3 processCommit SBO（computeAll 4007 → 2009 / computeIncremental 808 → 408）
`match_lanes` / `before_has` / `agg_lanes` を `SmallBuf(T, 32)`（+ heap fallback）へ。frontier 幅 ≤ 32 は alloc ゼロ。Phase 0 実測 frontier max=1-3 で固定長上限を安全決定。computeAll は 1000コミットで −1998（≈2/commit）、computeIncremental は delta 200 で −400。

### §6.1 *Msg API（take の基盤・振る舞い不改変）
`update(model, msg: *Msg)` へ。reducer が `Msg.LogLoaded.substrate` を take できる基盤。171 テスト呼出点更新（literal/借用は `updateRef` helper・所有 payload は `&msg`）。ms/allocs への直接影響なし（§6.2 の take を可能にする）。

---

## 全プロファイル・Phase 2 対象フェンス（ReleaseFast）

### topology.parse（§6.2 arena）

| profile | Phase 0 allocs | Phase 2 allocs | Δ |
|---|---|---|---|
| linear | 4016 | 20 | −3996 |
| wide-branches | 4070 | 20 | −4050 |
| periodic-merge | 5293 | 20 | −5273 |
| path-filter-sparse | 4016 | 20 | −3996 |
| author-filter-sparse | 4016 | 20 | −3996 |
| long-subject-refs | 4016 | 20 | −3996 |

### graph.computeAll（§6.3 SBO）

| profile | Phase 0 allocs | Phase 2 allocs | Δ |
|---|---|---|---|
| linear | 4007 | 2009 | −1998 |
| wide-branches | 4018 | 2011 | −2007 |
| periodic-merge | 4119 | 2010 | −2109 |
| path-filter-sparse | 4007 | 2009 | −1998 |
| author-filter-sparse | 4007 | 2009 | −1998 |
| long-subject-refs | 4007 | 2009 | −1998 |

### runLogInt filter（§6.2 clone 廃止）

| profile | Phase 0 allocs | Phase 2 allocs | Δ |
|---|---|---|---|
| linear | 10061 | 6065 | −3996 |
| wide-branches | 10138 | 6088 | −4050 |
| periodic-merge | 11452 | 6179 | −5273 |
| path-filter-sparse | 10061 | 6065 | −3996 |
| long-subject-refs | 10070 | 6074 | −3996 |

※ author-filter-sparse は filter="Bench Generator" が 0 件（プロファイルがコミット毎に author 上書き）・substrate 取得自体は走るため参考値。

---

## 所感・残課題

- **Phase 2 の主要効果は alloc 数削減**（topology.parse −99.5% / computeAll −50% / runLogInt filter −40%）。ms は純粋関数が既に <1.5ms（ReleaseFast）のため劇的改善は無いが、10万コミットで線形効く fragmentation・GC 圧力・cache locality 改善が本命。
- **runLogInt（子プロセス実行）が依然 ms 支配的**（18-57ms）。これは Phase 2/3 の対象外（git 子プロセスの直列実行・spec §1.1）。paging（`runLogPageInt`）は効率的・初回ロードの直列実行が上限。
- **frontier HashMap（§6.4）は延期**: frontier max=1-3 で効果薄。Phase 2 計測でも computeAll は 0.05-0.11ms で热点化せず。広い分岐 profile（10万相当）で再評価。
- **projection cache（§7）は Phase 3**: filter paging 時の全再投影（`graph_project.project` 5023 allocs）が残る。Phase 2 で substrate parse/clone が改善されたので定数倍は下がった。30fps 未達なら Phase 3 で cache key（案 A/B）を設計。

## Phase 2 完了判定

- [x] §6.1(`*Msg`) + §6.2(arena+move) + §6.3(SBO) 完了・580/580 tests green・リークゼロ
- [x] topology.parse allocs 有意減少（4016 → 20）・computeAll（4007 → 2009）・runLogInt filter clone 廃止
- [x] `checkAllAllocationFailures` で handleLogLoaded/parse/project の OOM safety
- [x] CLAUDE.md/AGENTS.md へ所有権 move 例外追記（§8）
- [ ] whole-branch review 合格・main へ no-ff マージ（user 確認後）
