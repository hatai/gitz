# TODO 2 phase 2（表示系: グラフ罫線 + East Asian Width + author/日時）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** git-tui のログビュー（phase 1 完了）にコミットグラフ罫線（`│ ├ └ ┐ ┘` 等・色分け）・author/日時カラム・East Asian Width 対応を追加する。フィルタ機能・`--cc` combined diff はスコープ外。

**Architecture:** phase 1 の Elm 風・副作用隔離アーキテクチャを踏襲。新モジュール `git/graph.zig`（frontier-based レーン割当・純粋・TDD 対象）を追加。`Model` に `log_graph_state: GraphState`（tagged union・`.invalid`/`.valid`）と `log_paging_tip: ?[]u8` を追加。グラフ計算は reducer 内で同期的（新規 AppCmd 無し）。paging 間の履歴 snapshot 統一は tip hash 固定で保証。

**Tech Stack:** Zig 0.16.0（`std.process.run`・unmanaged `ArrayList`・`std.time.epoch`）・zigzag v0.1.5 固定。

**Spec:** `docs/superpowers/specs/2026-06-19-todo2-log-view-phase2-display-design.md`（rev.2・codex 2 段階レビュー済み・H-01..H-08/M-01..M-14/L-01..L-05 全反映）

**コマンド規約（`CLAUDE.md`/`AGENTS.md` 準拠）:**
- ビルド: `zig build`
- テスト: `zig build test --summary all`（**Debug 既定を維持**）
- テストは実装 `.zig` 内の `test {}` ブロック・`std.testing.allocator` 必須。
- 新規 `.zig` は `src/root_test.zig` の `@import("...")` を有効化しないとテストが走らない。

---

## File Structure

### 新規ファイル
- `src/git/graph.zig` — frontier-based レーン割当 + cells 計算（`Conn`/`GraphRow`/`Frontier`/`GraphState`/`computeAll`/`computeIncremental`）。純粋・zigzag 非依存。

### 変更ファイル（純粋層）
- `src/root_test.zig` — `@import("git/graph.zig")` を有効化。
- `src/git/commands.zig` — `logArgv` へ `--topo-order` 追加・新設 `logPageArgv(tip_hash)`。
- `src/model.zig` — `log_graph_state`/`log_paging_tip` フィールド + `setLogGraphState`/`invalidateLogGraph`/`setLogPagingTip`/`clearLogPagingTip` ヘルパ。
- `src/messages.zig` — `AppCmd.load_log_page` を `LoadLog` から独立所有型 `LoadLogPage` へ変更・`Msg.LogPageLoaded` へ `request_tip` 追加。
- `src/appcmd.zig` — `.load_log_page` arm で `logPageArgv(tip)` 使用・bad revision（exit 128）検出で `git_error`。
- `src/update.zig` — `handleLogLoaded`/`handleLogPageLoaded` arm へグラフ計算呼び出し追加・`git_error`（log 中）で全 refresh・`toggle_view_mode`/`handleRequestRefreshLog` でグラフ無効化。

### 変更ファイル（UI 層）
- `src/view.zig` — `renderLog` のカラムレイアウト拡張（graph/refs/hash/subject/author/date）・グラフ罫線色ローテーション・省略セル `⋮`・UTC date フォーマット・段階的カラム省略。

### ドキュメント
- `README.md` — phase 2 表示要素（グラフ・author・日時 UTC）追記。
- `TODO.md` — phase 2 を「表示系」と「フィルタ」へ分割・表示系チェックボックス。

---

## Task 1: `src/git/graph.zig` — 型定義と線形履歴の `computeAll`

**Files:**
- Create: `src/git/graph.zig`
- Modify: `src/root_test.zig`

### Step 1: `src/git/graph.zig` を作成（型定義 + `computeAll` スケルトン）

