# パフォーマンス計渻 before レポート（Phase 0 Task 4 Step 3・codex m12）

Phase 1 最適化**前**の基線計測。ユーザー合意に従い **小規模（1000 コミット × 全6プロファイル）** で傾向把握し、10万コミットは省略する。

## 再現性メタデータ（m12）

- 計測コード commit: `0775bbc`（feat/perf-phase0-1 ブランチ・merge-base `3f61a00`）
- Zig version: 0.16.0
- 計測対象データ生成: `./bench/gen-history.sh <profile> 1000 bench/repos/<profile>-1000`（6 プロファイル）
- bench 実行: `zig build bench`（Debug）・`zig build bench -Doptimize=ReleaseFast`（ReleaseFast）
- 計測 API: `std.Io.Clock.now(.awake, io)` の timestamp 差分（codex B1・`std.time.Timer` は非存在）
- `bench/repos/` は生成物（`.gitignore` 対象・commit しない）

### フェンス一覧（spec §4.3・全て必須・codex M9）

| fence | 計測対象 | 入力 |
|---|---|---|
| `topology.parse` | `git rev-list --parents` 出力のパース | `substrate.txt` |
| `graph.computeAll` | 全コミット一括グラフ計算（frontier max 計測付き・codex m10） | `log.txt` → `[]log.Commit` |
| `graph.computeIncremental` | 増分計算（base 80% + delta 20%） | 同上 |
| `graph_project.project` | nearest-visible-parent 投影（substrate + visible） | `substrate.txt` + `log.txt` |
| `runLogInt (no-filter)` | `appcmd.run(.load_log)` 全体（headState/rev-parse/git log）・filter 空 | `bench/repos/<profile>-1000/` を cwd |
| `runLogInt (filter)` | 同上・filter 活性（fetchSubstrate 含む）・author="Bench Generator" | 同上 |
| `view.render 系` | `renderGraphCells`(可視窓50行) + `fitPane`（ArenaAllocator+CountingAlloc でフレーム相当） | `computeAll` 出力 |

> `view.render 系` は `renderDiff` を含まない（Model/zz.Context 構築が重いため）。`renderDiff` の 2 回走査（Task 6 対象）は Task 6 完了後に再測する。`renderGraphCells` が同一の `style.render` per-cell alloc パターンを担うため代表値として十分。

---

## ReleaseFast 計測（fps/latency・配布ビルド相当）

