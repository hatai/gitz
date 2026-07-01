# パフォーマンスチューニング全体設計（メタ spec）

- 日付: 2026-06-30（rev.2: 計画レビュー codex 指摘反映 + 第2回 spec レビュー codex 指摘 BLOCKER2/MAJOR3/MINOR2 の Phase 0-1 関連を反映・Phase 2/3 詳細は未固定）
- 対象: TODO 2（log view）実装完了後の**予防的パフォーマンスチューニング**。大規模リポジトリ（目標 10万コミット）での 30fps 維持と無駄アロケーション削減。
- 性格: 現状遅いと感じている操作は**無い**。大規模対応・将来堅牢性のための事前整備。
- 関連: TODO 2 phase 1-3b 完了（`TODO.md:151-201`）・phase3b #2 graph 投影（`docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md`）・busy lifecycle（`docs/superpowers/specs/2026-06-24-todo2-busy-lifecycle-design.md`）・StreamTooLong limit seam（`docs/superpowers/specs/2026-06-23-todo2-streamtoolong-limit-seam-design.md`）。

本 spec は**全体設計判断と Phase 構成を固定**し、各 Phase の実装詳細（コードの完全な形・タスク分解・テストケース）は各 Phase plan（`docs/superpowers/plans/2026-06-30-perf-phase*.md`）へ委ねる。各 Phase は独立 spec/plan → codex review → SDD の順で実施する（§11）。

---

## 0. 計画レビュー codex 指摘対応表（rev.0 → rev.1）

rev.0 計画を codex（read-only sandbox・実コード検証）へレビューさせた結果、**Issues Found**（BLOCKER 2 / MAJOR 4 / MINOR 2 / NIT 1）。Phase 0-1 方向性は妥当だが、Phase 1-5 のリスク誤判定・Phase 2 の設計分割欠陥・Phase 3 の C1 妥当性欠陥を指摘。全面反映:

| 指摘 | 重要度 | 内容 | 対応 |
|---|---|---|---|
| Phase 2-1 | **BLOCKER** | `main.zig:229-239` の `update.update(&app.model, msg)` は **Msg 値渡し**。reducer 内で `ll.substrate` を Model へ move しても呼出元 `msg` のコピー残りを null 化できず、`Model.topology_substrate` と `Msg.deinit`（`messages.zig:145-149`）が同じ substrate を解放する（二重 free） | **反映**: Phase 2-1 の前提として `update(*Model, *Msg)` API へ変更を必須化（§6.1）。値渡し前提の全呼出点（`main.step`・テスト群）も一括更新 |
| Phase 2-1 | **BLOCKER** | stale reject / `replaceLogCommits` / `setLogSnapshotTip` / clone / projection / computeAll の段階的失敗各時点で「誰が substrate を解放するか」未定義。move 化は現行 clone の安全性を捨てる変更 | **反映**: take は stale reject と entries 適用成功後・`setTopologySubstrate` 直前に限定（§6.2）。take 後失敗時は `model.clearTopologySubstrate()` または局所 owner deinit。`checkAllAllocationFailures` で `handleLogLoaded filter+substrate` OOM safety をテスト固定 |
| Phase 3 | **MAJOR** | 「derived 差分更新」は C1 を壊す。`update.zig:661-678` の実装コメント・回帰テスト `:3189-3228` が、未ロードページに最近親可視祖先がある場合の既存 row parent 変更を理由に全再投影を強制している。`computeIncremental` は既存 row を再処理しない | **反映**: Phase 3 の第一候補を「**projection result cache + 全 computeAll 維持**」へ変更（§7）。差分更新は C1 再配線仕様（descendants 影響・再構築単位）を独立 spec で先定義した上で、Phase 2 計測で projection cache でも目標未達の場合のみ第二候補として扱う |
| Phase 1-5 | **MAJOR** | `processCommit`（`graph.zig:190-331`）の `match_lanes`/`agg_lanes`/`before_has` スタック配列化は**低リスクでない**。frontier 幅 = 同時生存分岐数で 10万コミット想定では固定長上限を安全決定できない（TODO.md 留意点「レーン割当は同時生存分岐数」）。上限超過時の描画欠落/panic/silent truncation | **反映**: Phase 1（低リスク）から**除外し Phase 2 へ移動**（§6.3）。Phase 0 で実測 frontier max を測り **SBO（small-buffer optimization）+ heap fallback** で対応 |
| Phase 1-6 | **MAJOR** | 64MiB limit は `process.runWithLimit` の **stdout limit の話**で heap 使用量を保証しない。`topology.parse`（`topology.zig:62-104`）後の個別 dupe/Entry/HashMap で heap は stdout より大きい | **反映**: Phase 0 計測へ peak heap / substrate entries / parents 総数 / HashMap capacity 追加（§4）。substrate limit 設定は **build option でなく runtime env/CLI option**（`GIT_TUI_SUBSTRATE_LIMIT`）へ（§9） |
| Phase 2-3 | **MAJOR** | 「単一アリーナ確保」は `TopologySubstrate`（`topology.zig:17-55`）の deinit/clone/`hash_index` key 寿命/Model 保存を全部変える。Phase 2-1（clone 廃止・move）と Phase 2-3（arena）は**実質同じ設計問題で強く結合**。分離小変更は危険 | **反映**: Phase 2 を**統合**（§6）。clone 廃止・move semantics・arena 化を `TopologySubstrate` 一体再設計として同じ Phase で扱う（§6.2） |
| Phase 0 | **MINOR** | benchmark を Debug だけで測ると過大に悲観的。ReleaseFast だけだと safety check/OOM 経路の回帰を見落とす | **反映**: `zig build bench` は Debug（correctness + alloc 数）/ ReleaseFast（fps/latency）を分離測定（§4）。`zig build test` は従来どおり Debug 維持 |
| Phase 0 | **MINOR** | 1千/1万/10万 commits の線形履歴だけでは graph frontier/merge parent/projection C1/HashMap メモリ負荷が測れない | **反映**: プロファイルを linear / wide branches / periodic merge / path-filter sparse / author-filter sparse / long subject-refs へ多様化（§4） |
| 全体 | **NIT** | 「561+ tests」等の固定数表記は実装進行でズレる | **反映**: 本 spec では「**現行全テスト数 + 新規テスト**」と書き、実行時の `zig build test --summary all` 出力を各 Phase のレポートへ記録する方針 |

