# 設計: フィルタ中の graph 維持（TODO 2 phase 3b #2）

- **日付**: 2026-06-26
- **関連**: `TODO.md` phase 3b #2（`TODO.md:196`）/ phase2 spec §G.4（`docs/superpowers/specs/2026-06-19-todo2-log-view-phase2-display-design.md:656-658`）/ phase3a spec §16/§18（`docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md:937,962`）/ phase3a risk B2/M2（同 `:35,44`）/ handoff `docs/superpowers/handoffs/2026-06-25-todo2-phase3b-graph-handoff.md`
- **状態**: 設計（ユーザ承認済）→ plan レビュー待ち

---

## 1. 背景・問題

フィルタ（author/since/until/paths）は**サーバ側**で実行される（`git log --fixed-strings --author=… --since=… --until=… <snapshot_tip> -- <paths>`・`commands.appendFilterOptions` `commands.zig:115-157` + `appendPaths` `:159-173`）。TUI はマッチした commit（= visible）のみ受け取る。

各 visible commit は**実の parent hash** を持つが、その parent 自体がフィルタ除外されている場合、さらに上へ辿るデータが返却 window 内に無い → 辺が宙に浮く。現状はこれを `graph_render_policy = .suppressed`（`model.zig:19,70`）で一律 graph 非表示にして回避:

- SET `.suppressed`: `handleApplyFilter` 内 `update.zig:791`（フィルタ種別問わず）。
- SET `.auto`: `handleClearFilter` `update.zig:814`。
- 計算スキップ: `handleLogLoaded` `update.zig:589-596` / `handleLogPageLoaded` `update.zig:626-628`。
- 描画ゲート: `view.zig:523`（`show_graph = ... and graph_render_policy == .auto`）・非表示理由 `view.zig:535-539`（`filterReasonText`）。

phase3a §16（`phase3a-filter-design.md:937`）は「graph policy は全フィルタで `.suppressed`（M1: 部分集合で topology 保証できない）。維持は nearest-visible-parent 投影（L 案）または Git history simplification（別案）を別 spec で検討」と明記。§18（`:962`）は L 案 = visible commit 間の最近親可視親を事前計算して既存 `processCommit`（`graph.zig:191-332`）へ入力・phase2 §G.4 活用、を記載。本 spec は L 案の具現化。

### 1.1 投影の正確性に必要なもの

visible commit だけでは投影を解決できない。visible commit C の実 parent P がフィルタ除外のとき、P のさらに親を辿る（= gap の祖先解決）データが無い。よって**フィルタ除外 commit を含む全祖先の topology（hash + 実 parents）** = **topology substrate** が別途必要。

### 1.2 path フィルタの罠

`git log -- <path>` のデフォルト history simplification（TREESAME）は、サーバ側で parent を「最近親の path 変更祖先」へ**書き換える**可能性がある。よって filtered log の `.parents` フィールドは path フィルタでは信用できない。本設計は**全フィルタ種で filtered log の `.parents` を無視**し、substrate から一貫して再導出する（均一化・§3.2）。

---

## 2. 解決の核心（1 行）

> **フィルタ適用時に全履歴の topology substrate（`git rev-list --topo-order --parents <snapshot_tip>`）を1回取得し、新規純粋モジュールが visible commit 間の最近親可視祖先へ parent を投影 → derived `[]log.Commit` を既存 `graph.computeAll`/`computeIncremental` へ入力。`graph.zig` は不変。substrate 取得失敗時は suppress へ安全劣化。**

これは必要十分: derived parents は常に visible set 内（祖先関係保存・非閉路）→ `processCommit` の frontier 機構が paging を含めて正しく動作（topo 順 newest-first なので投影親は常に「より後の行」に現れる）。

---

## 3. 設計

### 3.1 データフロー（フィルタ適用〜表示）