```zig
//! コミットグラフのレーン割当とエッジ計算。`log.Commit` の parents から frontier-based で算出。
//! zigzag 非依存・テスト容易（決定論的入力 → 決定論的出力）。
const std = @import("std");
const log = @import("log.zig");

/// 1 表示行（= 1 コミット）の各列の接続情報を bitset で表現。
pub const Conn = packed struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    is_node: bool = false,
};

/// 1 コミット分のグラフ描画メタデータ。1 コミット = 1 表示行。
pub const GraphRow = struct {
    node_lane: u16,
    cells: []Conn,
    pub fn width(self: GraphRow) u16 {
        return @intCast(self.cells.len);
    }
    pub fn deinit(self: *GraphRow, a: std.mem.Allocator) void {
        a.free(self.cells);
    }
};

/// frontier: 各レーンの「次行へ伝播する親 hash」。dense・null hole 無し（M-01(再)）。
pub const Frontier = struct {
    slots: std.ArrayList(?[]u8),
    pub fn init() Frontier {
        return .{ .slots = .empty };
    }
    pub fn deinit(self: *Frontier, a: std.mem.Allocator) void {
        for (self.slots.items) |s| {
            if (s) |h| a.free(h);
        }
        self.slots.deinit(a);
    }
    pub fn clone(self: Frontier, a: std.mem.Allocator) !Frontier {
        var next: Frontier = .init();
        errdefer next.deinit(a);
        try next.slots.ensureTotalCapacity(a, self.slots.items.len);
        for (self.slots.items) |s| {
            const dup: ?[]u8 = if (s) |h| try a.dupe(u8, h) else null;
            errdefer if (dup) |d| a.free(d);
            try next.slots.append(a, dup);
        }
        return next;
    }
};

/// GraphState: tagged union。`.invalid`/`.valid` を保証。それ以外は runtime invariant（M-14）。
pub const GraphState = union(enum) {
    invalid,
    valid: struct {
        generation: u64,
        processed_len: usize,
        tip_hash: ?[]u8,
        rows: std.ArrayList(GraphRow),
        frontier: Frontier,

        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            for (self.rows.items) |*r| r.deinit(a);
            self.rows.deinit(a);
            self.frontier.deinit(a);
            if (self.tip_hash) |t| a.free(t);
        }
    },

    pub fn deinit(self: *GraphState, a: std.mem.Allocator) void {
        switch (self.*) {
            .invalid => {},
            .valid => |*v| v.deinit(a),
        }
    }
    pub fn isInvariant(self: GraphState, expected_generation: u64, commits_len: usize) bool {
        return switch (self) {
            .invalid => true,
            .valid => |v| v.generation == expected_generation and
                v.processed_len == commits_len and
                v.rows.items.len == commits_len,
        };
    }
};

/// 初回（skip=0）/全再計算: 全コミットを一括で処理。
pub fn computeAll(
    a: std.mem.Allocator,
    commits: []const log.Commit,
    generation: u64,
    tip_hash: ?[]const u8,
) !GraphState {
    var rows: std.ArrayList(GraphRow) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(a);
        rows.deinit(a);
    }
    var frontier: Frontier = .init();
    errdefer frontier.deinit(a);

    for (commits) |c| {
        const row = try processCommit(a, &frontier, c);
        errdefer row.deinit(a);
        try rows.append(a, row);
    }

    const tip_owned: ?[]u8 = if (tip_hash) |t| try a.dupe(u8, t) else null;
    errdefer if (tip_owned) |t| a.free(t);

    return .{ .valid = .{
        .generation = generation,
        .processed_len = commits.len,
        .tip_hash = tip_owned,
        .rows = rows,
        .frontier = frontier,
    } };
}

/// 1 コミットを処理し GraphRow を構築。frontier を破壊的に更新する。
fn processCommit(a: std.mem.Allocator, frontier: *Frontier, c: log.Commit) !GraphRow {
    // (1) c.hash と一致する frontier slot を全て列挙（H-01: 重複親の集約）
    var match_lanes: std.ArrayList(usize) = .empty;
    defer match_lanes.deinit(a);
    for (frontier.slots.items, 0..) |slot, i| {
        if (slot) |h| {
            if (std.mem.eql(u8, h, c.hash)) {
                try match_lanes.append(a, i);
            }
        }
    }

    // 代表 lane の決定
    const node_lane: u16 = if (match_lanes.items.len > 0)
        @intCast(match_lanes.items[0])
    else blk: {
        // 新規 tip: frontier 末尾へ append
        const h = try a.dupe(u8, c.hash);
        try frontier.slots.append(a, h);
        break :blk @intCast(frontier.slots.items.len - 1);
    };

    // before frontier のスナップショット（cells の up 接続用）
    const before_len = frontier.slots.items.len;
    var before_has: []bool = try a.alloc(bool, before_len);
    defer a.free(before_has);
    for (frontier.slots.items, 0..) |slot, i| {
        before_has[i] = slot != null;
    }

    // (3) frontier[node_lane] を消費
    if (frontier.slots.items[node_lane]) |h| a.free(h);
    frontier.slots.items[node_lane] = null;

    // 水平接続: H-01 で集約される余分 match の記録用
    var agg_lanes: std.ArrayList(usize) = .empty;
    defer agg_lanes.deinit(a);
    for (match_lanes.items[1..]) |ml| {
        try agg_lanes.append(a, ml);
        if (frontier.slots.items[ml]) |h| a.free(h);
        frontier.slots.items[ml] = null;
    }

    // (4) parents の配置
    var branch_lanes: std.ArrayList(usize) = .empty;
    defer branch_lanes.deinit(a);
    if (c.parents.len == 0) {
        // root: lane 終了
    } else {
        // 第一親: H-01 で既存 slot へ集約を試みる
        const p1 = c.parents[0];
        var found_p1: ?usize = null;
        for (frontier.slots.items, 0..) |slot, i| {
            if (i == node_lane) continue; // 自分の消費済み slot はスキップ
            if (slot) |h| {
                if (std.mem.eql(u8, h, p1)) {
                    found_p1 = i;
                    break;
                }
            }
        }
        if (found_p1) |fi| {
            // 集約: node_lane から fi へ水平接続
            try agg_lanes.append(a, fi);
        } else {
            // 新規配置
            const p1_dup = try a.dupe(u8, p1);
            frontier.slots.items[node_lane] = p1_dup;
        }
        // 追加親（merge）: dense 挿入
        for (c.parents[1..]) |p| {
            var found_p: ?usize = null;
            for (frontier.slots.items, 0..) |slot, i| {
                if (slot) |h| {
                    if (std.mem.eql(u8, h, p)) {
                        found_p = i;
                        break;
                    }
                }
            }
            if (found_p) |fi| {
                // 既存へ集約
                try branch_lanes.append(a, fi);
            } else {
                // node_lane の直後に挿入
                const p_dup = try a.dupe(u8, p);
                try frontier.slots.insert(a, node_lane + 1, p_dup);
                try branch_lanes.append(a, node_lane + 1);
            }
        }
    }

    // (5) 全 null slot を削除して左詰め（M-01(再): interior hole も残さない）
    var compacted: usize = 0;
    for (0..frontier.slots.items.len) |i| {
        if (frontier.slots.items[i] != null) {
            if (compacted != i) {
                frontier.slots.items[compacted] = frontier.slots.items[i];
                frontier.slots.items[i] = null;
            }
            compacted += 1;
        }
    }
    frontier.slots.shrinkRetainingCapacity(compacted);

    // after frontier のスナップショット
    const after_len = frontier.slots.items.len;

    // (6) cells 構築
    const w: usize = @max(@max(before_len, after_len), @as(usize, node_lane) + 1);
    var cells = try a.alloc(Conn, w);
    errdefer a.free(cells);
    for (cells) |*cell| cell.* = .{};

    // up 接続: before frontier の各 slot が非 null だった列
    for (0..before_len) |i| {
        if (i < w and before_has[i]) cells[i].up = true;
    }
    // down 接続: after frontier の各 slot が非 null の列
    for (0..after_len) |i| {
        if (i < w) cells[i].down = true;
    }
    // node
    cells[node_lane].is_node = true;
    // node_lane が before にあった場合、up を消さない（node 自体が up から来る）
    // node_lane が after にある場合、down も維持

    // 水平接続（集約）: agg_lanes の各 lane から node_lane へ
    for (agg_lanes.items) |al| {
        const lo = @min(al, @as(usize, node_lane));
        const hi = @max(al, @as(usize, node_lane));
        if (lo < w) cells[lo].right = true;
        if (hi < w) cells[hi].left = true;
        // 中間セルは水平線
        for (lo + 1..hi) |mid| {
            if (mid < w) {
                cells[mid].left = true;
                cells[mid].right = true;
            }
        }
    }

    return .{ .node_lane = node_lane, .cells = cells };
}

test {
    std.testing.refAllDecls(@This());
}
```

### Step 2: `src/root_test.zig` へ `@import("git/graph.zig")` を追加

`src/root_test.zig` の `test {}` ブロック末尾（`@import("git/show.zig")` の後）へ追加:

```zig
    _ = @import("git/graph.zig"); // TODO 2 phase 2: グラフレーン割当
```

### Step 3: 線形履歴のテストを追加

`src/git/graph.zig` の `test { ... }` の前に追加:

