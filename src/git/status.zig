const std = @import("std");

pub const Section = enum { staged, unstaged, untracked };

pub const StatusEntry = struct {
    path: []u8,
    orig_path: ?[]u8, // rename/copy のときの旧パス
    section: Section,
    pub fn deinit(self: *StatusEntry, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.orig_path) |p| a.free(p);
    }
};

pub const ParseError = error{ MalformedRecord, OutOfMemory };

/// 呼び出し側が返り値スライスと各要素を解放する。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError![]StatusEntry {
    var list: std.ArrayList(StatusEntry) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(a);
        list.deinit(a);
    }

    var it = std.mem.splitScalar(u8, raw, 0); // NUL 区切りトークン
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        switch (tok[0]) {
            '1' => try appendOrdinary(a, &list, tok, null),
            '2' => {
                // rename/copy: このレコードの後に NUL 区切りの origPath が続く
                const orig = it.next() orelse return ParseError.MalformedRecord;
                try appendOrdinary(a, &list, tok, orig);
            },
            '?' => {
                const path = tok[2..]; // "? <path>"
                try list.append(a, .{
                    .path = try a.dupe(u8, path),
                    .orig_path = null,
                    .section = .untracked,
                });
            },
            'u', '!' => {}, // MVP: 未マージ/ignored はスキップ
            else => return ParseError.MalformedRecord,
        }
    }
    return list.toOwnedSlice(a);
}

// "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>" / "2 <XY> ... <Xscore> <path>"
// orig_path 非 null なら rename/copy（type 2）。staged エントリに orig_path を付ける。
fn appendOrdinary(
    a: std.mem.Allocator,
    list: *std.ArrayList(StatusEntry),
    tok: []const u8,
    orig_path: ?[]const u8,
) ParseError!void {
    const is_rename = orig_path != null;
    var fields = std.mem.tokenizeScalar(u8, tok, ' ');
    _ = fields.next(); // "1" or "2"
    const xy = fields.next() orelse return ParseError.MalformedRecord;
    if (xy.len < 2) return ParseError.MalformedRecord;
    // パスは固定数フィールドの後ろ。type1=skip6, type2=skip7(score が 1 つ多い)。
    const skip: usize = if (is_rename) 7 else 6;
    var i: usize = 0;
    while (i < skip) : (i += 1) _ = fields.next() orelse return ParseError.MalformedRecord;
    const path = fields.rest(); // 残り全部がパス（空白を含みうる）
    if (path.len == 0) return ParseError.MalformedRecord;

    // X(index)=staged 側, Y(worktree)=unstaged 側。spec §2: 同一ファイルが両方の変更を持つ場合は
    // **staged と unstaged の 2 エントリ**を生成する（(path, section) をキーに別管理）。
    // orig_path は **R(rename)/C(copy) の側だけ**に付ける（type2 でも片側のみが rename のことがある）。
    const x = xy[0];
    const y = xy[1];
    if (x != '.') {
        const op = try list.addOne(a);
        const is_x_rename = (x == 'R' or x == 'C');
        op.* = .{
            .path = try a.dupe(u8, path),
            .orig_path = if (is_x_rename) (if (orig_path) |o| try a.dupe(u8, o) else null) else null,
            .section = .staged,
        };
    }
    if (y != '.') {
        const op = try list.addOne(a);
        const is_y_rename = (y == 'R' or y == 'C');
        op.* = .{
            .path = try a.dupe(u8, path),
            .orig_path = if (is_y_rename) (if (orig_path) |o| try a.dupe(u8, o) else null) else null,
            .section = .unstaged,
        };
    }
}

test "parses modified-in-worktree (type 1) as unstaged" {
    const a = std.testing.allocator;
    // XY=".M" → unstaged 変更。フィールドは porcelain v2 の固定順。
    const raw = "1 .M N... 100644 100644 100644 0000000 0000000 README.md\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("README.md", entries[0].path);
    try std.testing.expectEqual(Section.unstaged, entries[0].section);
    try std.testing.expect(entries[0].orig_path == null);
}

test "parses rename (type 2) consuming two paths" {
    const a = std.testing.allocator;
    // "2 R. <...> R100 <newpath>\x00<origpath>\x00"
    const raw = "2 R. N... 100644 100644 100644 0000000 0000000 R100 new.txt\x00old.txt\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("new.txt", entries[0].path);
    try std.testing.expectEqualStrings("old.txt", entries[0].orig_path.?);
    try std.testing.expectEqual(Section.staged, entries[0].section);
}

test "rename followed by another entry does not desync" {
    const a = std.testing.allocator;
    const raw =
        "2 R. N... 100644 100644 100644 0000000 0000000 R100 new.txt\x00old.txt\x00" ++
        "1 .M N... 100644 100644 100644 0000000 0000000 after.txt\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("after.txt", entries[1].path);
}

test "parses untracked single question mark" {
    const a = std.testing.allocator;
    const raw = "? 新規ファイル.txt\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(Section.untracked, entries[0].section);
    try std.testing.expectEqualStrings("新規ファイル.txt", entries[0].path);
}

test "staged modification (X=M) is staged section" {
    const a = std.testing.allocator;
    const raw = "1 M. N... 100644 100644 100644 0000000 0000000 src/main.zig\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(Section.staged, entries[0].section);
}

test "dual section: XY=MM yields both staged and unstaged entries" {
    const a = std.testing.allocator;
    const raw = "1 MM N... 100644 100644 100644 0000000 0000000 both.txt\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(Section.staged, entries[0].section);
    try std.testing.expectEqual(Section.unstaged, entries[1].section);
    try std.testing.expectEqualStrings("both.txt", entries[0].path);
    try std.testing.expectEqualStrings("both.txt", entries[1].path);
}

test "unstaged-side rename (XY=.R) puts orig_path on the unstaged entry" {
    const a = std.testing.allocator;
    const raw = "2 .R N... 100644 100644 100644 0000000 0000000 R100 new.txt\x00old.txt\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Section.unstaged, entries[0].section);
    try std.testing.expectEqualStrings("old.txt", entries[0].orig_path.?);
}