```text
apply_filter (update.zig)
  ├ filter_state 設定 / generation+=1 / clear snapshot tip / policy=.auto（★変更: suppressed→auto）
  └ return .load_log { filter }
        ↓
runLogInt (appcmd.zig)  ← filter 非empty のとき追加で substrate 取得
  ├ headState tri-state → rev-parse HEAD → snapshot_tip（既存・B1）
  ├ logArgv(filter) → filtered log（visible commits: 表示メタデータのみ使用・.parents 無視）
  ├ ★revListParentsArgv(snapshot_tip) → substrate（全履歴 hash+実parents）★
  │   失敗（exit≠0/StreamTooLong/OOM）→ substrate=null
  └ LogLoaded { entries, substrate: ?TopologySubstrate }
        ↓
handleLogLoaded (update.zig)
  ├ replaceLogCommits(entries) / setLogSnapshotTip（既存）
  ├ ★substrate 保存 → model.topology_substrate★
  ├ filter 活性かつ substrate 有 → ★graph_project.project → derived → computeAll★（policy=.auto）
  ├ filter 活性かつ substrate 無 → policy=.suppressed（現状の hide+理由）
  └ 無 filter → 従来 computeAll（policy=.auto）
        ↓
view.renderLog: graph_render_policy==.auto で graph 表示（変更不要）
```

paging（`handleLogPageLoaded`）: substrate は Model 保持済（load_log で1回取得）→ 新ページ分を投影 → `computeIncremental`。`load_log_page` は substrate 再取得しない。

### 3.2 投影の均一性（重要）

substrate は `git rev-list --parents <snapshot_tip>`（**フィルタ無し**・path 無し）= snapshot_tip から到達可能な全 commit の実 topology。visible set（filtered log の hash）は必ず substrate の部分集合。投影は**全フィルタ種で substrate の実 parents のみ**を使い、filtered log の `.parents` は一切参照しない。これにより path フィルタのサーバ側簡略化（§1.2）の影響を受けない。

### 3.3 topology substrate の構造と取得

**コマンド**（`commands.zig` 新設）:

```text
revListParentsArgv(a, snapshot_tip) -> OwnedArgv
  = ["git", "rev-list", "--topo-order", "--parents", snapshot_tip]
```

`snapshot_tip` は借用（logArgv と同様・`OwnedArgv` の owned に入れない）。`--topo-order` は logArgv と整合（commits.zig 既定）。`--parents` で各 commit の全 parents を `<hash> <p1> <p2> ...` 形式で得る。root は `<hash>` 単独。

**実行**（`appcmd.zig runLogInt`）: `process.runWithLimit(a, io, argv, cwd, log_limit)`（`default_stream_limit` 適用 → 大規模 repo で StreamTooLong → degrade）。exit≠0 / parse 失敗 / RunError は全て substrate=null へ正規化（filtered log 自体は LogLoaded へ返す・graph のみ劣化）。

### 3.4 新規モジュール: `src/git/topology.zig`（純粋・TDD）

```zig
pub const Entry = struct {
    hash: []u8,
    parents: [][]u8,
    pub fn deinit(self: *Entry, a: std.mem.Allocator) void { ... }
};

pub const TopologySubstrate = struct {
    entries: []Entry,                      // topo 順（newest-first）・rev-list 出力順
    hash_index: std.StringHashMap(usize),  // hash -> entries index（O(1) lookup・keys は entries[].hash を借用）
    pub fn deinit(self: *TopologySubstrate, a: std.mem.Allocator) void { ... }
};

/// `git rev-list --topo-order --parents <tip>` 出力をパース。
/// 各行 = "<hash>[ <parent>...]"（空白区切り・改行区切り・root は hash 単独）。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError!TopologySubstrate;
```

- 不正行（parent が 1 つも無い行は root 扱い = parents 空）は有効。
- 空入力（unborn 等）= entries 空・hash_index 空（valid）。
- OOM は `checkAllAllocationFailures` でリーク/二重解放無しを保証。

### 3.5 新規モジュール: `src/git/graph_project.zig`（純粋・TDD）

```zig
pub const ProjectedCommit = struct {
    hash: []u8,        // visible commit の hash を dupe（所有・computeAll が内部で dupe するため借用でも可だが所有で安全側）
    parents: [][]u8,   // 投影 parents（所有・最近親可視祖先 hash・重複排除済み）
};

/// substrate + visible commits から derived（投影）commits を構築。
/// 入力 visible は filtered log の表示順（topo newest-first）。出力 derived は 1:1・同順序。
/// 各 derived.parents は substrate 上の最近親可視祖先のみを含み、必ず visible set 内。
pub fn project(
    a: std.mem.Allocator,
    substrate: topology.TopologySubstrate,
    visible: []const log.Commit,
) Allocator.Error![]ProjectedCommit;
```

