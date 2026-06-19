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
        var row = try processCommit(a, &frontier, c);
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

/// 増分: 入力 GraphState を消費（所有権移行）し、delta rows + 新 frontier を構築 → 新 state 返却。
/// 既存 rows の deep-copy はしない（H-08: O(N²) 回避）。代わりに GraphRow 構造体を
/// 新 ArrayList へ move し、元 state は `.invalid` へ遷移させる（消費済みを示す）。
/// 強例外保証: 失敗時は入力 state を一切触らない（fallible 操作を全て先行）。
///
/// NOTE: 設計上 `state: *GraphState`（ポインタ）を採用。値渡しでは呼び出し元の base と
/// 返却 state が同じ cells ポインタを共有し、両者の deinit で二重解放となるため。
pub fn computeIncremental(
    a: std.mem.Allocator,
    state: *GraphState,
    new_commits: []const log.Commit,
) !GraphState {
    if (state.* != .valid) return error.InvalidState;
    const src = &state.valid;

    // 返却に必要なスカラー値を事前退避（消費後に src へアクセスしないため）
    const generation = src.generation;
    const old_processed_len = src.processed_len;
    const old_rows_len = src.rows.items.len;

    // 1. combined バッファを先行確保（この時点では所有する row 無し・空）
    var combined: std.ArrayList(GraphRow) = .empty;
    errdefer combined.deinit(a); // 空 → buffer free のみ
    try combined.ensureTotalCapacity(a, old_rows_len + new_commits.len);

    // 2. frontier を clone（処理用の一時状態）
    var tmp_frontier = try src.frontier.clone(a);
    errdefer tmp_frontier.deinit(a);

    // 3. delta rows を新規構築（cloned frontier 上で処理）
    var delta_rows: std.ArrayList(GraphRow) = .empty;
    errdefer {
        for (delta_rows.items) |*r| r.deinit(a);
        delta_rows.deinit(a);
    }
    for (new_commits) |c| {
        var row = try processCommit(a, &tmp_frontier, c);
        errdefer row.deinit(a);
        try delta_rows.append(a, row);
    }

    // 4. tip_hash を clone
    const tip_dup: ?[]u8 = if (src.tip_hash) |t| try a.dupe(u8, t) else null;
    errdefer if (tip_dup) |t| a.free(t);

    // === ここから先は infallible（try 無し）===
    // 5. src.rows + delta_rows を combined へ move（cells ポインタの所有権移行）
    for (src.rows.items) |r| {
        combined.appendAssumeCapacity(r);
    }
    for (delta_rows.items) |r| {
        combined.appendAssumeCapacity(r);
    }
    delta_rows.deinit(a); // items は combined へ移行済み・buffer のみ解放

    // 6. 入力 state を消費: cells は combined へ移動済み。
    //    rows.items.len = 0 にして deinit ループが cells を解放しないようにし、
    //    その後 state.deinit で rows buffer・frontier・tip_hash を解放 → invalid へ。
    src.rows.items.len = 0;
    state.deinit(a);
    state.* = .invalid;

    return .{ .valid = .{
        .generation = generation,
        .processed_len = old_processed_len + new_commits.len,
        .tip_hash = tip_dup,
        .rows = combined,
        .frontier = tmp_frontier,
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

    // before frontier のスナップショット（cells の up 接続用）—
    // 新規 tip append 前に取得することで、追加 slot に up 接続が付かないようにする
    // （新規 tip は前行から伝播していないため up=false が正）。
    const before_len = frontier.slots.items.len;
    var before_has: []bool = try a.alloc(bool, before_len);
    defer a.free(before_has);
    for (frontier.slots.items, 0..) |slot, i| {
        before_has[i] = slot != null;
    }

    // 代表 lane の決定
    const node_lane: u16 = if (match_lanes.items.len > 0)
        @intCast(match_lanes.items[0])
    else blk: {
        // 新規 tip: frontier 末尾へ append
        const h = try a.dupe(u8, c.hash);
        errdefer a.free(h); // append 失敗時の h 解放（frontier 未登録のため）
        try frontier.slots.append(a, h);
        break :blk @intCast(frontier.slots.items.len - 1);
    };

    // (3) frontier[node_lane] を消費
    if (frontier.slots.items[node_lane]) |h| a.free(h);
    frontier.slots.items[node_lane] = null;

    // 水平接続: H-01 で集約される余分 match の記録用
    var agg_lanes: std.ArrayList(usize) = .empty;
    defer agg_lanes.deinit(a);
    if (match_lanes.items.len > 1) {
        for (match_lanes.items[1..]) |ml| {
            try agg_lanes.append(a, ml);
            if (frontier.slots.items[ml]) |h| a.free(h);
            frontier.slots.items[ml] = null;
        }
    }

    // (4) parents の配置
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
            var found_p: bool = false;
            for (frontier.slots.items) |slot| {
                if (slot) |h| {
                    if (std.mem.eql(u8, h, p)) {
                        found_p = true;
                        break;
                    }
                }
            }
            if (!found_p) {
                // 既存へ集約されなければ node_lane の直後に挿入
                const p_dup = try a.dupe(u8, p);
                errdefer a.free(p_dup); // insert 失敗時の p_dup 解放（frontier 未登録のため）
                try frontier.slots.insert(a, node_lane + 1, p_dup);
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

fn mkCommit(a: std.mem.Allocator, hash: []const u8, parents: []const []const u8) !log.Commit {
    var ps: std.ArrayList([]u8) = .empty;
    errdefer {
        for (ps.items) |p| a.free(p);
        ps.deinit(a);
    }
    for (parents) |p| {
        const p_dup = try a.dupe(u8, p);
        errdefer a.free(p_dup);
        try ps.append(a, p_dup);
    }
    const parents_slice = try ps.toOwnedSlice(a);
    errdefer {
        for (parents_slice) |p| a.free(p);
        a.free(parents_slice);
    }

    const h = try a.dupe(u8, hash);
    errdefer a.free(h);

    const author = try a.dupe(u8, "tester");
    errdefer a.free(author);

    const subject = try a.dupe(u8, "subj");
    errdefer a.free(subject);

    const refs = try a.dupe(u8, "");
    errdefer a.free(refs);

    return .{
        .hash = h,
        .parents = parents_slice,
        .author = author,
        .epoch_sec = 1000,
        .subject = subject,
        .refs = refs,
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
    // Row 0: no horizontal connections
    try std.testing.expect(!v.rows.items[0].cells[0].left);
    try std.testing.expect(!v.rows.items[0].cells[0].right);
    // Row 1 (B): up + node + down
    try std.testing.expect(v.rows.items[1].cells[0].up);
    try std.testing.expect(v.rows.items[1].cells[0].is_node);
    try std.testing.expect(v.rows.items[1].cells[0].down);
    // Row 1: no horizontal connections
    try std.testing.expect(!v.rows.items[1].cells[0].left);
    try std.testing.expect(!v.rows.items[1].cells[0].right);
    // Row 2 (A, root): up + node, no down
    try std.testing.expect(v.rows.items[2].cells[0].up);
    try std.testing.expect(v.rows.items[2].cells[0].is_node);
    try std.testing.expect(!v.rows.items[2].cells[0].down);
    // Row 2: no horizontal connections
    try std.testing.expect(!v.rows.items[2].cells[0].left);
    try std.testing.expect(!v.rows.items[2].cells[0].right);
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
    // col 1: B node (new tip, no up), left connection to col 0 (aggregation)
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
    // H-01 aggregation: B's parent A aggregates to lane 1 (A already in
    // frontier after C's processing). node_lane=0 ↔ lane 1 horizontal link.
    try std.testing.expect(v.rows.items[2].cells[0].right);
    try std.testing.expect(v.rows.items[2].cells[1].left);
    // lane 1 was occupied by A in before-frontier → up connection
    try std.testing.expect(v.rows.items[2].cells[1].up);

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
    // M-01 (interior hole removal): after B's processing the frontier was
    // [null, A] (hole at position 0 from consumed B). Compaction must move
    // A to position 0. As a result Row 3 (A) has width 1 — if compaction
    // only trimmed the tail, A would still sit at lane 1 and width would be 2.
    try std.testing.expectEqual(@as(u16, 0), state.valid.rows.items[3].node_lane);
    try std.testing.expectEqual(@as(usize, 1), state.valid.rows.items[3].width());
}

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

    // computeAll for first 3, then computeIncremental for last 2.
    // NOTE: computeIncremental consumes base (sets it to .invalid), so the
    // deferred base.deinit is a no-op after the call.
    var base = try computeAll(a, all[0..3], 1, "E");
    defer base.deinit(a);

    var incr = try computeIncremental(a, &base, all[3..5]);
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

    // computeIncremental consumes base (move semantics) → base becomes .invalid.
    // The deferred base.deinit is therefore a no-op (not corrupted, just consumed).
    // Strong exception guarantee applies to the *failure* path: on error, base
    // would be left untouched.
    var incr = try computeIncremental(a, &base, commits[1..2]);
    defer incr.deinit(a);

    // base was consumed (now .invalid); base.deinit() via defer is a no-op.
    // incr owns all rows (moved from base + new delta).
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

test {
    std.testing.refAllDecls(@This());
}