**codex 総評（rev.0→rev.1）**: 「Phase 0 と Phase 1 の明らかな局所最適化のみ可。Phase 2-1 は現行値渡し API では BLOCKER。Phase 3 は C1 保証を壊さない差分更新仕様が出るまで承認不可」。→ 本 rev.1 は上記全面反映で BLOCKER 0 の設計へ昇格。

### 0.1 第2回 spec レビュー codex 指摘対応表（rev.1 → rev.2）

rev.1 spec を codex（read-only sandbox・実コード検証）へレビューさせた結果、**Issues Found**（BLOCKER 2 / MAJOR 3 / MINOR 2）。前回指摘は大枠反映されたが、rev.1 で新たに Phase 2/3 の correctness blocker が発生。Phase 0-1 関連を rev.2 へ反映、Phase 2/3 詳細は未固定（Phase 0 計測後に別途設計セッションで固定）:

| 指摘 | 重要度 | 内容 | 対応 |
|---|---|---|---|
| §7 | **BLOCKER** | projection cache の cache key 未定義。`nearestVisibleAncestor` は substrate だけでなく現在の visible_set に依存。未ロードページに可視祖先が後から現れると以前 `null` だった結果が hash に変わる（C1 再破壊） | **Phase 3 未固定**（§7）: cache key を `snapshot_tip + filter identity + loaded visible len` へ、または cache 対象を visible_set 非依存の immutable topology lookup へ限定。C1 回帰テスト必須。Phase 2 計測後・Phase 3 plan 前に別途設計セッションで固定 |
| §6.4 | **BLOCKER** | `frontier_index: hash -> frontier index` 単一 index では H-01 重複親集約（`match_lanes.items[1..]` 水平接続・`graph.zig:193-237,316-329`）を表現できない | **Phase 2 未固定**（§6.4）: multi-map（`hash -> SmallBuf(usize)`）または「match_lanes 全列挙は線形走査を残し、第一親/追加親の存在確認だけ HashMap 化」。index 再同期戦略も明記。Phase 2 plan 前に別途設計セッションで固定 |
| §6.2 | **MAJOR** | TopologySubstrate arena 設計が `ArenaAllocator` と単一 `[]u8` バッファの二択のまま。parents slice 配列の確保場所・hash_index key 寿命・OOM 状態遷移が未定 | **Phase 2 未固定**（§6.2）: Phase 2 plan 前に backing 採用・entries/parents slice 確保場所・hash_index.deinit と backing 解放順・OOM errdefer 状態遷移を固定 |
| §2.3 | **MAJOR** | 成功基準に Phase 0 後の go/no-go（exit gate）がない。「線形」「比例しない」が定性 | **反映**: §2.4 へ Phase ごとの定量 exit gate を追加 |
| §8 | **MAJOR** | 所有権例外の文言「`Msg.LogLoaded.substrate` 等」が他 payload へ波及リスク。AppCmd は現行維持すべき | **反映**: §8 を「現時点では `Msg.LogLoaded.substrate` のみ」へ限定。追加は個別 spec + takeXxx helper + OOM safety test 必須と明記 |
| §6.1 | **MINOR** | `update(*Model, *Msg)` 呼出点説明が不正確。`RuntimeModel.update`（zigzag trait・`main.zig:329`）は値渡し維持。変更は純粋 reducer のみ | **反映**: §6.1 を「zigzag trait は変更せず・純粋 reducer のみ `*Msg` 化・step で var msg 化・テストは var msg 形式へ一括変換」へ正確化 |
| §5.5/§9 | **MINOR** | env/CLI 化と言いつつ CLI 仕様がない（定義は env のみ） | **反映**: §5.5/§9 を「env 化」へ（Phase 1 は env のみ）・CLI は将来拡張扱いへ |