```zig
fn mkCommit(a: std.mem.Allocator, hash: []const u8, parents: []const []const u8) !log.Commit {
    var ps: std.ArrayList([]u8) = .empty;
    for (parents) |p| {
        try ps.append(a, try a.dupe(u8, p));
    }
    return .{
        .hash = try a.dupe(u8, hash),
        .parents = try ps.toOwnedSlice(a),
        .author = try a.dupe(u8, "tester"),
        .epoch_sec = 1000,
        .subject = try a.dupe(u8, "subj"),
        .refs = try a.dupe(u8, ""),
    };
}

test "computeAll: linear history (3 commits, 1 lane)" {
    const a = std.testing.allocator;
    var commits: [3]log.Commit = undefined;
    commits[0] = try mkCommit(a, "C", &.{"B"});
    commits[1] = try mkCommit(a, "B", &.{"A"});
    commits[2] = try mkCommit(a, "A", &.{});
    defer for (&commits) |*c| c.deinit(a);

    var state = try computeAll(a, &commits, 1, "C");
    defer state.deinit(a);

    try std.testing.expect(state == .valid);
    const v = state.valid;
    try std.testing.expectEqual(@as(usize, 3), v.rows.items.len);
    try std.testing.expectEqual(@as(u64, 1), v.generation);
    try std.testing.expectEqual(@as(usize, 3), v.processed_len);
    // 全コミット lane 0
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[0].node_lane);
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[1].node_lane);
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[2].node_lane);
    // Row 0 (C): node + down (parent B below)
    try std.testing.expect(v.rows.items[0].cells[0].is_node);
    try std.testing.expect(v.rows.items[0].cells[0].down);
    try std.testing.expect(!v.rows.items[0].cells[0].up);
    // Row 1 (B): up + node + down
    try std.testing.expect(v.rows.items[1].cells[0].up);
    try std.testing.expect(v.rows.items[1].cells[0].is_node);
    try std.testing.expect(v.rows.items[1].cells[0].down);
    // Row 2 (A, root): up + node, no down
    try std.testing.expect(v.rows.items[2].cells[0].up);
    try std.testing.expect(v.rows.items[2].cells[0].is_node);
    try std.testing.expect(!v.rows.items[2].cells[0].down);
    // frontier after processing: empty (A is root)
    try std.testing.expectEqual(@as(usize, 0), v.frontier.slots.items.len);
}

test "computeAll: empty commits returns valid with 0 rows" {
    const a = std.testing.allocator;
    var state = try computeAll(a, &.{}, 1, null);
    defer state.deinit(a);
    try std.testing.expect(state == .valid);
    try std.testing.expectEqual(@as(usize, 0), state.valid.rows.items.len);
    try std.testing.expectEqual(@as(?[]u8, null), state.valid.tip_hash);
}

test "computeAll: tip_hash is duplicated and owned" {
    const a = std.testing.allocator;
    var commits: [1]log.Commit = undefined;
    commits[0] = try mkCommit(a, "H", &.{});
    defer commits[0].deinit(a);
    var state = try computeAll(a, &commits, 1, "H");
    defer state.deinit(a);
    try std.testing.expectEqualStrings("H", state.valid.tip_hash.?);
}
```

### Step 4: テストを実行して確認

Run: `zig build test --summary all`
Expected: PASS（`graph.zig` の 3 テストが緑）

### Step 5: Commit

```bash
git add src/git/graph.zig src/root_test.zig
git commit -m "feat(graph): add frontier-based lane assignment module with linear history support

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 2: `src/git/graph.zig` — 分岐/マージ/共通親集約/dense compaction

**Files:**
- Modify: `src/git/graph.zig`

### Step 1: 分岐テストを追加

`src/git/graph.zig` のテストセクションへ追加:

```zig
test "computeAll: branch (C←A, B←A, 2 lanes)" {
    const a = std.testing.allocator;
    // topo-order newest first: C, B, A
    var commits: [3]log.Commit = undefined;
    commits[0] = try mkCommit(a, "C", &.{"A"});
    commits[1] = try mkCommit(a, "B", &.{"A"});
    commits[2] = try mkCommit(a, "A", &.{});
    defer for (&commits) |*c| c.deinit(a);

    var state = try computeAll(a, &commits, 1, "C");
    defer state.deinit(a);
    const v = state.valid;

    // Row 0 (C): lane 0, 1 column
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[0].node_lane);
    try std.testing.expectEqual(@as(usize, 1), v.rows.items[0].width());

    // Row 1 (B): lane 1 (new tip), B's parent A aggregates to existing lane 0
    try std.testing.expectEqual(@as(u16, 1), v.rows.items[1].node_lane);
    try std.testing.expectEqual(@as(usize, 2), v.rows.items[1].width());
    // col 0: A coming from above + continuing down
    try std.testing.expect(v.rows.items[1].cells[0].up);
    try std.testing.expect(v.rows.items[1].cells[0].down);
    // col 1: B node, up from new tip, left connection to col 0 (aggregation)
    try std.testing.expect(v.rows.items[1].cells[1].is_node);
    try std.testing.expect(v.rows.items[1].cells[1].left);

    // Row 2 (A): lane 0 (compacted)
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[2].node_lane);
    try std.testing.expectEqual(@as(usize, 1), v.rows.items[2].width());
    try std.testing.expect(v.rows.items[2].cells[0].is_node);
}

test "computeAll: merge (D=merge(B,C), B←A, C←A)" {
    const a = std.testing.allocator;
    // topo-order: D, C, B, A
    var commits: [4]log.Commit = undefined;
    commits[0] = try mkCommit(a, "D", &.{ "B", "C" });
    commits[1] = try mkCommit(a, "C", &.{"A"});
    commits[2] = try mkCommit(a, "B", &.{"A"});
    commits[3] = try mkCommit(a, "A", &.{});
    defer for (&commits) |*c| c.deinit(a);

    var state = try computeAll(a, &commits, 1, "D");
    defer state.deinit(a);
    const v = state.valid;

    // Row 0 (D, merge): lane 0, parents B(lane0) + C(lane1 inserted)
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[0].node_lane);
    try std.testing.expectEqual(@as(usize, 2), v.rows.items[0].width());
    try std.testing.expect(v.rows.items[0].cells[0].is_node);
    try std.testing.expect(v.rows.items[0].cells[0].down); // B continues
    try std.testing.expect(v.rows.items[0].cells[1].down); // C continues

    // Row 1 (C): lane 1
    try std.testing.expectEqual(@as(u16, 1), v.rows.items[1].node_lane);

    // Row 2 (B): lane 0, B's parent A aggregates with C's parent A (H-01)
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[2].node_lane);
    // B connects horizontally to A's lane
    try std.testing.expect(v.rows.items[2].cells[0].is_node);

    // Row 3 (A): lane 0 (compacted)
    try std.testing.expectEqual(@as(u16, 0), v.rows.items[3].node_lane);
}

test "computeAll: dense compaction removes interior holes (M-01)" {
    const a = std.testing.allocator;
    // A root, B←A, C←A, D=merge(B,C)
    // After D: frontier=[B,C]. After C consumed: [B,A]. After B consumed+aggregated: [A].
    // Interior hole at position 0 is removed by compaction.
    var commits: [4]log.Commit = undefined;
    commits[0] = try mkCommit(a, "D", &.{ "B", "C" });
    commits[1] = try mkCommit(a, "C", &.{"A"});
    commits[2] = try mkCommit(a, "B", &.{"A"});
    commits[3] = try mkCommit(a, "A", &.{});
    defer for (&commits) |*c| c.deinit(a);

    var state = try computeAll(a, &commits, 1, "D");
    defer state.deinit(a);
    // After all processing, frontier should be empty (A is root)
    try std.testing.expectEqual(@as(usize, 0), state.valid.frontier.slots.items.len);
}
```

### Step 2: テストを実行

Run: `zig build test --summary all`
Expected: PASS

### Step 3: Commit

```bash
git add src/git/graph.zig
git commit -m "test(graph): add branch/merge/common-parent/dense-compaction test cases

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 3: `src/git/graph.zig` — `computeIncremental` + OOM 安全性

