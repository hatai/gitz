//! コミットログフィルタの純粋データモデル（zigzag 非依存）。
//! phase 3a は作者（`--author`）のみ。phase 3b 拡張ポイント:
//! since/until/path/branches を optional field として追加予定。

const std = @import("std");

pub const max_author_runes: usize = 256;

pub const Error = error{ AuthorTooLong, OutOfMemory };

pub const FilterSpec = struct {
    author: ?[]u8,

    pub fn init() FilterSpec {
        return .{ .author = null };
    }

    pub fn isEmpty(self: FilterSpec) bool {
        if (self.author) |val| return val.len == 0;
        return true;
    }

    // トランザクショナル: dup 成功後に旧を free するため、OOM で self は不変。
    // 空文字は clearAuthor へ正規化。countCodepoints 失敗（invalid UTF-8）も安全側で reject。
    pub fn setAuthor(self: *FilterSpec, a: std.mem.Allocator, value: []const u8) Error!void {
        if (value.len == 0) {
            self.clearAuthor(a);
            return;
        }
        const count = std.unicode.utf8CountCodepoints(value) catch return error.AuthorTooLong;
        if (count > max_author_runes) return error.AuthorTooLong;
        const dup = try a.dupe(u8, value);
        if (self.author) |old| a.free(old);
        self.author = dup;
    }

    pub fn clearAuthor(self: *FilterSpec, a: std.mem.Allocator) void {
        if (self.author) |old| a.free(old);
        self.author = null;
    }

    pub fn clone(self: FilterSpec, a: std.mem.Allocator) Error!FilterSpec {
        var out = FilterSpec.init();
        errdefer out.deinit(a);
        if (self.author) |val| {
            out.author = try a.dupe(u8, val);
        }
        return out;
    }

    pub fn eql(self: FilterSpec, other: FilterSpec) bool {
        if (self.author == null and other.author == null) return true;
        if (self.author == null or other.author == null) return false;
        return std.mem.eql(u8, self.author.?, other.author.?);
    }

    pub fn deinit(self: *FilterSpec, a: std.mem.Allocator) void {
        self.clearAuthor(a);
    }
};

test "FilterSpec: isEmpty/setAuthor/clearAuthor/clone/eql/deinit" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try std.testing.expect(spec.isEmpty());

    try spec.setAuthor(a, "foo");
    try std.testing.expect(!spec.isEmpty());
    try std.testing.expectEqualStrings("foo", spec.author.?);

    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("foo", cloned.author.?);
    try std.testing.expect(spec.author.?.ptr != cloned.author.?.ptr);

    spec.clearAuthor(a);
    try std.testing.expect(spec.isEmpty());
    try std.testing.expectEqual(@as(?[]u8, null), spec.author);
    try std.testing.expect(!spec.eql(cloned));
}

test "FilterSpec: setAuthor OOM leaves state unchanged" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, setAuthorOomHelper, .{});
}

fn setAuthorOomHelper(a: std.mem.Allocator) !void {
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.setAuthor(a, "initial");
    try spec.setAuthor(a, "replacement");
}

test "FilterSpec: empty string normalizes to null" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.setAuthor(a, "");
    try std.testing.expect(spec.isEmpty());
    try std.testing.expectEqual(@as(?[]u8, null), spec.author);
}

test "FilterSpec: max_author_runes boundary (256 ok / 257 error)" {
    const a = std.testing.allocator;
    const ok = try a.alloc(u8, max_author_runes);
    defer a.free(ok);
    @memset(ok, 'a');
    const too_long = try a.alloc(u8, max_author_runes + 1);
    defer a.free(too_long);
    @memset(too_long, 'a');

    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.setAuthor(a, ok);
    try std.testing.expect(!spec.isEmpty());

    try std.testing.expectError(error.AuthorTooLong, spec.setAuthor(a, too_long));
    try std.testing.expectEqualStrings(ok, spec.author.?);
}

test "FilterSpec: UTF-8 author preserved through clone" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.setAuthor(a, "山田太郎");
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("山田太郎", cloned.author.?);
    try std.testing.expect(spec.author.?.ptr != cloned.author.?.ptr);
}

test {
    std.testing.refAllDecls(@This());
}