**codex 総評（rev.1→rev.2）**: 「Phase 0-1 plan へ進むなら、Phase 2/3 の該当箇所を『未固定・要再 spec』と明示してからなら進行可能」。→ 本 rev.2 は Phase 2/3 を「未固定」明記（§6.2/§6.4/§7）し、Phase 0-1 関連（§2.4/§6.1/§8/§5.5/§9）を反映。Phase 0-1 plan 執筆可能。

---

## 1. 背景 & スコープ

### 1.1 現状のパフォーマンス特性（read-only 調査サマリ）

主要ホットパスと懸念（`file:line` 参照）:

- **git プロセス実行（直列）**: `runLogInt`（`appcmd.zig:175-249`）初回ロードで最大 3-5 プロセス直列（`headState` 最悪 3 + rev-parse + git log + filter 活性時 `fetchSubstrate` で `git rev-list`）。paging（`runLogPageInt:309-352`）は tip 固定で git log 1 プロセスのみ・効率的。
- **グラフ計算**: `computeAll`（`graph.zig:87-117`）O(N×L)・`computeIncremental`（`:126-188`）は H-08 O(N²) 回避済み（deep-copy 無し）。`processCommit`（`:191-332`）frontier 線形走査 4-5 回 + 1コミット 3-4 個小アロケーション。
- **graph 投影（フィルタ時）**: `graph_project.project`（`graph_project.zig:19-57`）は substrate + visible → 投影・O(N) 償却（第一親チェーン・メモ化）。`memo.put(cur, result) catch {}`（`:132`）で OOM 無視設計。
- **paging 再計算**: `handleLogPageLoaded`（`update.zig:641-705`）で filter 活性時は paging 毎に**全 loaded commits 再投影 + computeAll**（`:666-678`）。C1 cross-page 辺接続のため意図的（コメント `:660-665`）。
- **topology parse/clone**: `topology.parse`（`topology.zig:62-105`）は hash/parents を個別 dupe で O(N×P) アロケーション。`clone`（`:28-55`）は全件 deep-copy・`handleLogLoaded` で呼出（`update.zig:606`）。
- **描画**: `fitPane`（`view.zig:686-721`）毎フレーム East Asian Width 計算（`zz.width`）。`renderGraphCells`（`:462-489`）各セル個別 ANSI render（最大 20/行 × 50 行 ≒ 1000 小アロケーション/フレーム）。`renderDiff`（`:301-369`）diff_text 2 回走査。
- **アロケーション**: `appendLogCommits`（`model.zig:280-300`）paging 毎に全コミット deep-copy。`FilterSpec.clone`（`filter.zig:102-113`）。
- **計測インフラ**: **一切存在しない**。`build.zig` は `addTest` のみ・`std.time` の利用は日付計算/autorefresh 間引きのみ・CI は functional QA のみ。

### 1.2 スコープ（IN / OUT）

**IN（本 spec 対象）**:
- Phase 0: 計測インフラ整備（benchmark exe・大規模履歴ジェネレータ・フェンス計測）
- Phase 1: 低リスク局所最適化（paging deep-copy 廃止・描画 2 回走査解消・ANSI 有限集合キャッシュ・二重 dupe 解消・substrate limit env/CLI 化）
- Phase 2（統合）: `update(*Model, *Msg)` API 変更・`TopologySubstrate` 一体再設計（arena + move + clone 廃止）・`processCommit` SBO・frontier HashMap 化
- Phase 3: projection result cache + 全 computeAll 維持（第一候補）

**OUT（将来・非目標）**:
- git プロセスプール化/常駐化（設計変更大・WSL2 以外では影響小）
- 描画の差分更新（zigzag 描画モデル自体の変更）
- 所有権規約の全面的 ARC 化
- filter paging 差分更新（C1 再配線）は Phase 2 計測で projection cache でも目標未達の場合のみ独立 spec 化

### 1.3 プロダクト判断（Open decisions・ユーザー承認済）

1. **対象領域**: 全領域（ログ取得・グラフ計算 / フィルタ時投影・paging / 描画 / メモリ）。
2. **性格**: 予防的チューニング。現状遅い操作は無いが大規模対応の事前整備。
3. **対象規模**: **10万コミット**想定（substrate limit 設定基準）。
4. **範囲**: **Phase 0-3 全完了**。
5. **所有権規約（`CLAUDE.md:55-57`）への局所的 move semantics 例外**: **許容**。CLAUDE.md へ例外規約を追記（§8）。

---

## 2. ゴール・非目標・成功基準

