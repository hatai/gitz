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
    // （新規 tip は前 行から伝播していないため up=false が正）。
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

test {
    std.testing.refAllDecls(@This());
}