**アルゴリズム**（メモ化・全体 O(N)）:

```text
for each visible commit C (filtered log 順):
  proj = []
  for each real parent P of C (substrate.entries[hash_index[C.hash]].parents):
    a = nearestVisibleAncestor(P)        // 第一親チェーン追跡（git simplification 態例）
    if a != null and a not in proj: proj.append(a)
  derived.append({ hash: C.hash, parents: proj })

nearestVisibleAncestor(X):  // メモ化（HashMap hash->?hash）
  if X not in substrate.hash_index: return null   // 外部 commit（shallow 等）
  if X in visible_set: return X
  parents = substrate.entries[hash_index[X]].parents
  if parents.len == 0: return null                 // 実 root 到達・可視祖先無し
  return nearestVisibleAncestor(parents[0])        // 第一親へ再帰
```

**設計判断**: `nearestVisibleAncestor` は**第一親チェーン**（`git --simplify-by-decoration` 相当の予測可能挙動）を採用。merge は各 parent を独立解決し重複排除。第一親のみだとエッジ欠落が生じうるが、標準的な history simplification 態例であり tmux pty で目視検証し、必要なら all-parents DFS（探索幅優先）へ切替を検討（§8 未決点 4）。これにより derived graph は常に**非閉路**（投影先は厳密な祖先）かつ**投影 parents ⊆ visible set** を満たす。

### 3.6 graph.zig は不変（再利用）

`graph.computeAll(a, commits, generation, tip_hash)` / `computeIncremental(a, *state, new_commits)` は derived を `[]const log.Commit` 互換で受け取る。derived は computeAll の読み取り契約（`c.hash` と `c.parents` のみ参照・入力を free しない）を満たすため、**graph.zig の変更は一切不要**。既存 graph テスト（`graph.zig:373-607`）は全て維持・不変条件 `rows.items.len == commits_len`（`isInvariant` `graph.zig:76-83`）も derived が 1:1 なので保持。

**derived → log.Commit への適合**: computeAll は `c.hash`/`c.parents` のみ読む。derived（`ProjectedCommit`）を一時的に `log.Commit`（hash/parents のみ実値・他フィールドは空/ゼロ）へ詰め直すか、computeAll が `log.Commit` を取るための薄い変換を graph_project 側で行う。いずれにせよ derived バッファは compute 後に呼び出し側が解放する**一時**（Model には持たない）。

---

## 4. 統合（既存層への変更点）

### 4.1 messages.zig

`Msg.LogLoaded`（`messages.zig` LogLoaded 構造体）へフィールド追加:

```zig
.log_loaded: .{
    ...,                          // 既存: request_skip/request_max_count/request_generation/request_tip/is_unborn/entries
    substrate: ?topology.TopologySubstrate,  // ★追加（所有・filter 活性で非null・無 filter または substrate 失敗で null）★
}
```

`Msg.deinit` で substrate を deinit（null なら no-op）。`LogLoadFailed`/`LogLoadFailedSilent` は substrate 無し（既存どおり）。

### 4.2 model.zig

```zig
// フィールド追加（phase 2/3a ブロック・model.zig:67-70 周辺）
topology_substrate: ?topology.TopologySubstrate,   // filter 活性中のみ保持・clear_filter で解放
```

`Model.init` で `null`、`deinit` で解放。ヘルパ:

```zig
pub fn setTopologySubstrate(self: *Model, sub: topology.TopologySubstrate) void {  // 旧を deinit して swap
pub fn clearTopologySubstrate(self: *Model) void {                                 // deinit + null
```

### 4.3 update.zig

