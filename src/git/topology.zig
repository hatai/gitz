//! `git rev-list --topo-order --parents <tip>` 出力のパーサ（zigzag 非依存）。
//! 出力は改行区切り・各行 "<hash>[ <parent>...]"（root は hash 単独）。
//! phase 3b #2: フィルタ中 graph 投影のための全履歴 topology substrate。

const std = @import("std");

pub const Entry = struct {
    hash: []u8,
    parents: [][]u8,
    // perf phase2/§6.2: hash/parents は backing arena 内（個別 free 不要）。Entry.deinit は提供しない。
};

/// phase 3b #2 + perf phase2/§6.2: 全 hash/parents 文字列を **backing arena** へ一括配置し、
/// parse の O(N×P) 個別 dupe を arena 配下へ集約（`std.testing.allocator` 視点で alloc 数大幅減）。
/// `hash_index` は backing と別（呼出側 allocator `a`）で keys は entries[].hash を借用。
/// clone は廃止・Msg から Model へ take（move）で所有権移譲（§6.1 `*Msg` API と組合せ）。
pub const TopologySubstrate = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry, // arena 内（topo 順・newest-first・rev-list 出力順）
    hash_index: std.StringHashMap(usize), // a 上・hash -> entries index（keys は entries[].hash を借用 = arena 内）

    pub fn deinit(self: *TopologySubstrate, a: std.mem.Allocator) void {
        // 順序厳守: hash_index 先（keys は entries[].hash を借用 = arena 内・hash_index は keys を free しない）。
        //   arena を先に解放すると keys が消え hash_index.deinit が freed memory を触り得るため逆順。
        //   `a` は署名互換で残す（hash_index は init(a) で allocator を内部保持・arena も自己管理）。
        _ = a;
        self.hash_index.deinit();
        self.arena.deinit();
    }
};

pub const ParseError = error{ OutOfMemory };

/// `git rev-list --topo-order --parents <tip>` 出力をパース。
/// 空入力（unborn 等）= entries 空・hash_index 空（valid）。
/// perf phase2/§6.2: 全 hash/parents を backing arena へ（O(N×P) dupe を arena 配下へ集約）。
/// hash_index は `a`（呼出側）上へ・keys は entries[].hash を借用。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError!TopologySubstrate {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var entries_list: std.ArrayList(Entry) = .empty;
    var line_it = std.mem.splitScalar(u8, raw, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue; // 末尾改行等の空行
        var tok_it = std.mem.splitScalar(u8, line, ' ');
        const hash_tok = tok_it.next() orelse continue;
        const hash = try aa.dupe(u8, hash_tok);
        var parents: std.ArrayList([]u8) = .empty;
        while (tok_it.next()) |pt| {
            if (pt.len == 0) continue;
            const pd = try aa.dupe(u8, pt);
            try parents.append(aa, pd);
        }
        const parents_slice = try parents.toOwnedSlice(aa);
        try entries_list.append(aa, .{ .hash = hash, .parents = parents_slice });
    }
    const entries = try entries_list.toOwnedSlice(aa);
    var idx = std.StringHashMap(usize).init(a); // hash_index は呼出側 allocator 上
    errdefer idx.deinit();
    for (entries, 0..) |e, i| try idx.put(e.hash, i);
    return .{ .arena = arena, .entries = entries, .hash_index = idx };
}


test "parse: linear (3 commits, each 1 parent)" {
    const a = std.testing.allocator;
    // topo newest-first: C←B, B←A, A root
    const raw = "C B\nB A\nA\n";
    var sub = try parse(a, raw);
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), sub.entries.len);
    try std.testing.expectEqualStrings("C", sub.entries[0].hash);
    try std.testing.expectEqual(@as(usize, 1), sub.entries[0].parents.len);
    try std.testing.expectEqualStrings("B", sub.entries[0].parents[0]);
    try std.testing.expectEqual(@as(usize, 0), sub.entries[2].parents.len); // A root
    // hash_index lookup
    try std.testing.expectEqual(@as(?usize, 0), sub.hash_index.get("C"));
    try std.testing.expectEqual(@as(?usize, 2), sub.hash_index.get("A"));
    try std.testing.expectEqual(@as(?usize, null), sub.hash_index.get("Z")); // miss
}

test "parse: merge commit (2 parents space-separated)" {
    const a = std.testing.allocator;
    const raw = "D B C\nC A\nB A\nA\n";
    var sub = try parse(a, raw);
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), sub.entries[0].parents.len);
    try std.testing.expectEqualStrings("B", sub.entries[0].parents[0]);
    try std.testing.expectEqualStrings("C", sub.entries[0].parents[1]);
}

test "parse: empty input returns empty valid substrate" {
    const a = std.testing.allocator;
    var sub = try parse(a, "");
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), sub.entries.len);
}

test "parse: trailing newline only yields empty" {
    const a = std.testing.allocator;
    var sub = try parse(a, "\n");
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), sub.entries.len);
}

test "parse: arena backing - entries/hash_index が解放されリークゼロ（perf phase2/§6.2）" {
    const a = std.testing.allocator;
    var sub = try parse(a, "C B\nB A\nA\n");
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), sub.entries.len);
    try std.testing.expectEqualStrings("C", sub.entries[0].hash);
    try std.testing.expectEqual(@as(?usize, 0), sub.hash_index.get("C"));
    // arena backing: hash 文字列は arena 内（個別 free 不要・deinit で arena 一括解放）
}

test "parse: no invalid free / leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndFree, .{});
}

fn parseAndFree(a: std.mem.Allocator) !void {
    const raw = "D B C\nC A\nB A\nA\n";
    var sub = try parse(a, raw);
    sub.deinit(a);
}

test {
    std.testing.refAllDecls(@This());
}