**Files:**
- Modify: `src/git/graph.zig`

### Step 1: `computeIncremental` を実装

`computeAll` の後に追加:

```zig
/// 増分: 入力 GraphState.valid を破壊せず、delta rows + 新 frontier を構築 → swap。
/// 既存 rows の deep-copy はしない（H-08: O(N²) 回避）。
pub fn computeIncremental(
    a: std.mem.Allocator,
    state: GraphState,
    new_commits: []const log.Commit,
) !GraphState {
    if (state != .valid) return error.InvalidState;
    const src = state.valid;

    // 1. frontier を clone（一時状態）
    var tmp_frontier = try src.frontier.clone(a);
    errdefer tmp_frontier.deinit(a);

    // 2. delta rows を新規構築
    var delta_rows: std.ArrayList(GraphRow) = .empty;
    errdefer {
        for (delta_rows.items) |*r| r.deinit(a);
        delta_rows.deinit(a);
    }

    for (new_commits) |c| {
        const row = try processCommit(a, &tmp_frontier, c);
        errdefer row.deinit(a);
        try delta_rows.append(a, row);
    }

    // 3. 既存 rows + delta を新 ArrayList へ構築（move 既存 + append delta）
    var combined: std.ArrayList(GraphRow) = .empty;
    errdefer combined.deinit(a);
    try combined.ensureTotalCapacity(a, src.rows.items.len + delta_rows.items.len);
    // 既存 rows を move（所有権移行・free しない）
    for (src.rows.items) |r| {
        try combined.appendAssumeCapacity(r);
    }
    // delta rows を move
    for (delta_rows.items) |r| {
        try combined.appendAssumeCapacity(r);
    }
    delta_rows.deinit(a); // items は移行済み・空になる

    // tip_hash を clone
    const tip_dup: ?[]u8 = if (src.tip_hash) |t| try a.dupe(u8, t) else null;
    errdefer if (tip_dup) |t| a.free(t);

    return .{ .valid = .{
        .generation = src.generation,
        .processed_len = src.processed_len + new_commits.len,
        .tip_hash = tip_dup,
        .rows = combined,
        .frontier = tmp_frontier,
    } };
}
```

### Step 2: 増分テストを追加

```zig
test "computeIncremental: append produces same result as computeAll" {
    const a = std.testing.allocator;
    // 5 commits: A←B←C←D←E
    var all: [5]log.Commit = undefined;
    all[0] = try mkCommit(a, "E", &.{"D"});
    all[1] = try mkCommit(a, "D", &.{"C"});
    all[2] = try mkCommit(a, "C", &.{"B"});
    all[3] = try mkCommit(a, "B", &.{"A"});
    all[4] = try mkCommit(a, "A", &.{});
    defer for (&all) |*c| c.deinit(a);

    // computeAll for all 5
    var full = try computeAll(a, &all, 1, "E");
    defer full.deinit(a);

    // computeAll for first 3, then computeIncremental for last 2
    var base = try computeAll(a, all[0..3], 1, "E");
    defer base.deinit(a);

    var incr = try computeIncremental(a, base, all[3..5]);
    defer incr.deinit(a);

    // Same row count
    try std.testing.expectEqual(full.valid.rows.items.len, incr.valid.rows.items.len);
    // Same node_lanes
    for (full.valid.rows.items, incr.valid.rows.items) |fr, ir| {
        try std.testing.expectEqual(fr.node_lane, ir.node_lane);
    }
    // Same frontier
    try std.testing.expectEqual(
        full.valid.frontier.slots.items.len,
        incr.valid.frontier.slots.items.len,
    );
    // Same processed_len
    try std.testing.expectEqual(full.valid.processed_len, incr.valid.processed_len);
}

test "computeIncremental: does not corrupt input state on OOM" {
    const a = std.testing.allocator;
    var commits: [2]log.Commit = undefined;
    commits[0] = try mkCommit(a, "B", &.{"A"});
    commits[1] = try mkCommit(a, "A", &.{});
    defer for (&commits) |*c| c.deinit(a);

    var base = try computeAll(a, commits[0..1], 1, "B");
    defer base.deinit(a);

    // Verify base is still usable after incremental (strong exception guarantee)
    var incr = try computeIncremental(a, base, commits[1..2]);
    defer incr.deinit(a);

    // base.deinit() succeeds (not corrupted)
    try std.testing.expectEqual(@as(usize, 2), incr.valid.rows.items.len);
}

test "computeAll: checkAllAllocationFailures (no leak/double-free)" {
    const raw = "E\x00D\x00t\x001\x00s\x00\x00D\x00C\x00t\x001\x00s\x00\x00C\x00B\x00t\x001\x00s\x00\x00";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, computeAllAndFree, .{raw});
}

fn computeAllAndFree(a: std.mem.Allocator, raw: []const u8) !void {
    const commits = try log.parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    var state = try computeAll(a, commits, 1, "E");
    state.deinit(a);
}
```

### Step 3: テストを実行

Run: `zig build test --summary all`
Expected: PASS

### Step 4: Commit

```bash
git add src/git/graph.zig
git commit -m "feat(graph): add computeIncremental with strong exception guarantee (H-08)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 4: `src/git/commands.zig` — `--topo-order` + `logPageArgv(tip_hash)`

**Files:**
- Modify: `src/git/commands.zig`

### Step 1: `logArgv` へ `--topo-order` を追加

`src/git/commands.zig` の `logArgv` 関数へ `"--topo-order",` を追加（`"log",` の直後）:

```zig
pub fn logArgv(a: std.mem.Allocator, skip: usize, max_count: usize) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "log", "--topo-order",
    });
    // ... 既存のコード（skip/max_count/pretty format）は同じ
```

### Step 2: `logPageArgv` を新設

`logArgv` の後に追加:

```zig
/// `git log --topo-order --skip=N --max-count=100 <tip_hash>` argv。
/// ★H-06/H-07: paging 間で tip hash を固定し同一 snapshot を参照する。
pub fn logPageArgv(
    a: std.mem.Allocator,
    skip: usize,
    max_count: usize,
    tip_hash: []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "log", "--topo-order",
    });
    if (skip > 0) {
        const skip_arg = try std.fmt.allocPrint(a, "--skip={d}", .{skip});
        errdefer a.free(skip_arg);
        try list.append(a, skip_arg);
    }
    const max_arg = try std.fmt.allocPrint(a, "--max-count={d}", .{max_count});
    errdefer a.free(max_arg);
    try list.append(a, max_arg);
    try list.appendSlice(a, &.{
        "--pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d",
        "-z",
        "--decorate=short",
        "--no-color",
    });
    try list.append(a, tip_hash);
    return list.toOwnedSlice(a);
}
```

### Step 3: argv テストを更新・追加

`src/git/commands.zig` のテストセクションへ追加:

```zig
test "logArgv: includes --topo-order" {
    const a = std.testing.allocator;
    const argv = try logArgv(a, 0, 100);
    defer {
        for (argv) |arg| {
            if (std.mem.startsWith(u8, arg, "--max-count=") or
                std.mem.startsWith(u8, arg, "--skip=")) a.free(arg);
        }
        a.free(argv);
    }
    var has_topo = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--topo-order")) has_topo = true;
    }
    try std.testing.expect(has_topo);
}

