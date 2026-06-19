//! git show --name-status -z 出力の NUL 区切りパーサ（zigzag 非依存）。
//! `git show --diff-merges=first-parent --format= --name-status -z <hash>` 出力をパースする。
//! R12: -z モードでは R/C の旧パスが先・新パスが次。

const std = @import("std");

pub const ParseError = error{ InvalidFormat, OutOfMemory };

pub const NameStatus = struct {
    status: u8,
    path: []u8,
    orig_path: ?[]u8,
    pub fn deinit(self: *NameStatus, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.orig_path) |p| a.free(p);
    }
};

/// 呼び出し側が返り値スライスと各要素を deinit する（status.parse と同じ契約）。
pub fn parseNameStatus(a: std.mem.Allocator, raw: []const u8) ParseError![]NameStatus {
    var list: std.ArrayList(NameStatus) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(a);
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |status_tok| {
        if (status_tok.len == 0) continue;
        const code = status_tok[0];
        switch (code) {
            'A', 'M', 'D' => {
                const path_tok = it.next() orelse return ParseError.InvalidFormat;
                const p = try a.dupe(u8, path_tok);
                errdefer a.free(p);
                try list.append(a, .{ .status = code, .path = p, .orig_path = null });
            },
            'R', 'C' => {
                // R12: -z 出力は "R100\0old\0new\0"（旧パスが先・新パスが次）
                const orig_tok = it.next() orelse return ParseError.InvalidFormat;
                const new_tok = it.next() orelse return ParseError.InvalidFormat;
                const orig = try a.dupe(u8, orig_tok);
                errdefer a.free(orig);
                const new = try a.dupe(u8, new_tok);
                errdefer a.free(new);
                try list.append(a, .{ .status = code, .path = new, .orig_path = orig });
            },
            else => return ParseError.InvalidFormat,
        }
    }
    return list.toOwnedSlice(a);
}

test "parseNameStatus: tracked modifications (M)" {
    const a = std.testing.allocator;
    const raw = "M\x00f.txt\x00M\x00g.txt\x00";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u8, 'M'), entries[0].status);
    try std.testing.expectEqualStrings("f.txt", entries[0].path);
    try std.testing.expect(entries[0].orig_path == null);
}

test "parseNameStatus: A and D" {
    const a = std.testing.allocator;
    const raw = "A\x00new.txt\x00D\x00old.txt\x00";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(u8, 'A'), entries[0].status);
    try std.testing.expectEqual(@as(u8, 'D'), entries[1].status);
}

test "parseNameStatus: R100 (rename) - orig_path is OLD, path is NEW (R12)" {
    const a = std.testing.allocator;
    const raw = "R100\x00old.txt\x00new.txt\x00";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u8, 'R'), entries[0].status);
    try std.testing.expectEqualStrings("new.txt", entries[0].path);
    try std.testing.expectEqualStrings("old.txt", entries[0].orig_path.?);
}

test "parseNameStatus: C75 (copy with score)" {
    const a = std.testing.allocator;
    const raw = "C75\x00orig.txt\x00copy.txt\x00";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(u8, 'C'), entries[0].status);
    try std.testing.expectEqualStrings("copy.txt", entries[0].path);
    try std.testing.expectEqualStrings("orig.txt", entries[0].orig_path.?);
}

test "parseNameStatus: Japanese path" {
    const a = std.testing.allocator;
    const raw = "M\x00日本語.txt\x00";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqualStrings("日本語.txt", entries[0].path);
}

test "parseNameStatus: empty commit returns empty slice" {
    const a = std.testing.allocator;
    const entries = try parseNameStatus(a, "");
    defer a.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseNameStatus: mixed A/M/D/R in one commit" {
    const a = std.testing.allocator;
    const raw = "A\x00new.txt\x00M\x00mod.txt\x00R100\x00old\x00new\x00D\x00gone.txt\x00";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqual(@as(u8, 'A'), entries[0].status);
    try std.testing.expectEqual(@as(u8, 'M'), entries[1].status);
    try std.testing.expectEqual(@as(u8, 'R'), entries[2].status);
    try std.testing.expectEqualStrings("new", entries[2].path);
    try std.testing.expectEqualStrings("old", entries[2].orig_path.?);
    try std.testing.expectEqual(@as(u8, 'D'), entries[3].status);
}

test "parseNameStatus: no invalid free / leak when allocation fails" {
    const raw = "A\x00new.txt\x00M\x00mod.txt\x00R100\x00old\x00new\x00";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseNameStatusAndFree, .{raw});
}

fn parseNameStatusAndFree(a: std.mem.Allocator, raw: []const u8) !void {
    const entries = try parseNameStatus(a, raw);
    for (entries) |*e| e.deinit(a);
    a.free(entries);
}

test {
    std.testing.refAllDecls(@This());
}