### 2.1 ゴール
10万コミットの大規模リポジトリで、フィルタ適用時 paging を含む全操作が **30fps を維持**し、無駄アロケーションを大幅削減する。全最適化は `std.Io.Clock.now`（Zig 0.16 実 API・`init.io` 経由）計測で定量検証し、正確性（現行全テスト数 + 新規テスト・リーク検出）を一切損なわない。

### 2.2 非目標
- git プロセスプール化/常駐化
- 描画の差分更新（zigzag 描画モデル変更）
- 所有権規約の全面 ARC 化

### 2.3 成功基準（Phase 0 計測で基準値を確定し各 Phase で検証）
- **fps**: 10万コミット・wide-branches プロファイルでスクロール/選択移動が 30fps（≤33ms/frame）を維持
- **filter paging**: 10万コミット・author-filter sparse で paging 累積レイテンシが線形（O(K)・K=ページ数）に抑えられること
- **アロケーション**: `appendLogCommits` paging 1 回あたりの alloc 数が 既存コミット数に比例しない（新規分のみ）
- **substrate**: 10万コミットで `fetchSubstrate` が StreamTooLong で失敗しない（limit 64MiB 既定）
- **正確性**: 現行全テスト + 新規テストが全て緑・`std.testing.allocator` でリーク検出無し

### 2.4 Phase ごとの exit gate（go/no-go・codex MAJOR 4 反映）

成功基準（§2.3）を各 Phase 完了時に定量で判定し、未達時の対応を明示:

| Phase | exit gate（定量） | 未達時の対応 |
|---|---|---|
| Phase 0 | before 計測レポートが全プロファイル・全フェンスで取得済み・frontier max / peak heap 実測値確定 | （基準値そのもの・未達概念なし） |
| Phase 1 | `appendLogCommits` paging 1 回の alloc 数 ≤ 新規件数 + O(1)（10万コミット・wide-branches）・現行全テスト緑・リークゼロ | Phase 2 で追加検証（move 実装の見直し） |
| Phase 2 | 10万コミット・author-filter sparse で **filter paging p95 ≤ 33ms/page**・`handleLogLoaded` filter+substrate の `checkAllAllocationFailures` 全通過・現行全テスト緑 | Phase 3（projection cache 強化・必要なら差分更新独立 spec）を**必須化** |
| Phase 3 | 10万コミット・全プロファイルでスクロール/選択移動が 30fps（≤33ms/frame）・成功基準 §2.3 全項クリア | 差分更新（C1 再配線）独立 spec を新設し再実装 |

各 Phase で「現行全テスト + 新規テストが緑・`std.testing.allocator` でリークゼロ」は**全 Phase 共通の必須 exit gate**。

---

## 3. Phase 構成の全体像

```
Phase 0 (計測インフラ) ─────────────────┐
  before 計測レポート                    │
  frontier max 実測 ────────────────┐   │
  peak heap / HashMap capacity ──┐  │   │
                                 │  │   │
Phase 1 (低リスク局所) ◀─────────┼──┼───┤
  appendLogCommits move          │  │   │
  renderDiff 1 回化              │  │   │
  renderGraphCells ANSI cache    │  │   │
  mkDerived 二重 dupe 解消       │  │   │
  substrate limit env/CLI 化 ◀──┼──┘   │
                                 │      │
Phase 2 (統合・API 変更) ◀────────┼──────┤
  update(*Model, *Msg) API       │      │
  TopologySubstrate 一体再設計 ◀─┘      │
  processCommit SBO ◀──────── frontier max
  frontier HashMap 化                   │
                                         │
Phase 3 (projection cache 第一) ◀───────┘
  Phase 2 計測で目標達成なら cache 強化のみで完了
  未達なら差分更新（C1 再配線）を独立 spec 化
```

**依存関係の原則**:
- Phase 0 は全 Phase の前提（計測なくして最適化の正当性なし）
- Phase 1 は Phase 0 後に単独実施可能（低リスク・正確性不変）
- Phase 2 は Phase 0 の frontier max / heap 実測が SBO 上限設計に必須
- Phase 3 の要否・内容は Phase 2 計測で確定

---

## 4. Phase 0: 計測インフラ整備

### 4.1 benchmark exe（`src/bench.zig`）
- `build.zig` へ `bench` exe 追加（`zig build bench`）。テスト（`zig build test`）とは完全分離。
- **Debug / ReleaseFast 分離測定**:
  - Debug 既定: correctness 検証 + **alloc 数計測**（safety check 経路含む）
  - `zig build bench -Doptimize=ReleaseFast`: fps/latency（配布ビルド相当）
- `zig build test --summary all` は従来どおり **Debug 固定維持**（AGENTS.md 規約遵守）。

### 4.2 大規模履歴ジェネレータ
プロファイルを負荷形状ごとに分離（codex MINOR 8 反映）:

| プロファイル | 目的 |
|---|---|
| linear | 基線（parent=1 のみ） |
| wide-branches | frontier 幅最大・HashMap/線形走査負荷 |
| periodic-merge | merge commit 多発・`processCommit` parent 2+ 経路 |
| path-filter-sparse | path filter で visible が疎・投影 gap 大 |
| author-filter-sparse | author filter で visible が疎・projection memo 効率 |
| long-subject-refs | East Asian Width / truncation 負荷（描画） |

各 1千 / 1万 / 10万 コミットで生成。スクリプトは `bench/gen-history.sh`（git 操作のみ・Zig 実装しない）。

### 4.3 フェンス計測（`std.Io.Clock.now`・Zig 0.16 実 API・codex BLOCKER 1 反映）
主要フェンスの ms・alloc 数・peak heap:

- `runLogInt`（初回ロード全体・`headState`/rev-parse/git log/`fetchSubstrate` の内訳）
- `topology.parse` / `topology.clone`（clone は Phase 2 で廃止前の基線）
- `graph.computeAll` / `graph.computeIncremental`
- `graph_project.project`（filter 活性時・paging 毎の累積）
- `view.render`（フレーム毎・`fitPane`/`renderGraphCells`/`renderDiff` 内訳）

### 4.4 リソース計測（codex MAJOR 5 反映）
- **peak heap bytes**（`std.heap.GeneralPurposeAllocator` の统计または custom allocator ラップ）
- **substrate entries 数 / parents 総数 / HashMap capacity**
- **frontier max**（`graph.computeAll` 実行中・Phase 2 SBO 上限設計資料）

### 4.5 成果物
- `bench/report-before.md`: 各フェンス・各プロファイルの ms/alloc/heap 表（10万コミット热点地図）
- frontier max 実測値（Phase 2 SBO 固定長上限の根拠）
- substrate entries/parents 総数（Phase 2 arena バッファサイズ・limit 設定の根拠）

---

## 5. Phase 1: 低リスク局所最適化（正確性不変）

全タスク正確性不変・現行全テスト緑維持・所有権規約不改変。

### 5.1 `appendLogCommits` move（`model.zig:280-300`）
現状は既存 items + 新規 entries を全て `cloneCommit` で deep-copy して unified list を構築 → swap。既存 items は**再 dup が無駄**。

**変更**: 既存 items の所有権を新しい ArrayList へ **move**（clone しない）・新規 entries のみ `cloneCommit` → 旧 ArrayList の items バッファは新 ArrayList へ移譲し、旧は空のまま解放。トランザクショナル性（OOM で既存 Model 状態を壊さない）は `ensureTotalCapacity` + errdefer で維持。

### 5.2 `renderDiff` 1 回走査化（`view.zig:301-369`）
現状は `total_lines` カウント（`:314-316`）と描画（`:341-366`）で `splitScalar` を 2 回呼ぶ。

**変更**: line count を描画ループ内で取得（row インデックスが高さ上限へ達した時点で break・残行数は捨てる）。1 回走査へ統合。

### 5.3 `renderGraphCells` ANSI 有限集合キャッシュ（`view.zig:462-489`）
現状は各セル（最大 20/行）で個別に `style.render(a, ch)` を呼び ANSI 文字列を確保。毎フレーム数百個の小アロケーション。

**変更**: 6色 × 数種 box 文字（`│●╵╷─╴╶` 等・有限集合）の ANSI render 結果を**プロセス持続の静的キャッシュ**（`?[][]u8`・初回 lazy 初期化・`ctx.persistent_allocator` で確保）へ格納。セル描画はキャッシュ参照のみで alloc ゼロ。

### 5.4 `mkDerived` 二重 dupe 解消（`graph_project.zig:84,154`）
現状は `projectedParents`（`:84`）で dupe し、その後 `mkDerived`（`:154`）で再度 dupe される二重コピー。

**変更**: `projectedParents` の slice を `mkDerived` へ所有権移譲（二重 dupe 廃止）。`freeDerived` 側で一括解放。

### 5.5 `substrate` limit env 化（`process.zig:28`・`appcmd.zig`・codex MINOR 7 反映）
現状は `default_stream_limit = .limited(16 * 1024 * 1024)` 固定（`process.zig:28`）。10万コミットで `fetchSubstrate` が StreamTooLong で失敗する恐れ。

**変更**:
- 既定を **64MiB** へ引き上げ（10万コミット・`rev-list --parents` 出力 ≈ 15-18MiB の余裕）
- **runtime env `GIT_TUI_SUBSTRATE_LIMIT`（MiB単位）** で上書き可能（codex MAJOR 5: build option でなく runtime・本番利用者の repo サイズに合わせて調整可能）
- `appcmd` 初期化で env を読み `process` の limit へ反映。env 無し/不正値は既定 64MiB
- **CLI option（`--substrate-limit-mib` 等）は Phase 1 範囲外（将来拡張・優先順位・`--no-mouse` との parse 順は別途検討）**