| 関数 | 変更 |
|---|---|
| `handleApplyFilter`（`:791`） | `graph_render_policy = .suppressed` → **`.auto`**（graph 欲しい）。substrate 無なら handleLogLoaded で suppressed へ。`invalidateLogGraph` は維持。 |
| `handleLogLoaded`（`:551-598`） | substrate（ペイロード）を `setTopologySubstrate` で保存（null なら `clearTopologySubstrate`）。filter 活性かつ substrate 有 → `graph_project.project` → derived → `computeAll`（policy=.auto）。filter 活性かつ substrate 無 → policy=.suppressed（graph スキップ・理由は view 既存）。無 filter → 従来 computeAll。 |
| `handleLogPageLoaded`（`:605-649`） | filter 活性かつ `model.topology_substrate` 有 → 新ページ分 `project` → derived → `computeIncremental`。filter 活性かつ substrate 無 → 従来スキップ。無 filter → 従来 incremental/computeAll switch。 |
| `handleClearFilter`（`:807-822`） | `clearTopologySubstrate` 追加（policy=.auto は既存） |

**OOM 安全側**: 投影/compute の OOM は `invalidateLogGraph` + policy=.suppressed へ（commits 表示は継続・phase2 と同型の catch）。

### 4.4 appcmd.zig

`runLogInt`（`:156-213`）: 既存の filtered log 取得後、`!cmd.filter.isEmpty()` のとき同一 snapshot_tip で substrate 取得を追加:

```text
（既存: headState → snapshot_tip → logArgv → runWithLimit → parse → entries）
if (!cmd.filter.isEmpty()):
    sub_argv = revListParentsArgv(a, snapshot_tip)
    sub_res = process.runWithLimit(a, io, sub_argv.args, cwd, log_limit)  // StreamTooLong 含む RunError → substrate=null
    if sub_res.exit_code == 0:
        substrate = topology.parse(a, sub_res.stdout) catch null
    else:
        substrate = null
else:
    substrate = null
return LogLoaded { entries, substrate, ... }
```

**unborn（`.is_unborn=true`）**: filter 活性でも commit 無 → substrate 取得スキップ（null）・entries 空。既存の unborn 分岐（`:161-173`）を維持し substrate=null を付加。

`runLogPageInt`（`:261-304`）: **変更なし**（substrate は load_log で取得済・Model 保持分を使用）。

### 4.5 commands.zig

`revListParentsArgv`（新設・`logArgv` と同型）を追加。テスト: argv 構成（`git rev-list --topo-order --parents <tip>`）・snapshot_tip が末尾・借用（deinit で free しない）。高レベル実行関数は不要（appcmd が `process.runWithLimit` を直接呼ぶ・logArgv と同じ形）。

### 4.6 view.zig

**変更不要**。`show_graph = pane_w >= 30 and log_graph_state == .valid and graph_render_policy == .auto`（`view.zig:523`）は投影 graph もそのまま表示（policy=.auto・graph_state.valid）。理由表示（`view.zig:535-539`）は policy==.suppressed のみ = substrate 失敗時のみ。

### 4.7 main.zig / input.zig

**変更なし**。apply_filter/clear_filter のキーバインド（`f`/`F`）・modal 操作は既存のまま。substrate は AppCmd→Msg→Model へ透過（runtime は関知しない）。

---

## 5. paging 整合性の厳密な根拠

- substrate は snapshot_tip 時点の**全履歴**（1 回取得・不変）。filtered log は同一 snapshot_tip の visible 部分集合（topo 順 newest-first）。
- 投影は per-commit 独立（C の投影親は C の substrate 上の実祖先のみに依存し、他ページの可視性に依存しない）→ ページ到着毎の部分投影は冪等・安定。
- topo newest-first において、C の実祖先（= 投影親）は常に「C より後の行」（高 index）に現れる。processCommit は親 hash を frontier slot へ入れ、後続行で消費 → paging を跨いでも frontier が保持（既存の無 filter paging と同一機構）。
- 可視祖先が未ロードページにあっても、その hash の slot が frontier に留まり、該当ページ到着時に消費される（down 接続が継続表示）。正常系と同じ。

---

## 6. エッジケース・失敗・劣化