test "logPageArgv: includes --topo-order, tip_hash last" {
    const a = std.testing.allocator;
    const argv = try logPageArgv(a, 100, 100, "abc123");
    defer {
        for (argv) |arg| {
            if (std.mem.startsWith(u8, arg, "--max-count=") or
                std.mem.startsWith(u8, arg, "--skip=")) a.free(arg);
        }
        a.free(argv);
    }
    // tip_hash is the last arg
    try std.testing.expectEqualStrings("abc123", argv[argv.len - 1]);
    // --topo-order present
    var has_topo = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--topo-order")) has_topo = true;
    }
    try std.testing.expect(has_topo);
}
```

### Step 4: テストを実行

Run: `zig build test --summary all`
Expected: PASS

### Step 5: Commit

```bash
git add src/git/commands.zig
git commit -m "feat(commands): add --topo-order to logArgv and new logPageArgv(tip_hash) (H-03/H-06)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 5: `src/messages.zig` — `LoadLogPage` 独立所有型 + `LogPageLoaded.request_tip`

**Files:**
- Modify: `src/messages.zig`

### Step 1: `AppCmd.load_log_page` を `LoadLog` から独立型 `LoadLogPage` へ変更

`src/messages.zig` の `AppCmd` 定義で:

```zig
pub const AppCmd = union(enum) {
    // 既存...
    load_log: LoadLog,
    load_log_page: LoadLogPage,  // ← LoadLog から変更
    // ...
    pub const LoadLog = struct { skip: usize, max_count: usize, generation: u64 };
    /// ★rev.2 M-10: page 用独立所有型。tip_hash は dupe 済み・deinit で解放。
    pub const LoadLogPage = struct {
        skip: usize,
        max_count: usize,
        generation: u64,
        tip_hash: []u8,  // 所有
    };
    // ...
```

### Step 2: `Msg.LogPageLoaded` へ `request_tip` を追加

`LogLoaded` 構造体とは別に、`LogPageLoaded` を新設:

```zig
    pub const LogLoaded = struct {
        request_skip: usize,
        request_max_count: usize,
        request_generation: u64,
        entries: []@import("git/log.zig").Commit,
    };
    /// ★rev.2 H-07: log_page_loaded 専用（request_tip 追加）。
    pub const LogPageLoaded = struct {
        request_skip: usize,
        request_max_count: usize,
        request_generation: u64,
        request_tip: []u8,  // ★H-07: 要求時 tip と model.log_paging_tip を照合
        entries: []@import("git/log.zig").Commit,
    };
```

`Msg` のバリアントも変更:

```zig
    log_loaded: LogLoaded,
    log_page_loaded: LogPageLoaded,  // ← LogLoaded から変更
```

### Step 3: `deinit` を更新

`Msg.deinit` の `.log_page_loaded` arm を更新:

```zig
            .log_loaded => |ll| {
                for (ll.entries) |*c| c.deinit(a);
                a.free(ll.entries);
            },
            .log_page_loaded => |lpl| {
                a.free(lpl.request_tip);
                for (lpl.entries) |*c| c.deinit(a);
                a.free(lpl.entries);
            },
```

`AppCmd.deinit` の `.load_log_page` arm を更新:

```zig
            .load_log_page => |llp| {
                a.free(llp.tip_hash);
            },
```

### Step 4: テストを更新

既存の `load_log_page` 関連テストがあれば `tip_hash` を含むよう修正。`log_page_loaded` のテストも `request_tip` を含むよう修正。

### Step 5: テストを実行してコンパイルエラーを確認

Run: `zig build test --summary all`
Expected: `update.zig`/`appcmd.zig` でコンパイルエラー（次の Task で修正）

### Step 6: Commit

```bash
git add src/messages.zig
git commit -m "feat(messages): add LoadLogPage owned type and LogPageLoaded.request_tip (H-07/M-10)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 6: `src/model.zig` — `log_graph_state` + `log_paging_tip` + ヘルパ

**Files:**
- Modify: `src/model.zig`

### Step 1: `graph` モジュール import とフィールド追加

`src/model.zig` の import セクションへ追加:

```zig
const graph_mod = @import("git/graph.zig");
```

`Model` struct の phase 1 フィールド群の後に追加:

```zig
    // --- TODO 2 phase 2: グラフ描画 + paging tip ---
    log_graph_state: graph_mod.GraphState,
    log_paging_tip: ?[]u8,
```

### Step 2: `init` と `deinit` を更新

`init` の戻り値リテラルへ追加:

```zig
            .log_graph_state = .invalid,
            .log_paging_tip = null,
```

`deinit` へ追加（既存の phase 1 解放の後）:

```zig
        // --- TODO 2 phase 2 ---
        self.log_graph_state.deinit(a);
        if (self.log_paging_tip) |t| a.free(t);
```

### Step 3: ヘルパメソッドを追加

`Model` の `clearLogRestoreHash` の後に追加:

```zig
    /// phase 2: log_graph_state を新規 state へ置換（旧を deinit）。
    pub fn setLogGraphState(self: *Model, new_state: graph_mod.GraphState) void {
        self.log_graph_state.deinit(self.allocator);
        self.log_graph_state = new_state;
    }
    /// phase 2: log_graph_state を .invalid へ（旧を deinit）。
    pub fn invalidateLogGraph(self: *Model) void {
        self.log_graph_state.deinit(self.allocator);
        self.log_graph_state = .invalid;
    }
    /// phase 2: log_paging_tip をセット（旧を free して dup）。
    pub fn setLogPagingTip(self: *Model, hash: []const u8) !void {
        const a = self.allocator;
        const new = try a.dupe(u8, hash);
        if (self.log_paging_tip) |old| a.free(old);
        self.log_paging_tip = new;
    }
    /// phase 2: log_paging_tip をクリア。
    pub fn clearLogPagingTip(self: *Model) void {
        const a = self.allocator;
        if (self.log_paging_tip) |old| a.free(old);
        self.log_paging_tip = null;
    }
```

### Step 4: テストを追加

```zig
test "Model.log_graph_state initializes to .invalid" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expect(m.log_graph_state == .invalid);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_paging_tip);
}

test "setLogPagingTip / clearLogPagingTip cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setLogPagingTip("abc");
    try std.testing.expectEqualStrings("abc", m.log_paging_tip.?);
    try m.setLogPagingTip("def");
    try std.testing.expectEqualStrings("def", m.log_paging_tip.?);
    m.clearLogPagingTip();
    try std.testing.expectEqual(@as(?[]u8, null), m.log_paging_tip);
}
```

### Step 5: テストを実行（messages.zig のコンパイルエラーは appcmd/update 修正後）

Run: `zig build test --summary all`
Expected: model.zig テスト PASS（他はコンパイルエラーのまま）

### Step 6: Commit

```bash
git add src/model.zig
git commit -m "feat(model): add log_graph_state and log_paging_tip fields with helpers

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 7: `src/appcmd.zig` — `.load_log_page` で `logPageArgv(tip)` + bad revision