### 5.6 検証
- before vs after 計測（Phase 0 レポートと比較）
- 現行全テスト + 新規テスト（各タスクのユニットテスト・`appendLogCommits` move の OOM safety・ANSI cache の lazy 初期化・limit env パース）が緑
- tmux pty で wide-branches/long-subject-refs プロファイルの表示崩れなし

---

## 6. Phase 2: 所有権 / arena 統合（中リスク・API 変更含む）

**本 Phase は codex MAJOR 6 を受け clone 廃止（move）と arena 化を `TopologySubstrate` の一体再設計として扱う。分離実施は危険**。

### 6.1 `update(*Model, *Msg)` API 変更（codex BLOCKER 1 解消）

現状: `pub fn update(model: *Model, msg: Msg) !AppCmd`（`update.zig:23`）。`main.step`（`main.zig:229-239`）は値渡しで `update.update(&app.model, msg)` を呼び、その後必ず `msg.deinit(app.gpa)`。

**変更**: `pub fn update(model: *Model, msg: *Msg) !AppCmd` へ（ポインタ渡し）。reducer が Msg のフィールド（`ll.substrate` 等）を take した場合、当該フィールドを null 化（disarm）して呼出元 `msg.deinit` が二重解放しないよう設計。

**呼出点更新**（codex MINOR 6 反映・正確化）:
- **zigzag trait `RuntimeModel.update`（`main.zig:329`・`pub fn update(self, msg: Msg, ctx)`）は変更しない**（zigzag が要求する signature・`docs/superpowers/plans/zigzag-api-notes.md:134-138`）
- 変更対象は**純粋 reducer `src/update.zig` のみ**: `pub fn update(model: *Model, msg: *Msg) !AppCmd` へ
- `main.step`（`main.zig:231-239`）は `var msg = msg_in;` 化済みの変数へ `update.update(&app.model, &msg)` へ（`&msg` 渡し）・`msg.deinit` は従来どおり step が実施
- `RuntimeModel.update`（`main.zig:329`）内から純粋 reducer を呼ぶ経路も `&msg` 渡しへ
- **テスト呼出の一括変換**: `update.zig` 内の `update(&m, .key_down)` のような literal 呼出は `*Msg` を渡せないため、`var msg = Msg{ .key_down = {} }; defer msg.deinit(a); var cmd = try update(&m, &msg);` 形式へ全て書き換え（`:1142` 等・100箇所以上）

**Msg 側の take helper**: `Msg.LogLoaded` に `takeSubstrate() ?TopologySubstrate` を追加（現在の `substrate` フィールドを null 化して値を返す）。`Msg.deinit` は null 化済みの substrate を解放しない。

### 6.2 `TopologySubstrate` 一体再設計（codex BLOCKER 2 / MAJOR 6 解消）

> **⚠️ 未固定（codex MAJOR 3）**: 本節の詳細設計（backing を `ArenaAllocator` か単一 `[]u8` バッファのいずれにするか・`entries`/`parents` slice 配列の確保場所・`hash_index.deinit()` と backing 解放順・空 substrate/OOM errdefer の状態遷移）は **Phase 0 計測後・Phase 2 plan 執筆前に別途設計セッションで固定**する。Phase 0-1 は本節の詳細に依存しない。

現状の `TopologySubstrate`（`topology.zig:17-55`）:
- `entries: []Entry`（各 `Entry` が `hash: []u8` / `parents: [][]u8` を個別所有）
- `hash_index: std.StringHashMap(usize)`（keys は `entries[].hash` を借用）
- `clone` は全件 deep-copy（`handleLogLoaded:606` で呼出）
- `deinit` は各 hash/parent を個別 free

**再設計**:
1. **backing arena フィールド追加**: `arena: ?std.heap.ArenaAllocator`（または単一連続 `[]u8` バッファ + オフセット表）。全 hash/parents 文字列をアリーナ内へ連続配置。`parse` の O(N×P) 個別 dupe を O(1) アロケーションへ。
2. **`hash_index` key 寿命**: keys は backing バッファ内の slice を借用（バッファ解放と HashMap 解放の順序を明示）。
3. **`clone` 廃止**: 代わりに Msg から Model へ **take（move）** で所有権移譲（§6.1 の `*Msg` API と組合せ）。`handleLogLoaded` で `ll.takeSubstrate()` → `model.setTopologySubstrate(sub)`。`Msg.deinit` は disarm 済みを解放しない。
4. **take の時点と失敗時解放**: take は stale reject 通過後・`replaceLogCommits` 成功後・`setTopologySubstrate` 直前に限定。take 後 projection/computeAll が失敗する場合は `model.clearTopologySubstrate()` で確実解放。
5. **OOM safety テスト**: `checkAllAllocationFailures` で `handleLogLoaded filter+substrate` の全 alloc 失敗点で「リーク無し・二重 free 無し・Model 半端状態無し」を固定。

### 6.3 `processCommit` SBO（codex MAJOR 4 解消）