| ケース | 挙動 |
|---|---|
| 大規模 repo（substrate が stream_limit 超過） | `runWithLimit` が StreamTooLong → substrate=null → policy=.suppressed + 理由表示。メモリ爆発しない（TODO の大規模懸念に合致）。 |
| substrate 取得 exit≠0（壊れた repo 等） | substrate=null → suppress。filtered log 自体は表示。 |
| substrate parse 失敗 | substrate=null → suppress。 |
| 投影/compute の OOM | `invalidateLogGraph` + policy=.suppressed（commits 表示継続）。 |
| root 投影（祖先が全て非可視→実 root） | 投影 parents 空 → derived graph の root（lane 終了）。 |
| merge 投影 | 各 parent を第一親チェーンで解決・重複排除。2 親が同一可視祖先へ収束すれば 1 辺へ集約。 |
| shallow clone（substrate に無い parent） | `nearestVisibleAncestor` が `hash_index` miss で null → 当該 parent 辺を drop（安全側）。 |
| unborn（commit 無） | substrate 取得スキップ・entries 空・graph_state.invalid（既存どおり）。 |
| 無 filter | substrate 取得しない・従来 computeAll（変更無し）。 |

---

## 7. メモリ・コスト

- substrate: hash(40B)+parents（平均 1-2・各 40B）≈ 80-120B/commit。100k commit ≈ 10-12MB（filter 中のみ保持・clear_filter/load_log 再取得で解放）。
- 投影: メモ化 HashMap + derived 一時バッファ（compute 後即解放）。全体 O(N) 時間・O(N) 補助。
- hash_index（StringHashMap）: keys は entries[].hash を借用（dup 無し）・O(N) メモリ。
- derived 一時: 投影 parents のみ所有（hash は visible から dupe または借用）。computeAll 直後に解放。

---

## 8. 未決点（実装/検証で詰める）

1. **derived → log.Commit 適合方式**: `ProjectedCommit` を computeAll 直前に `log.Commit`（hash/parents のみ）へ詰めるか、graph_project が直接 `log.Commit` を返すか。実装で決定（テスト容易性優先）。
2. **投影 parents の hash 所有/借用**: computeAll は内部で hash を dupe するため derived の hash/parents は借用可だが、所有で安全側（OOM 時の解放明確）。
3. **`nearestVisibleAncestor` 第一親 vs all-parents DFS**: 第一親（本 spec 採用）で tmux pty 目視検証。エッジ欠落が目立つなら all-parents DFS（探索幅優先）へ切替（over-connect リスクは重複排除で緩和）。
4. **substrate の Model 保持期間**: clear_filter のみならず新 load_log（無 filter 切替）でも clearTopologySubstrate を呼ぶ（filter→無 filter 切替で古い substrate が残らないよう）。

---

## 9. テスト戦略（純粋層 TDD → UI 配線・CLAUDE.md「進め方」）

### 9.1 topology.zig

- `parse`: linear / branch（分岐）/ merge（多親）/ root（parents 空）/ 複数行 / 空入力（unborn）/ 不正行スキップ。
- `hash_index`: lookup 正当性・外部 hash miss。
- OOM: `checkAllAllocationFailures`（リーク/二重解放無し）。

### 9.2 graph_project.zig

- `project`: 全可視（= identity・投影 parent == 実 parent）/ gap 投影縮約（非可視 parent を飛ばして最近親可視祖先へ）/ merge 投影 / root 投影（祖先全非可視）/ 第一親チェーン追跡 / 重複排除（2 親→同一祖先）。
- 不変条件: derived 1:1・投影 parents ⊆ visible set・非閉路（投影先は厳密祖先）。
- OOM: `checkAllAllocationFailures`。

### 9.3 commands.zig

- `revListParentsArgv`: argv 構成・snapshot_tip 末尾・借用（deinit で snapshot_tip を free しない）。

### 9.4 appcmd.zig（実 tmp repo 結合）

- filter 付き load_log → LogLoaded.substrate 非null（author/date/paths 各 1 パターン）・substrate.entries に全 commit 含む。
- substrate 失敗の模擬: 極小 stream_limit → substrate=null・filtered log は非null。
- unborn + filter → substrate=null・entries 空。

### 9.5 update.zig