**Files:**
- Modify: `src/appcmd.zig`

### Step 1: `.load_log_page` arm を更新

`src/appcmd.zig` の `run` 関数で、`.load_log_page` arm を更新:

```zig
        .load_log_page => |c| return runLogPageInt(a, io, cwd, c),
```

`runLogInt` の直後に `runLogPageInt` を新設:

```zig
/// load_log_page 専用: tip_hash 固定で git log を実行（★H-06/H-07）。
fn runLogPageInt(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd.LoadLogPage) !Msg {
    // ★M-12: tip が bad revision（exit 128）の場合は git_error へ。
    const argv = try cmds.logPageArgv(a, cmd.skip, cmd.max_count, cmd.tip_hash);
    defer freeLogPageArgv(a, argv);
    var res = process.run(a, io, argv, cwd) catch
        return mkPageFailedOrSilent(a, .{ .skip = cmd.skip, .max_count = cmd.max_count, .generation = cmd.generation }, "git log 実行エラー");
    defer res.deinit(a);
    if (res.exit_code != 0) {
        // ★M-12: bad revision 検出（tip が gc 等で消失）
        const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n");
        if (res.exit_code == 128) {
            return .{ .git_error = try a.dupe(u8, "tip が期限切れです（履歴が移動しました）") };
        }
        const text = a.dupe(u8, stderr_trimmed) catch
            return mkPageFailedSilent(.{ .skip = cmd.skip, .max_count = cmd.max_count, .generation = cmd.generation });
        return .{ .log_page_failed = .{
            .request_skip = cmd.skip,
            .request_generation = cmd.generation,
            .error_text = text,
        } };
    }
    const entries = log.parse(a, res.stdout) catch
        return mkPageFailedOrSilent(a, .{ .skip = cmd.skip, .max_count = cmd.max_count, .generation = cmd.generation }, "git log パース失敗");
    // ★H-07: request_tip を dupe して結果 Msg へ
    const tip_dup = try a.dupe(u8, cmd.tip_hash);
    errdefer a.free(tip_dup);
    return .{ .log_page_loaded = .{
        .request_skip = cmd.skip,
        .request_max_count = cmd.max_count,
        .request_generation = cmd.generation,
        .request_tip = tip_dup,
        .entries = entries,
    } };
}

fn freeLogPageArgv(a: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "--skip=") or
            std.mem.startsWith(u8, arg, "--max-count=")) {
            a.free(arg);
        }
    }
    a.free(argv);
}
```

### Step 2: テストを実行してコンパイルエラーを解消

Run: `zig build test --summary all`
Expected: `update.zig` でコンパイルエラー（次の Task で修正）

### Step 3: Commit

```bash
git add src/appcmd.zig
git commit -m "feat(appcmd): use logPageArgv(tip) with bad revision detection (H-06/M-12)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 8: `src/update.zig` — グラフ計算呼び出し + bad revision 回復 + 無効化

**Files:**
- Modify: `src/update.zig`

### Step 1: `graph_mod` import を追加

`src/update.zig` の import セクションへ追加:

```zig
const graph_mod = @import("git/graph.zig");
```

### Step 2: `handleLogLoaded` へグラフ計算 + tip 設定を追加

`handleLogLoaded` 関数の `replaceLogCommits` の後に、tip 設定とグラフ計算を追加:

```zig
fn handleLogLoaded(model: *Model, ll: msgs.Msg.LogLoaded) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (ll.request_generation != model.log_request_generation) return .none;
    if (ll.request_skip != 0) return .none;
    try model.replaceLogCommits(ll.entries);
    // R4: restore hash
    if (model.log_restore_hash) |h| {
        var found: ?usize = null;
        for (model.log_commits.items, 0..) |c, idx| {
            if (std.mem.eql(u8, c.hash, h)) {
                found = idx;
                break;
            }
        }
        model.log_selected = found orelse 0;
        model.clearLogRestoreHash();
    } else {
        model.log_selected = 0;
    }
    model.log_has_more = ll.entries.len >= ll.request_max_count;
    model.log_page_requested = null;
    model.detail_kind = .files;
    if (model.log_commits.items.len == 0) {
        model.clearDetailOwner();
        try model.replaceDetailFiles(&.{});
        return .none;
    }
    // ★phase 2: tip 設定（★H-07: generation と一体）
    model.setLogPagingTip(model.log_commits.items[0].hash) catch {
        model.clearLogPagingTip();
    };
    // ★phase 2: グラフ計算（OOM で .invalid へ・commits は採用済み）
    {
        const tip_const: ?[]const u8 = if (model.log_paging_tip) |t| t else null;
        const gs = graph_mod.computeAll(model.allocator, model.log_commits.items, model.log_request_generation, tip_const) catch {
            model.invalidateLogGraph();
            return try loadCommitDetailForSelection(model);
        };
        model.setLogGraphState(gs);
    }
    return try loadCommitDetailForSelection(model);
}
```

### Step 3: `handleLogPageLoaded` を `LogPageLoaded` + switch へ更新

```zig
fn handleLogPageLoaded(model: *Model, lpl: msgs.Msg.LogPageLoaded) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (lpl.request_generation != model.log_request_generation) return .none;
    const expected_skip = model.log_page_requested orelse return .none;
    if (lpl.request_skip != expected_skip) return .none;
    // ★H-07: request_tip 照合
    if (model.log_paging_tip) |tip| {
        if (!std.mem.eql(u8, tip, lpl.request_tip)) return .none;
    } else {
        return .none;
    }
    // ★R22: page_requested を先に null 化
    model.log_page_requested = null;
    try model.appendLogCommits(lpl.entries);
    model.log_has_more = lpl.entries.len >= lpl.request_max_count;
    if (model.log_commits.items.len == 0) return .none;
    // ★phase 2 M-11: グラフ計算（.valid→incremental / .invalid→computeAll）
    switch (model.log_graph_state) {
        .valid => {
            // H-04/H-08: computeIncremental は入力 state を破壊しない
            const new_state = graph_mod.computeIncremental(model.allocator, model.log_graph_state, lpl.entries) catch {
                model.invalidateLogGraph();
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(new_state);
        },
        .invalid => {
            const tip_const: ?[]const u8 = if (model.log_paging_tip) |t| t else null;
            const gs = graph_mod.computeAll(model.allocator, model.log_commits.items, model.log_request_generation, tip_const) catch {
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(gs);
        },
    }
    return try loadCommitDetailForSelection(model);
}
```

### Step 4: `handleLogCursorDown` の `load_log_page` で tip を渡す

`handleLogCursorDown` の paging trigger で tip_hash を含める:

```zig
        model.log_page_requested = len;
        const tip_dup = try model.allocator.dupe(u8, model.log_paging_tip orelse model.log_commits.items[0].hash);
        return .{ .load_log_page = .{
            .skip = len,
            .max_count = 100,
            .generation = model.log_request_generation,
            .tip_hash = tip_dup,
        } };
```

### Step 5: `git_error` arm へ bad revision 回復を追加

`update` 関数の `.git_error` arm へ、log モード時の回復を追加:

```zig
        .git_error => |err_text| {
            if (model.view_mode == .log) {
                // ★M-12: log 中の git_error（bad revision 等）は全 refresh へ
                model.log_request_generation += 1;
                model.log_page_requested = null;
                model.log_has_more = false;
                model.invalidateLogGraph();
                model.clearLogPagingTip();
                try model.replaceLogCommits(&.{});
                model.clearDetailOwner();
                try model.replaceDetailFiles(&.{});
                try model.setStr(&model.detail_diff, "");
                model.detail_kind = .files;
                try model.setStr(&model.error_text, err_text);
                return .{ .load_log = .{
                    .skip = 0,
                    .max_count = 100,
                    .generation = model.log_request_generation,
                } };
            }
            try model.setStr(&model.error_text, err_text);
            return .none;
        },
```

### Step 6: `handleToggleViewMode` と `handleRequestRefreshLog` へグラフ無効化を追加

`handleToggleViewMode` の両方の分岐（changes→log / log→changes）で:

```zig
        .changes => {
            // 既存コード...
            model.invalidateLogGraph();
            model.clearLogPagingTip();
            // ...
        },
        .log => {
            // 既存コード...
            model.invalidateLogGraph();
            model.clearLogPagingTip();
            // ...
        },
```

`handleRequestRefreshLog` で:

```zig
fn handleRequestRefreshLog(model: *Model) !AppCmd {
    model.log_request_generation += 1;
    model.log_page_requested = null;
    model.log_has_more = false;
    model.invalidateLogGraph(); // ★phase 2
    model.clearLogPagingTip(); // ★phase 2
    // ... 既存のコード（restore hash / replaceLogCommits / clearDetail）
    return .{ .load_log = .{ ... } };
}
```

### Step 7: テストを追加・更新

`handleLogLoaded` / `handleLogPageLoaded` の既存テストへ `log_graph_state` 検証を追加:

```zig
test "log_loaded: builds graph state on success" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 1;
    var entries: [1]log_mod.Commit = undefined;
    entries[0] = try mkCommit(a, "h0001", "subj");
    defer entries[0].deinit(a);
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0,
        .request_max_count = 100,
        .request_generation = 1,
        .entries = &entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(m.log_graph_state == .valid);
    try std.testing.expectEqual(@as(usize, 1), m.log_graph_state.valid.rows.items.len);
    try std.testing.expectEqualStrings("h0001", m.log_paging_tip.?);
}