`match_lanes` / `agg_lanes` / `before_has`（`graph.zig:193,207,229`）の小アロケーションを **SBO（small-buffer optimization）** へ。

- Phase 0 で実測した **frontier max**（例: wide-branches 10万コミットでの最大同時生存分岐数）を固定長上限 `[N]T` へ（N = frontier max + 余裕）
- 超過時は heap fallback（現行 ArrayList へ fallback・OOM まで続行）。描画欠落/panic/silent truncation を回避。
- SBO 構造体は `graph.zig` 内へ局所定義（`SmallBuf(T, N)` 等）。

### 6.4 frontier hash 検索 HashMap 化（`graph.zig`・**Phase 2 未固定・codex BLOCKER 2**）

> **⚠️ 未固定**: `hash -> frontier index` 単一 index では H-01 重複親集約（`match_lanes.items[1..]` 水平接続・`graph.zig:193-237,316-329`）を表現できない。Phase 2 plan 執筆前に以下いずれかへ固定:
> - **案 A**: multi-map（`hash -> SmallBuf(usize)`）で重複 slot 全列挙を可能にする
> - **案 B**: `match_lanes` 全列挙だけ線形走査を残し、第一親/追加親の存在確認だけ HashMap 化（部分最適化）
> 
> `insert`/compact 後の index 再同期戦略も Phase 2 plan で明記。

現状は frontier 内の hash 検索が `std.mem.eql` 線形（`:197,249,268`）。O(L)。Phase 2 で上記いずれかの案へ最適化する。

### 6.5 検証
- `update(*Model, *Msg)` API 変更で全呼出点更新漏れ無し（コンパイラが検出するはずだが一応 grep 網羅）
- `checkAllAllocationFailures` で `handleLogLoaded`/`handleLogPageLoaded` filter+substrate 全経路の OOM safety
- TopologySubstrate arena/move でリーク/二重 free ゼロ（`std.testing.allocator`）
- Phase 0 レポートと比較し alloc 数・peak heap が有意に減少
- codex plan review

---

## 7. Phase 3: projection cache 第一（高リスク・独立 spec）

> **⚠️ cache key 設計は未固定（codex BLOCKER 1）**: `nearestVisibleAncestor` は substrate だけでなく現在の visible_set に依存するため、cache key が未定義のままだと C1 を再び壊す。Phase 2 計測後・Phase 3 plan 執筆前に以下いずれかへ固定:
> - **案 A**: cache key を `snapshot_tip + filter identity + loaded visible len` へ（paging で visible が増えたら stale memo を再利用しない）
> - **案 B**: cache 対象を visible_set 非依存の immutable topology lookup（substrate 内の第一親チェーン等）へ限定
> 
> C1 回帰テスト（`update.zig:3189-3228` 相当）を Phase 3 plan の必須テストへ。

### 7.1 第一候補: projection result cache + 全 computeAll 維持（codex MAJOR 3 反映）

現状の `graph_project.project`（`graph_project.zig:19-57`）は paging 毎に全 loaded commits を再投影する（`update.zig:666-678`）。C1 cross-page 辺接続のため全再投影は**維持**する（差分更新は C1 を壊すため第二候補以下）。

**最適化**:
- **projection result cache**: substrate は不変（同一 snapshot_tip）なので、visible 集合の成長に対する投影結果をキャッシュ。`memo` 強化（現状 `memo.put(cur, result) catch {}` の OOM 無視を、arena 確保で OOM 耐性向上）。
- Phase 2 の `topology.parse` arena 化・clone 廃止で全再投影の定数倍が大幅改善 → projection cache で更に累積 O(K²) を実質 O(K) へ近づける。
- computeAll 自体は全件維持するが、Phase 2 の frontier HashMap 化・processCommit SBO で computeAll の定数倍も改善。

### 7.2 第二候補（条件付き・独立 spec）

Phase 2 完了後の計測で「projection cache + Phase 2 改善でも 10万コミット・filter paging で 30fps 未達」の場合のみ、差分更新（C1 再配線）を独立 spec 化:

- 既存 row の parent 再配線範囲・visible ancestor 発見時に影響を受ける descendants・GraphState rows/frontier の再構築単位を spec で先定義（codex MAJOR 3）
- 独立 spec → codex spec review → plan → codex plan review → SDD

### 7.3 完了判定
Phase 2 計測で成功基準（§2.3）を全て満たせば、Phase 3 は projection cache 強化のみで完了（差分更新は実施しない）。

---

## 8. 所有権規約への例外追記（CLAUDE.md 更新）

`CLAUDE.md:55-57` の現行規約:
> `Msg`/`AppCmd` のペイロードは Model を**借用せず複製所有**し、**消費者が `deinit`** する。