- handleLogLoaded: filter+substrate → graph_state.valid・rows==commits・policy=.auto。filter+substrate無 → policy=.suppressed。無 filter → 従来。
- handleLogPageLoaded: filter+substrate → computeIncremental・rows 増分。substrate は Model 保持。
- handleClearFilter: topology_substrate 解放・policy=.auto。
- model.zig: setTopologySubstrate/clearTopologySubstrate cycle（リーク無し）。

### 9.6 view.zig（tmux pty 手動検証・AGENTS.md）

- フィルタ適用 → 投影 graph 表示（理由行無し）。
- substrate 失敗模擬（stream_limit 小）→ 理由行 `Filter: ... (graph hidden)` 表示・graph 非表示。
- paging 下で graph 連続（スクロールで追加ロード・frontier 継続）。
- clear_filter → graph 復活（通常 computeAll）。

### 9.7 root_test.zig

新規 `topology.zig`/`graph_project.zig` の `@import` 行を `src/root_test.zig` へ追加（AGENTS.md 必須・忘れるとテスト非実行）。

---

## 10. スコープ外（将来課題）

- **branch フィルタ（`--branches`）**: 本 spec 対象外（phase 3b #1）。B3 和集合問題（`phase3a-filter-design.md:938`）の解決が前提。本設計の substrate/投影は branch フィルタにも再利用可能（snapshot_tip が単一 tip の限り）。
- **graph 列幅の最適化**（dense history のレーン数膨張）: 本件は投影による正確性が主眼・描画最適化は別途。
- **substrate の差分更新**（load_log 毎の全再取得）: 現状は filter 適用毎に1回フル取得。大規模 repo では stream_limit で劣化するため実用上問題無し。キャッシュ/差分は将来課題。

---

## 11. リスクと緩和

| Risk | 重要度 | mitigation | 根拠 |
|---|---|---|---|
| 大規模 repo で substrate が巨大・メモリ/遅延 | 中 | `default_stream_limit` で StreamTooLong → suppress へ劣化（メモリ爆発しない）・substrate は hash+parents のみ軽量 | TODO 大規模懸念 / `process.zig` runWithLimit |
| 第一親チェーン投影でエッジ欠落・見栄え悪化 | 中 | tmux pty 目視検証・必要なら all-parents DFS 切替（§8.3） | §3.5 |
| path フィルタで filtered log の .parents が簡略化済みで不整合 | 中 | 投影は substrate の実 parents のみ使用・filtered log の .parents は無視（§3.2 均一化） | §1.2 |
| 投影が cycle を作る（祖先でない commit へ投影） | 低 | `nearestVisibleAncestor` は厳密な祖先のみ返す（substrate 上の親チェーン追跡）・非閉路保証 | §3.5 |
| paging で substrate と visible の snapshot_tip 不整合 | 低 | 両者とも load_log で解決した同一 snapshot_tip を使用・load_log_page は Model 保持 substrate を使用 | phase3a B1 / §3.1 |
| LogLoaded へ substrate 追加で既存テスト破壊 | 低 | 既存 LogLoaded 構築箇所へ substrate フィールド追加（空 filter は null）・テスト更新は機械的 | §4.1 |
| substrate の HashMap keys 借用とライフタイライム | 低 | `StringHashMap` は keys を free しない（構造体のみ）ため entries と map の deinit 順序に依存しない。keys は entries[].hash と同一 allocator/ライフタイム | §3.4 |

---

## 12. 受け入れ基準

1. フィルタ（author/since/until/paths 各単独・組合せ）適用中、graph が表示される（policy=.auto・graph_state.valid）。
2. 投影 graph の辺は visible commit 間でのみ接続（宙に浮く辺無し）・非閉路。
3. paging 下で graph が連続（スクロール追加ロードで frontier 継続・破綻無し）。
4. substrate 取得失敗（stream_limit/exit≠0/parse）時は従来どおり graph 非表示 + 理由表示（劣化・クラッシュ無し）。
5. clear_filter で graph 復旧（通常 computeAll）・topology_substrate 解放（リーク無し）。
6. `zig build test --summary all` が全 green（既定 Debug 維持）。新規 2 モジュールのテスト含む。
7. tmux pty で上記 1-5 を目視確認。