test "git_error in log mode triggers full refresh with generation bump" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 5;
    var msg = Msg{ .git_error = try a.dupe(u8, "tip expired") };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    try std.testing.expectEqual(@as(u64, 6), m.log_request_generation);
    try std.testing.expect(m.log_graph_state == .invalid);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_paging_tip);
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
}
```

### Step 8: テストを実行

Run: `zig build test --summary all`
Expected: PASS（全コンパイルエラー解消）

### Step 9: Commit

```bash
git add src/update.zig
git commit -m "feat(update): wire graph computation into log reducers with OOM fallback (H-05/M-11)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 9: `src/view.zig` — グラフ描画 + UTC date + 色ローテーション + 段階的省略

**Files:**
- Modify: `src/view.zig`

### Step 1: `graph_mod` import を追加

`src/view.zig` の import セクションへ追加:

```zig
const graph_mod = @import("git/graph.zig");
```

### Step 2: UTC date フォーマット関数を追加

`renderLog` の前に追加:

```zig
/// ★M-07(再): epoch_sec → "YYYY-MM-DD" (UTC) の 10 桁文字列。
fn formatAuthorDateUTC(a: std.mem.Allocator, epoch_sec: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_sec) };
    const day = es.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, day.year),
        @as(u32, month_day.month.numeric()),
        @as(u32, month_day.day_index + 1),
    }) catch "????-??-??";
}
```

### Step 3: グラフセル描画ヘルパを追加

```zig
/// グラフセル（Conn）を box-drawing 文字へ変換。レーン色は 6 色ローテーション。
const LANE_COLORS = [_]zz.Color{
    zz.Color.red, zz.Color.green, zz.Color.yellow,
    zz.Color.blue, zz.Color.magenta, zz.Color.cyan,
};

fn laneColor(lane: u16) zz.Color {
    return LANE_COLORS[lane % LANE_COLORS.len];
}

/// 1 行のグラフ部分を描画（spec §D）。cells 配列から ANSI 付き文字列を構築。
fn renderGraphCells(a: std.mem.Allocator, row: graph_mod.GraphRow, max_width: u16) []const u8 {
    if (max_width == 0) return "";
    var parts: std.ArrayList([]const u8) = .empty;
    const w: usize = @min(@as(usize, max_width), row.cells.len);
    for (row.cells[0..w], 0..) |cell, i| {
        const lane: u16 = @intCast(i);
        const ch: []const u8 = if (cell.is_node)
            "●"
        else if (cell.up and cell.down)
            "│"
        else if (cell.up and !cell.down)
            "╵"
        else if (!cell.up and cell.down)
            "╷"
        else if (cell.left and cell.right)
            "─"
        else if (cell.left and !cell.right)
            "╴"
        else if (cell.right and !cell.left)
            "╶"
        else
            " ";
        const style = zz.Style{ .foreground = laneColor(lane), .bold_attr = cell.is_node };
        const styled = style.render(a, ch) catch ch;
        parts.append(a, styled) catch {};
    }
    return std.mem.join(a, "", parts.items) catch "";
}
```

### Step 4: `renderLog` のシグネチャを変更し width を受け取る

`renderLogMode` が `layout.log.w` を `renderLog` へ渡すよう変更。既存の `fn renderLog(model, ctx, height)` を `fn renderLog(model, ctx, height, pane_w)` へ:

`renderLogMode` 内の呼び出しを変更:
```zig
    const log = fitPane(a, renderLog(model, ctx, layout.log.h, layout.log.w), layout.log);
```

### Step 5: `renderLog` を拡張

既存の `renderLog` を以下へ置換:

```zig
fn renderLog(model: *Model, ctx: *const zz.Context, height: u16, pane_w: u16) []const u8 {
    const a = ctx.allocator;
    if (model.log_commits.items.len == 0) return "(no commits)";

    const limit: usize = if (height == 0) 1 else height;
    const total = model.log_commits.items.len;

    model.log_scroll = ensureVisible(model.log_scroll, model.log_selected, limit);
    if (model.log_scroll >= total) model.log_scroll = if (total == 0) 0 else total - 1;

    // ★M-13: 段階的カラム省略の決定（最小 subject 幅 10 を先予約）
    const subject_min: usize = 10;
    const hash_w: usize = 7;
    const show_graph = pane_w >= 30 and model.log_graph_state == .valid;
    const show_date = pane_w >= 60;
    const show_author = pane_w >= 45;
    const author_max: usize = if (pane_w >= 60) 12 else if (pane_w >= 45) 8 else 0;
    _ = subject_min;
    _ = hash_w;

    // グラフ rows の取得
    const graph_rows: ?[]const graph_mod.GraphRow = if (model.log_graph_state == .valid)
        model.log_graph_state.valid.rows.items
    else
        null;

    var lines: std.ArrayList([]const u8) = .empty;
    const start = model.log_scroll;
    const end = @min(total, start + limit);
    for (model.log_commits.items[start..end], start..) |c, i| {
        const selected = (i == model.log_selected);
        const short_hash = if (c.hash.len >= 7) c.hash[0..7] else c.hash;

        var parts: std.ArrayList([]const u8) = .empty;
        // graph
        if (show_graph and graph_rows != null and i < graph_rows.?.len) {
            const graph_str = renderGraphCells(a, graph_rows.?[i], 20);
            parts.append(a, graph_str) catch {};
            parts.append(a, " ") catch {};
        }
        // refs (M-06: subject 前)
        if (c.refs.len > 0) {
            const refs_style = zz.Style{ .foreground = zz.Color.green };
            const refs_styled = refs_style.render(a, c.refs) catch c.refs;
            parts.append(a, refs_styled) catch {};
            parts.append(a, " ") catch {};
        }
        // hash
        parts.append(a, short_hash) catch {};
        parts.append(a, " ") catch {};
        // subject
        parts.append(a, c.subject) catch {};
        // author
        if (show_author) {
            parts.append(a, " ") catch {};
            parts.append(a, c.author) catch {};
        }
        // date
        if (show_date) {
            parts.append(a, " ") catch {};
            const date_str = formatAuthorDateUTC(a, c.epoch_sec);
            parts.append(a, date_str) catch {};
        }

        const line = std.mem.join(a, "", parts.items) catch short_hash;
        if (selected) {
            const style = zz.Style{ .reverse_attr = true };
            const styled = style.render(a, line) catch line;
            lines.append(a, styled) catch {};
        } else {
            lines.append(a, line) catch {};
        }
    }
    if (lines.items.len == 0) return "(no commits)";
    return std.mem.join(a, "\n", lines.items) catch "(log render error)";
}
```

### Step 6: テストを追加

```zig
test "formatAuthorDateUTC: formats epoch to YYYY-MM-DD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2023-11-14 22:13:20 UTC = 1700000000
    const date = formatAuthorDateUTC(a, 1700000000);
    try std.testing.expectEqualStrings("2023-11-14", date);
}
```

### Step 7: テストを実行

Run: `zig build test --summary all`
Expected: PASS

### Step 8: Commit

```bash
git add src/view.zig
git commit -m "feat(view): render graph cells, UTC date, and color rotation in renderLog

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 10: `README.md` + `TODO.md` 更新

**Files:**
- Modify: `README.md`
- Modify: `TODO.md`

### Step 1: `README.md` へ phase 2 表示要素を追記

README の log モード説明へ以下を追記:

- グラフ罫線（`│ ├ └ ┐ ┘ ●` 等・6 色ローテーション）でブランチ分岐/マージを表示
- author 名とコミット日時（UTC `YYYY-MM-DD`）を各行に表示
- 狭い端末では subject/hash を優先し、グラフ/author/date を段階的に省略
- 色は branch identity ではなく視認補助（同一色が別ブランチに使われることがある）

### Step 2: `TODO.md` の phase 2 を分割

`TODO.md` の TODO 2 phase 2 セクションを「表示系（完了）」と「フィルタ（未実装）」へ分割:

- phase 2 表示系の Sub Tasks のチェックボックス `[x]` をマーク:
  - `[x]` グラフレーン割当アルゴリズム（frontier-based 自前）
  - `[x]` グラフ描画（`│ ├ └ ┐ ┘ ●` + 色分け）
  - `[x]` 日本語の author/subject/refs の桁計算（East Asian Width: zigzag 既存機能）
  - `[x]` author / コミット日時の表示（UTC YYYY-MM-DD）
- フィルタ機能は独立セクション「phase 3（フィルタ）— 未実装」として残す

### Step 3: Commit

```bash
git add README.md TODO.md
git commit -m "docs: update README and TODO for phase 2 display layer completion

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 11: 手動 pty 検証

**Files:** （コード変更なし・検証のみ）

### Step 1: 分岐/マージ履歴のテストリポジトリを作成

```bash
cd /tmp && rm -rf graph-test && mkdir graph-test && cd graph-test
git init
git config user.email "test@test.com"
git config user.name "tester"
echo "a" > f.txt && git add f.txt && git commit -m "commit A"
echo "b" >> f.txt && git commit -am "commit B"
git checkout -b feature
echo "c" >> f.txt && git commit -am "commit C on feature"
git checkout main
echo "d" >> f.txt && git commit -am "commit D on main"
git merge --no-ff feature -m "merge feature into main"
echo "e" >> f.txt && git commit -am "commit E"
```

### Step 2: TUI を起動してグラフを目視確認

```bash
cd /tmp/graph-test
zig build && zig-out/bin/git-tui
# L キーで log モードへ
# グラフ罫線・色分け・author/date が表示されることを確認
# j/k でコミット移動・グラフが追従することを確認
```

### Step 3: `tmux capture-pane` でスクリーンショット取得

```bash
tmux new-session -d -s test -x 120 -y 40
tmux send-keys -t test "cd /tmp/graph-test && zig-out/bin/git-tui" Enter
sleep 1
tmux send-keys -t test "L"
sleep 1
tmux capture-pane -p -t test
# グラフ罫線（│ ● ┐ ┘ 等）と author/date が表示されていることを確認
```

### Step 4: 100 件超でページング + グラフ接続を確認

100+ コミットのリポジトリで j/k を連打し、ページング発火後にグラフが正しく接続されることを確認。

### Step 5: 最終 build test

Run: `zig build test --summary all`
Expected: ALL PASS

---

## 自己レビューチェックリスト

実装完了後、以下を確認:

1. **spec カバレッジ**: spec の各セクションがどの Task で実装されているか:
   - §A（アルゴリズム）→ Task 1-3
   - §B（データ構造）→ Task 1, 6
   - §D（描画）→ Task 9
   - §E（paging/所有権）→ Task 7, 8
   - §F（テスト）→ 各 Task の Step
2. **プレースホルダ**: TBD/TODO なし
3. **型一貫性**: `LoadLogPage`/`LogPageLoaded`/`GraphState`/`GraphRow` が全 Task で同じ定義
4. **所有権**: `tip_hash` の dupe/free が `messages.zig`/`model.zig`/`appcmd.zig` で一貫
5. **Zig 0.16**: `ArrayList` unmanaged・`std.time.epoch`・`std.process.run` 全て正しい API