**例外追記（Phase 2 で実施・codex MAJOR 5 反映で限定）**:
> **例外（パフォーマンスチューニング・2026-06-30）**: **現時点では `Msg.LogLoaded.substrate` のみ**、reducer が Model へ所有権を **move（take）** できる。このため純粋 reducer `update` は `msg: *Msg`（ポインタ渡し）へ変更し、reducer が `Msg.LogLoaded.substrate` を take したら当該フィールドを null 化（disarm）して `Msg.deinit` の二重解放を防ぐ。take は stale reject 通過後・Model 適用成功後に限定し、take 後失敗時は Model 側で確実解放する。
>
> **AppCmd ペイロードは現行どおり**（解釈器が消費・deinit する複製所有規約を維持）。他の Msg バリアントへ move 例外を広げる場合は**個別 spec + `takeXxx()` helper + `checkAllAllocationFailures` による OOM safety test を必須**とする。

`AGENTS.md` の該当記述も同期更新。

---

## 9. substrate limit env 化（Phase 1-5 詳細・codex MINOR 7 反映）

- env 変数名: **`GIT_TUI_SUBSTRATE_LIMIT`**（MiB 単位・整数）
- 既定値: **64**（MiB）= `64 * 1024 * 1024`
- パース: `std.fmt.parseInt` で失敗/0 以下は既定へフォールバック（安全側）
- 適用先: `process.runWithLimit` の `stdout_limit` 引数（`fetchSubstrate` 呼出時・`appcmd.zig`）
- README へ環境変数の記載を追加（大規模リポジトリ利用者向け）
- **CLI option（`--substrate-limit-mib`）は Phase 1 範囲外**（将来拡張・優先順位・`--no-mouse` との parse 順は別途検討）

---

## 10. 検証・テスト規約

### 10.1 テスト（CLAUDE.md/AGENTS.md 準拠）
- 実装 `.zig` 内の `test {}`・`std.testing.allocator` 必須・新規 `.zig` は `src/root_test.zig` へ import 追加
- `zig build test --summary all` は **Debug 既定維持**（実行時安全チェック保持）
- Phase 2 の API 変更後は既存テストの `update(&m, ...)` 呼出を `update(&m, &msg)` 等へ一括更新
- `checkAllAllocationFailures` で OOM safety を `handleLogLoaded`/`handleLogPageLoaded` filter+substrate 経路へ拡充

### 10.2 計測（Phase 0 以降）
- 各 Phase 完了時に `zig build bench`（Debug + ReleaseFast）で before/after 比較レポート
- レポートは各 Phase の plan へ添付（または `docs/superpowers/perf-reports/` 配下）

### 10.3 手動検証
- tmux pty で wide-branches/long-subject-refs プロファイルの描画崩れ無しを確認（AGENTS.md「TUI の手動検証」）

---

## 11. ドキュメント構成・進め方

### 11.1 ドキュメント
| ドキュメント | 範囲 | タイミング |
|---|---|---|
| 本 spec（メタ） | 全体設計判断・Phase 構成・codex 対応表 | 今 |
| plan `2026-06-30-perf-phase0-1.md` | Phase 0 + Phase 1 | 本 spec 承認後 |
| plan `2026-06-30-perf-phase2.md` | Phase 2（統合・API 変更含む） | Phase 0-1 マージ後・frontier max 実測確定後 |
| spec+plan `2026-06-30-perf-phase3-projection-cache.md` | Phase 3 | Phase 2 マージ・計測後 |

### 11.2 進め方（プロジェクト確立フロー準拠）
1. 本 spec → codex spec review（read-only sandbox）→ user 承認
2. Phase 0-1 plan 執筆 → codex plan review → SDD（fresh subagent/タスク + タスクレビュー + 最終 whole-branch review）→ main へ no-ff マージ
3. before 計測レポート確定（Phase 0 成果）→ **Phase 2/3 詳細設計セッション**: §6.2 TopologySubstrate backing・§6.4 frontier HashMap（案 A/B）・§7 cache key（案 A/B）を確定（frontier max 実測で SBO 上限も）
4. Phase 2 plan 執筆 → codex plan review → SDD → マージ
5. Phase 2 計測 → Phase 3 要否判定・内容確定（§7 cache key 設計を反映）→ 独立 spec/plan → SDD → マージ
6. `TODO.md`・`CLAUDE.md`（所有権 move 例外・§8）・`AGENTS.md` 更新・README へ env 変数追記

---

## 12. 参照

- `CLAUDE.md`（規約・所有権 `:55-57`・Zig 0.16 落とし穴・描画 gotcha）
- `AGENTS.md`（コマンド・テスト規約・進め方）
- `TODO.md:151-201`（TODO 2 phase 1-3b 完了状況）
- `docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md`（graph 投影・C1）
- `docs/superpowers/specs/2026-06-24-todo2-busy-lifecycle-design.md`（busy lifecycle）
- `docs/superpowers/specs/2026-06-23-todo2-streamtoolong-limit-seam-design.md`（limit seam）
- `docs/superpowers/plans/zigzag-api-notes.md`（実 API）