| fence | profile | commits | ms | allocs | peak_heap | note |
|---|---|---|---|---|---|---|
| topology.parse | linear | 1000 | 0.691 | 4016 | 204792 | extra=1000 |
| graph.computeAll | linear | 1000 | 0.398 | 4007 | 28462 | frontier=1 |
| graph.computeIncremental | linear | 1000 | 0.159 | 808 | 44257 | delta=200 |
| graph_project.project | linear | 1000 | 1.463 | 7021 | 323040 | visible=1000 |
| runLogInt (no-filter) | linear | 1000 | 51.531 | 6030 | 350305 | entries=1000 |
| runLogInt (filter) | linear | 1000 | 84.353 | 10061 | 617022 | entries=1000 |
| view.render 系 | linear | 1000 | 0.095 | 154 | 15366 | win=50 |
| topology.parse | wide-branches | 1000 | 0.217 | 4070 | 206760 | extra=1011 |
| graph.computeAll | wide-branches | 1000 | 0.096 | 4018 | 29365 | **frontier=3** |
| graph.computeIncremental | wide-branches | 1000 | 0.044 | 813 | 44583 | delta=200 |
| graph_project.project | wide-branches | 1000 | 1.240 | 6985 | 306768 | visible=1000 |
| runLogInt (no-filter) | wide-branches | 1000 | 43.617 | 6053 | 365731 | entries=1000 |
| runLogInt (filter) | wide-branches | 1000 | 84.428 | 10138 | 635674 | entries=1000 |
| view.render 系 | wide-branches | 1000 | 0.242 | 206 | 17066 | win=50 |
| topology.parse | periodic-merge | 1000 | 0.636 | 5293 | 249096 | extra=1284 |
| graph.computeAll | periodic-merge | 1000 | 0.378 | 4119 | 28564 | frontier=2 |
| graph.computeIncremental | periodic-merge | 1000 | 0.071 | 831 | 44285 | delta=200 |
| graph_project.project | periodic-merge | 1000 | 1.243 | 7243 | 328136 | visible=1000 |
| runLogInt (no-filter) | periodic-merge | 1000 | 56.075 | 6144 | 360779 | entries=1000 |
| runLogInt (filter) | periodic-merge | 1000 | 93.669 | 11452 | 700849 | entries=1000 |
| view.render 系 | periodic-merge | 1000 | 0.125 | 165 | 15706 | win=50 |
| topology.parse | path-filter-sparse | 1000 | 0.704 | 4016 | 204792 | extra=1000 |
| graph.computeAll | path-filter-sparse | 1000 | 0.349 | 4007 | 28462 | frontier=1 |
| graph.computeIncremental | path-filter-sparse | 1000 | 0.119 | 808 | 44257 | delta=200 |
| graph_project.project | path-filter-sparse | 1000 | 1.339 | 7021 | 323040 | visible=1000 |
| runLogInt (no-filter) | path-filter-sparse | 1000 | 52.177 | 6030 | 346313 | entries=1000 |
| runLogInt (filter) | path-filter-sparse | 1000 | 114.690 | 10061 | 613030 | entries=1000 |
| view.render 系 | path-filter-sparse | 1000 | 0.204 | 154 | 15366 | win=50 |
| topology.parse | author-filter-sparse | 1000 | 0.373 | 4016 | 204792 | extra=1000 |
| graph.computeAll | author-filter-sparse | 1000 | 0.153 | 4007 | 28462 | frontier=1 |
| graph.computeIncremental | author-filter-sparse | 1000 | 0.071 | 808 | 44257 | delta=200 |
| graph_project.project | author-filter-sparse | 1000 | 1.295 | 7021 | 323040 | visible=1000 |
| runLogInt (no-filter) | author-filter-sparse | 1000 | 56.370 | 6030 | 341233 | entries=1000 |
| runLogInt (filter) | author-filter-sparse | 1000 | 47.305 | 4046 | 287303 | entries=0 ※ |
| view.render 系 | author-filter-sparse | 1000 | 0.139 | 154 | 15366 | win=50 |
| topology.parse | long-subject-refs | 1000 | 0.818 | 4016 | 204792 | extra=1000 |
| graph.computeAll | long-subject-refs | 1000 | 0.248 | 4007 | 28462 | frontier=1 |
| graph.computeIncremental | long-subject-refs | 1000 | 0.119 | 808 | 44257 | delta=200 |
| graph_project.project | long-subject-refs | 1000 | 1.486 | 7021 | 323040 | visible=1000 |
| runLogInt (no-filter) | long-subject-refs | 1000 | 99.197 | 6039 | **1244447** | entries=1000 |
| runLogInt (filter) | long-subject-refs | 1000 | 137.368 | 10070 | **1511222** | entries=1000 |
| view.render 系 | long-subject-refs | 1000 | 0.147 | 154 | 15366 | win=50 |

※ `author-filter-sparse` の `runLogInt (filter)` は author="Bench Generator" が **0 件**（当プロファイルはコミット毎に `-c user.name` で Alice/Bob/Carol へ上書きするため）。substrate 取得自体は filter 非空で常に走る（allocs 4046 ≈ substrate parse 分）ため、substrate-fetch overhead の計測としては有効。

---

## Debug 計測（correctness + alloc 数・safety check 経路）

allocs / peak_heap は ReleaseFast と同一（最適化非依存）。ms は safety check で過大（純粋関数で 10-200 倍）。主な値（代表）:

| fence | profile | ms | allocs | peak_heap |
|---|---|---|---|---|
| topology.parse | linear | 109.264 | 4016 | 204792 |
| graph.computeAll | linear | 151.313 | 4007 | 28462 |
| graph.computeIncremental | linear | 14.100 | 808 | 44257 |
| graph_project.project | linear | 203.169 | 7021 | 323040 |
| runLogInt (no-filter) | linear | 195.537 | 6030 | 350305 |
| runLogInt (filter) | linear | 324.724 | 10061 | 617022 |
| view.render 系 | linear | 1.348 | 154 | 15366 |

> Debug の全行は `zig build bench` で再現可能（本レポートでは紙面省略・allocs/peak は上表 ReleaseFast と一致）。

---

## 観察と Phase 1-2 への示唆

### ホットパス（Phase 1 対象の優先順位付け）

1. **`runLogInt` が支配的**（43-137ms / 1000コミット）。純粋関数（topology.parse/computeAll/project）は 0.1-1.5ms で**1桁以上小さい**。ボトルネックは git 子プロセス実行（headState + rev-parse + git log + fetchSubstrate）。
   - Phase 1 の局所最適化（Task 5-9）は純粋関数の **alloc 数削減** が主目的・ms 削減効果は小さい（runLogInt の子プロセス待ちが効かないため）。ただし **paging 毎の deep-copy**（`appendLogCommits`・Task 5）は 10万コミットで線形効くので実施意義あり。
2. **`graph_project.project` の allocs = 7021**（1000コミット）。Task 8（`mkDerived` 二重 dupe 解消）の効果検証対象。現在 visible 1件 ≈ 7 allocs。
3. **`topology.parse` の allocs = 4016 / peak 200KB**（1000コミット＝hash+parents 個別 dupe）。Phase 2 の `TopologySubstrate` arena 化（§6.2）の根拠。10万コミットで線形増大。
4. **`view.render 系` = 154-206 allocs/フレーム**（50行窓）。Task 7（`renderGraphCells` ANSI cache）で allocs ゼロ化を目指す。ms は既に 0.1-0.24ms で小さいが、60fps（16.6ms/フレーム）余裕は大きい。

### Phase 2 設計資料（codex MAJOR 4/5/6 反映）

- **frontier max 実測**（Phase 2 SBO 上限設計の根拠）:
  - linear=1, wide-branches=**3**, periodic-merge=2, 他=1（1000コミット・gen-history の merge が末尾集中のため小さい）
  - wide-branches は frontier=3 のみ → 実運用（同時進行分岐が多い repo）では更大。Phase 2 SBO（small-buffer optimization）の固定長上限は 1000コミットベースでは**安全決定できない**（spec §0 MAJOR 4 の指摘通り）。10万相当の広い分岐プロファイルで再測が望ましいが、Phase 2 設計では **SBO + heap fallback**（上限超過時ヒープへ逃がす）を採用すれば安全。
- **peak heap 実測**（Phase 2 TopologySubstrate arena backing 選定の根拠）:
  - substrate parse peak: ~200-250KB / 1000コミット。10万コミットで ~20-25MB 想定（線形）。
  - long-subject-refs の runLogInt peak = **1.5MB**（長い日本語 subject の log 出力バッファ）。substrate limit env 化（Task 9・既定 64MiB）で十分余裕。

### Phase 1 完了判定（spec §2.4 exit gate）

Phase 1 完了後に `zig build bench` 再実行 → `bench/report-after-phase1.md` へ比較。exit gate:
- `appendLogCommits` paging alloc ≤ 新規件数 + O(1)（Task 5・ paging シナリオで検証）
- `graph_project.project` allocs 減少（Task 8・二重 dupe 解消）
- `view.render 系` allocs ゼロ化（Task 7・ANSI cache）
- `renderDiff` 1 回走査化（Task 6・別途ユニットテストで検証）

---

## Phase 0 完了

- [x] `zig build bench` 動作（Debug + ReleaseFast）
- [x] 6 プロファイル × 1000コミットで before 計測レポート確定（commit hash / Zig version / build mode 凍結）
- [x] frontier max 実測（Phase 2 SBO 設計資料）
- [x] substrate entries / peak heap 実測（Phase 2 arena / limit 設計資料）
- [x] 566/566 tests green（Debug・リークゼロ）
