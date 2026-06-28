//! `git rev-list --topo-order --parents <tip>` 出力のパーサ（zigzag 非依存）。
//! 出力は改行区切り・各行 "<hash>[ <parent>...]"（root は hash 単独）。
//! phase 3b #2: フィルタ中 graph 投影のための全履歴 topology substrate。

const std = @import("std");

pub const Entry = struct {
    hash: []u8,
    parents: [][]u8,
    pub fn deinit(self: *Entry, a: std.mem.Allocator) void {
        a.free(self.hash);
        for (self.parents) |p| a.free(p);
        a.free(self.parents);
    }
};

pub const TopologySubstrate = struct {
    entries: []Entry, // topo 順（newest-first・rev-list 出力順）
    hash_index: std.StringHashMap(usize), // hash -> entries index（keys は entries[].hash を借用）

    pub fn deinit(self: *TopologySubstrate, a: std.mem.Allocator) void {
        // StringHashMap は keys を free しない（構造体のみ）→ entries 先に解放しても安全。
        for (self.entries) |*e| e.deinit(a);
        a.free(self.entries);
        self.hash_index.deinit();
    }

    pub fn clone(self: TopologySubstrate, a: std.mem.Allocator) std.mem.Allocator.Error!TopologySubstrate {
        const out_entries = try a.alloc(Entry, self.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (out_entries[0..initialized]) |*e| e.deinit(a);
            a.free(out_entries);
        }
        for (self.entries, 0..) |e, i| {
            const h = try a.dupe(u8, e.hash);
            errdefer a.free(h);
            const ps = try a.alloc([]u8, e.parents.len);
            var pinit: usize = 0;
            errdefer {
                for (ps[0..pinit]) |p| a.free(p);
                a.free(ps);
            }
            for (e.parents, 0..) |p, j| {
                ps[j] = try a.dupe(u8, p);
                pinit = j + 1;
            }
            out_entries[i] = .{ .hash = h, .parents = ps };
            initialized = i + 1;
        }
        var idx = std.StringHashMap(usize).init(a);
        errdefer idx.deinit();
        for (out_entries, 0..) |e, i| try idx.put(e.hash, i);
        return .{ .entries = out_entries, .hash_index = idx };
    }
};

pub const ParseError = error{ OutOfMemory };

/// `git rev-list --topo-order --parents <tip>` 出力をパース。
/// 空入力（unborn 等）= entries 空・hash_index 空（valid）。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError!TopologySubstrate {
    var entries_list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries_list.items) |*e| e.deinit(a);
        entries_list.deinit(a);
    }
    var line_it = std.mem.splitScalar(u8, raw, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue; // 末尾改行等の空行
        var tok_it = std.mem.splitScalar(u8, line, ' ');
        const hash_tok = tok_it.next() orelse continue;
        const hash = try a.dupe(u8, hash_tok);
        errdefer a.free(hash);
        var parents: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parents.items) |p| a.free(p);
            parents.deinit(a);
        }
        while (tok_it.next()) |pt| {
            if (pt.len == 0) continue;
            const pd = try a.dupe(u8, pt);
            errdefer a.free(pd);
            try parents.append(a, pd);
        }
        const parents_slice = try parents.toOwnedSlice(a);
        // toOwnedSlice 後は parents ArrayList は空になり元の errdefer は無害化するので、
        // 新たに parents_slice の解放を登録する（後続 append 失敗時のリーク防止・log.zig:67-73 と同型）。
        errdefer {
            for (parents_slice) |p| a.free(p);
            a.free(parents_slice);
        }
        try entries_list.append(a, .{ .hash = hash, .parents = parents_slice });
    }
    const entries = try entries_list.toOwnedSlice(a);
    // toOwnedSlice 後は entries_list の errdefer は無害化（items 空）。entries の各内容を解放する errdefer を登録。
    errdefer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    var idx = std.StringHashMap(usize).init(a);
    errdefer idx.deinit();
    for (entries, 0..) |e, i| try idx.put(e.hash, i);
    return .{ .entries = entries, .hash_index = idx };
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

test "clone: deep-copies entries and hash_index (no shared pointers)" {
    const a = std.testing.allocator;
    var sub = try parse(a, "C B\nB A\nA\n");
    defer sub.deinit(a);
    var c = try sub.clone(a);
    defer c.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), c.entries.len);
    try std.testing.expectEqualStrings("C", c.entries[0].hash);
    try std.testing.expectEqual(@as(?usize, 0), c.hash_index.get("C"));
    // 独立メモリ
    try std.testing.expect(sub.entries[0].hash.ptr != c.entries[0].hash.ptr);
}

test "parse: no invalid free / leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndFree, .{});
}

fn parseAndFree(a: std.mem.Allocator) !void {
    const raw = "D B C\nC A\nB A\nA\n";
    var sub = try parse(a, raw);
    sub.deinit(a);
}

test "clone: no invalid free / leak on allocation failure (phase 3b #2 M1)" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneAndFree, .{});
}

fn cloneAndFree(a: std.mem.Allocator) !void {
    var sub = try parse(a, "D B C\nC A\nB A\nA\n");
    defer sub.deinit(a);
    var c = try sub.clone(a);
    c.deinit(a);
}

test {
    std.testing.refAllDecls(@This());
}
