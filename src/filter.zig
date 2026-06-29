//! コミットログフィルタの純粋データモデル（zigzag 非依存）。
//! phase 3b: FilterCondition union リスト（author/since/until/paths）+ date/path helpers。

const std = @import("std");

pub const max_author_runes: usize = 256;
pub const max_branch_runes: usize = 256; // ★phase 3b #1: branch/revspec
pub const max_date_runes: usize = 16;
pub const max_path_runes: usize = 1024;
pub const max_path_count: usize = 16;

pub const Error = error{ AuthorTooLong, OutOfMemory };

pub const FilterCondition = union(enum) {
    author: []u8,
    branch: []u8, // ★phase 3b #1: branch/revspec（runLogInt が snapshot_tip 解決に使用・logArgv は無視）
    since: []u8,
    until: []u8,
    paths: [][]u8,
};

pub const FilterSpec = struct {
    conditions: std.ArrayList(FilterCondition),

    pub fn init() FilterSpec {
        return .{ .conditions = .empty };
    }

    pub fn isEmpty(self: FilterSpec) bool {
        return self.conditions.items.len == 0;
    }

    /// 同 variant があれば上書き（後勝ち）・無ければ append。
    /// OOM 時 payload を自動 deinit し、呼出側は成功時のみ所有権移譲と見做す。
    pub fn addCondition(self: *FilterSpec, a: std.mem.Allocator, cond: FilterCondition) std.mem.Allocator.Error!void {
        const tag = std.meta.activeTag(cond);
        for (self.conditions.items, 0..) |*c, i| {
            if (std.meta.activeTag(c.*) == tag) {
                deinitCondition(a, c.*);
                self.conditions.items[i] = cond;
                return;
            }
        }
        self.conditions.append(a, cond) catch |err| {
            deinitCondition(a, cond);
            return err;
        };
    }

    pub fn removeVariant(self: *FilterSpec, a: std.mem.Allocator, tag: std.meta.Tag(FilterCondition)) void {
        var i: usize = 0;
        while (i < self.conditions.items.len) {
            if (std.meta.activeTag(self.conditions.items[i]) == tag) {
                deinitCondition(a, self.conditions.items[i]);
                _ = self.conditions.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn getAuthor(self: FilterSpec) ?[]const u8 {
        for (self.conditions.items) |c| switch (c) {
            .author => |t| return t,
            else => {},
        };
        return null;
    }

    pub fn getBranch(self: FilterSpec) ?[]const u8 {
        for (self.conditions.items) |c| switch (c) {
            .branch => |t| return t,
            else => {},
        };
        return null;
    }

    pub fn getSince(self: FilterSpec) ?[]const u8 {
        for (self.conditions.items) |c| switch (c) {
            .since => |t| return t,
            else => {},
        };
        return null;
    }

    pub fn getUntil(self: FilterSpec) ?[]const u8 {
        for (self.conditions.items) |c| switch (c) {
            .until => |t| return t,
            else => {},
        };
        return null;
    }

    pub fn getPaths(self: FilterSpec) []const []const u8 {
        for (self.conditions.items) |c| switch (c) {
            .paths => |list| return list,
            else => {},
        };
        return &.{};
    }

    pub fn clone(self: FilterSpec, a: std.mem.Allocator) std.mem.Allocator.Error!FilterSpec {
        var out = FilterSpec.init();
        errdefer out.deinit(a);
        for (self.conditions.items) |c| {
            const cloned = try cloneCondition(a, c);
            out.conditions.append(a, cloned) catch {
                deinitCondition(a, cloned);
                return error.OutOfMemory;
            };
        }
        return out;
    }

    pub fn eql(self: FilterSpec, other: FilterSpec) bool {
        if (self.conditions.items.len != other.conditions.items.len) return false;
        for (self.conditions.items, other.conditions.items) |a_cond, b_cond| {
            if (!conditionEql(a_cond, b_cond)) return false;
        }
        return true;
    }

    pub fn deinit(self: *FilterSpec, a: std.mem.Allocator) void {
        for (self.conditions.items) |c| deinitCondition(a, c);
        self.conditions.deinit(a);
    }
};

fn deinitCondition(a: std.mem.Allocator, cond: FilterCondition) void {
    switch (cond) {
        .author, .branch, .since, .until => |t| a.free(t),
        .paths => |list| {
            for (list) |p| a.free(p);
            a.free(list);
        },
    }
}

fn cloneCondition(a: std.mem.Allocator, cond: FilterCondition) std.mem.Allocator.Error!FilterCondition {
    return switch (cond) {
        .author => |t| .{ .author = try a.dupe(u8, t) },
        .branch => |t| .{ .branch = try a.dupe(u8, t) },
        .since => |t| .{ .since = try a.dupe(u8, t) },
        .until => |t| .{ .until = try a.dupe(u8, t) },
        .paths => |list| blk: {
            const out = try a.alloc([]u8, list.len);
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |p| a.free(p);
                a.free(out);
            }
            for (list, 0..) |p, i| {
                out[i] = try a.dupe(u8, p);
                initialized = i + 1;
            }
            break :blk .{ .paths = out };
        },
    };
}

fn conditionEql(a_cond: FilterCondition, b_cond: FilterCondition) bool {
    if (std.meta.activeTag(a_cond) != std.meta.activeTag(b_cond)) return false;
    return switch (a_cond) {
        .author => |t| std.mem.eql(u8, t, b_cond.author),
        .branch => |t| std.mem.eql(u8, t, b_cond.branch),
        .since => |t| std.mem.eql(u8, t, b_cond.since),
        .until => |t| std.mem.eql(u8, t, b_cond.until),
        .paths => |list| blk: {
            const other = b_cond.paths;
            if (list.len != other.len) break :blk false;
            for (list, other) |p, q| if (!std.mem.eql(u8, p, q)) break :blk false;
            break :blk true;
        },
    };
}

pub const DateSpec = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: ?u5,
    minute: ?u6,
};

pub const DateError = error{ InvalidDateFormat, OutOfMemory };

pub fn daysInMonth(year: u16, month: u4) u5 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

pub fn addOneDay(ds: DateSpec) DateSpec {
    var out = ds;
    const dim = daysInMonth(ds.year, ds.month);
    if (ds.day < dim) {
        out.day = ds.day + 1;
        return out;
    }
    out.day = 1;
    if (ds.month < 12) {
        out.month = ds.month + 1;
        return out;
    }
    out.month = 1;
    out.year = ds.year + 1;
    return out;
}

pub fn parseDate(input: []const u8) DateError!DateSpec {
    if (input.len == 10) {
        if (input[4] != '-' or input[7] != '-') return error.InvalidDateFormat;
        const year = std.fmt.parseInt(u16, input[0..4], 10) catch return error.InvalidDateFormat;
        const month = std.fmt.parseInt(u4, input[5..7], 10) catch return error.InvalidDateFormat;
        const day = std.fmt.parseInt(u5, input[8..10], 10) catch return error.InvalidDateFormat;
        if (month < 1 or month > 12) return error.InvalidDateFormat;
        if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDateFormat;
        return .{ .year = year, .month = month, .day = day, .hour = null, .minute = null };
    }
    if (input.len == 16) {
        if (input[4] != '-' or input[7] != '-' or input[10] != ' ' or input[13] != ':') return error.InvalidDateFormat;
        const year = std.fmt.parseInt(u16, input[0..4], 10) catch return error.InvalidDateFormat;
        const month = std.fmt.parseInt(u4, input[5..7], 10) catch return error.InvalidDateFormat;
        const day = std.fmt.parseInt(u5, input[8..10], 10) catch return error.InvalidDateFormat;
        const hour = std.fmt.parseInt(u5, input[11..13], 10) catch return error.InvalidDateFormat;
        const minute = std.fmt.parseInt(u6, input[14..16], 10) catch return error.InvalidDateFormat;
        if (month < 1 or month > 12) return error.InvalidDateFormat;
        if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDateFormat;
        if (hour > 23) return error.InvalidDateFormat;
        if (minute > 59) return error.InvalidDateFormat;
        return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute };
    }
    return error.InvalidDateFormat;
}

pub fn formatGitDate(a: std.mem.Allocator, ds: DateSpec, is_until_date_only: bool) std.mem.Allocator.Error![]u8 {
    const effective = if (is_until_date_only) addOneDay(ds) else ds;
    if (effective.hour) |h| {
        return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:00", .{
            effective.year, effective.month, effective.day, h, effective.minute.?,
        });
    }
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} 00:00:00", .{
        effective.year, effective.month, effective.day,
    });
}

pub const PathError = error{ TooManyPaths, PathTooLong, UnterminatedQuote, OutOfMemory };

pub fn parsePaths(a: std.mem.Allocator, input: []const u8) PathError![][]u8 {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |p| a.free(p);
        result.deinit(a);
    }
    var current: std.ArrayList(u8) = .empty;
    errdefer current.deinit(a);
    var in_quote = false;
    var in_escape = false;
    var has_token = false;
    for (input) |ch| {
        if (in_escape) {
            try current.append(a, ch);
            in_escape = false;
            has_token = true;
            continue;
        }
        if (ch == '\\') {
            in_escape = true;
            continue;
        }
        if (in_quote) {
            if (ch == '"') {
                in_quote = false;
                has_token = true;
                continue;
            }
            try current.append(a, ch);
            has_token = true;
            continue;
        }
        if (ch == '"') {
            in_quote = true;
            has_token = true;
            continue;
        }
        if (ch == ' ' or ch == '\t') {
            if (has_token) {
                if (current.items.len > 0) {
                    if (result.items.len >= max_path_count) return error.TooManyPaths;
                    if (current.items.len > 4096) return error.PathTooLong;
                    try result.append(a, try current.toOwnedSlice(a));
                }
                current = .empty;
                has_token = false;
            }
            continue;
        }
        try current.append(a, ch);
        has_token = true;
    }
    if (in_quote) return error.UnterminatedQuote;
    if (has_token and current.items.len > 0) {
        if (result.items.len >= max_path_count) return error.TooManyPaths;
        if (current.items.len > 4096) return error.PathTooLong;
        try result.append(a, try current.toOwnedSlice(a));
    }
    return result.toOwnedSlice(a);
}

pub fn paths_to_string(a: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error![]u8 {
    if (paths.len == 0) return a.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (paths, 0..) |p, idx| {
        if (idx > 0) try out.append(a, ' ');
        if (needsQuote(p)) try out.append(a, '"');
        for (p) |ch| {
            if (ch == '"' or ch == '\\') try out.append(a, '\\');
            try out.append(a, ch);
        }
        if (needsQuote(p)) try out.append(a, '"');
    }
    return out.toOwnedSlice(a);
}

fn needsQuote(p: []const u8) bool {
    for (p) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '"' or ch == '\\') return true;
    }
    return false;
}

test "FilterSpec: isEmpty/addCondition/removeVariant/clone/eql/deinit" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try std.testing.expect(spec.isEmpty());

    const author_dup = try a.dupe(u8, "foo");
    try spec.addCondition(a, .{ .author = author_dup });
    try std.testing.expect(!spec.isEmpty());
    try std.testing.expectEqualStrings("foo", spec.getAuthor().?);

    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("foo", cloned.getAuthor().?);
    try std.testing.expect(spec.getAuthor().?.ptr != cloned.getAuthor().?.ptr);

    spec.removeVariant(a, .author);
    try std.testing.expect(spec.isEmpty());
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getAuthor());
    try std.testing.expect(!spec.eql(cloned));
}

test "FilterSpec: addCondition OOM leaves list unchanged and frees payload (M3)" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addConditionOomHelper, .{});
}

fn addConditionOomHelper(a: std.mem.Allocator) !void {
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    const dup1 = try a.dupe(u8, "first");
    try spec.addCondition(a, .{ .author = dup1 });
    const dup2 = try a.dupe(u8, "2026-06-01");
    spec.addCondition(a, .{ .since = dup2 }) catch |err| switch (err) {
        error.OutOfMemory => return,
    };
}

test "FilterSpec: duplicate variant overwrites (codex m1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    try std.testing.expectEqual(@as(usize, 1), spec.conditions.items.len);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "bar") });
    try std.testing.expectEqual(@as(usize, 1), spec.conditions.items.len);
    try std.testing.expectEqualStrings("bar", spec.getAuthor().?);
}

test "FilterSpec: accessor 群 (getAuthor/getSince/getUntil/getPaths) borrow (m3)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getAuthor());
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getSince());
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getUntil());
    try std.testing.expectEqual(@as(usize, 0), spec.getPaths().len);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    try spec.addCondition(a, .{ .since = try a.dupe(u8, "2026-06-01") });
    try spec.addCondition(a, .{ .until = try a.dupe(u8, "2026-06-30") });
    try std.testing.expectEqualStrings("foo", spec.getAuthor().?);
    try std.testing.expectEqualStrings("2026-06-01", spec.getSince().?);
    try std.testing.expectEqualStrings("2026-06-30", spec.getUntil().?);
}

test "FilterSpec: max_author_runes constant preserved" {
    try std.testing.expectEqual(@as(usize, 256), max_author_runes);
}

test "FilterSpec: branch variant addCondition/getBranch/clone/eql/deinit (phase 3b #1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getBranch());
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try std.testing.expect(!spec.isEmpty());
    try std.testing.expectEqualStrings("dev", spec.getBranch().?);
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("dev", cloned.getBranch().?);
    try std.testing.expect(spec.getBranch().?.ptr != cloned.getBranch().?.ptr);
    spec.removeVariant(a, .branch);
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getBranch());
    try std.testing.expect(spec.isEmpty());
}

test "FilterSpec: duplicate branch overwrites (codex m1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try std.testing.expectEqual(@as(usize, 1), spec.conditions.items.len);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "main") });
    try std.testing.expectEqual(@as(usize, 1), spec.conditions.items.len);
    try std.testing.expectEqualStrings("main", spec.getBranch().?);
}

test "FilterSpec: branch + author + paths multi-variant clone no leak (phase 3b #1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    const paths = try a.alloc([]u8, 1);
    paths[0] = try a.dupe(u8, "src/");
    try spec.addCondition(a, .{ .paths = paths });
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("dev", cloned.getBranch().?);
    try std.testing.expectEqualStrings("foo", cloned.getAuthor().?);
    try std.testing.expectEqual(@as(usize, 1), cloned.getPaths().len);
}

test "FilterSpec: max_branch_runes constant preserved" {
    try std.testing.expectEqual(@as(usize, 256), max_branch_runes);
}

test "FilterSpec: addCondition branch OOM frees payload (M3, phase 3b #1)" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addConditionBranchOomHelper, .{});
}

fn addConditionBranchOomHelper(a: std.mem.Allocator) !void {
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "first") });
    const branch = try a.dupe(u8, "dev");
    spec.addCondition(a, .{ .branch = branch }) catch |err| switch (err) {
        error.OutOfMemory => return,
    };
}

test "FilterSpec: UTF-8 author preserved through clone" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "山田太郎") });
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("山田太郎", cloned.getAuthor().?);
    try std.testing.expect(spec.getAuthor().?.ptr != cloned.getAuthor().?.ptr);
}

test "FilterSpec: multi-variant (author+since+paths) clone/deinit no leak" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    try spec.addCondition(a, .{ .since = try a.dupe(u8, "2026-06-01") });
    const paths = try a.alloc([]u8, 2);
    paths[0] = try a.dupe(u8, "src/");
    paths[1] = try a.dupe(u8, "test/");
    try spec.addCondition(a, .{ .paths = paths });
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqual(@as(usize, 2), cloned.getPaths().len);
    try std.testing.expectEqualStrings("src/", cloned.getPaths()[0]);
    try std.testing.expectEqualStrings("test/", cloned.getPaths()[1]);
}

test "parseDate: YYYY-MM-DD (date only)" {
    const ds = try parseDate("2026-06-22");
    try std.testing.expectEqual(@as(u16, 2026), ds.year);
    try std.testing.expectEqual(@as(u4, 6), ds.month);
    try std.testing.expectEqual(@as(u5, 22), ds.day);
    try std.testing.expectEqual(@as(?u5, null), ds.hour);
    try std.testing.expectEqual(@as(?u6, null), ds.minute);
}

test "parseDate: YYYY-MM-DD HH:MM" {
    const ds = try parseDate("2026-06-22 09:30");
    try std.testing.expectEqual(@as(?u5, 9), ds.hour);
    try std.testing.expectEqual(@as(?u6, 30), ds.minute);
}

test "parseDate: invalid formats" {
    try std.testing.expectError(error.InvalidDateFormat, parseDate("2026-13-01"));
    try std.testing.expectError(error.InvalidDateFormat, parseDate("2026-02-30"));
    try std.testing.expectError(error.InvalidDateFormat, parseDate("2025-02-29"));
    _ = try parseDate("2024-02-29");
    try std.testing.expectError(error.InvalidDateFormat, parseDate("2026/06/22"));
    try std.testing.expectError(error.InvalidDateFormat, parseDate("2026-6-1"));
    try std.testing.expectError(error.InvalidDateFormat, parseDate(""));
    try std.testing.expectError(error.InvalidDateFormat, parseDate("2026-06-22 09"));
}

test "daysInMonth: leap year boundaries" {
    try std.testing.expectEqual(@as(u5, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u5, 28), daysInMonth(2026, 2));
    try std.testing.expectEqual(@as(u5, 31), daysInMonth(2026, 1));
    try std.testing.expectEqual(@as(u5, 30), daysInMonth(2026, 4));
}

test "addOneDay: month/year boundaries" {
    const jan31 = DateSpec{ .year = 2026, .month = 1, .day = 31, .hour = null, .minute = null };
    const feb1 = addOneDay(jan31);
    try std.testing.expectEqual(@as(u4, 2), feb1.month);
    try std.testing.expectEqual(@as(u5, 1), feb1.day);

    const feb28 = DateSpec{ .year = 2026, .month = 2, .day = 28, .hour = null, .minute = null };
    const mar1 = addOneDay(feb28);
    try std.testing.expectEqual(@as(u4, 3), mar1.month);

    const leap_feb28 = DateSpec{ .year = 2024, .month = 2, .day = 28, .hour = null, .minute = null };
    const leap_feb29 = addOneDay(leap_feb28);
    try std.testing.expectEqual(@as(u4, 2), leap_feb29.month);
    try std.testing.expectEqual(@as(u5, 29), leap_feb29.day);

    const dec31 = DateSpec{ .year = 2026, .month = 12, .day = 31, .hour = null, .minute = null };
    const next_jan1 = addOneDay(dec31);
    try std.testing.expectEqual(@as(u16, 2027), next_jan1.year);
    try std.testing.expectEqual(@as(u4, 1), next_jan1.month);
}

test "formatGitDate: since date-only 00:00:00" {
    const a = std.testing.allocator;
    const ds = DateSpec{ .year = 2026, .month = 6, .day = 22, .hour = null, .minute = null };
    const out = try formatGitDate(a, ds, false);
    defer a.free(out);
    try std.testing.expectEqualStrings("2026-06-22 00:00:00", out);
}

test "formatGitDate: since HH:MM" {
    const a = std.testing.allocator;
    const ds = DateSpec{ .year = 2026, .month = 6, .day = 22, .hour = 9, .minute = 30 };
    const out = try formatGitDate(a, ds, false);
    defer a.free(out);
    try std.testing.expectEqualStrings("2026-06-22 09:30:00", out);
}

test "formatGitDate: until date-only +1day" {
    const a = std.testing.allocator;
    const ds = DateSpec{ .year = 2026, .month = 6, .day = 22, .hour = null, .minute = null };
    const out = try formatGitDate(a, ds, true);
    defer a.free(out);
    try std.testing.expectEqualStrings("2026-06-23 00:00:00", out);
}

test "formatGitDate: until HH:MM unchanged" {
    const a = std.testing.allocator;
    const ds = DateSpec{ .year = 2026, .month = 6, .day = 22, .hour = 12, .minute = 0 };
    const out = try formatGitDate(a, ds, false);
    defer a.free(out);
    try std.testing.expectEqualStrings("2026-06-22 12:00:00", out);
}

test "parsePaths: single path" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "src/");
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("src/", paths[0]);
}

test "parsePaths: multiple paths" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "src/ test/");
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("src/", paths[0]);
    try std.testing.expectEqualStrings("test/", paths[1]);
}

test "parsePaths: quoted path with space" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "\"my dir/file\"");
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("my dir/file", paths[0]);
}

test "parsePaths: escape backslash-space" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "src/\\ *.zig");
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("src/ *.zig", paths[0]);
}

test "parsePaths: consecutive whitespace skipped" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "a   b");
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("a", paths[0]);
    try std.testing.expectEqualStrings("b", paths[1]);
}

test "parsePaths: empty input" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "");
    defer a.free(paths);
    try std.testing.expectEqual(@as(usize, 0), paths.len);
}

test "parsePaths: too many paths" {
    const a = std.testing.allocator;
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        if (i > 0) {
            buf[len] = ' ';
            len += 1;
        }
        buf[len] = 'p';
        len += 1;
    }
    try std.testing.expectError(error.TooManyPaths, parsePaths(a, buf[0..len]));
}

test "parsePaths: path too long" {
    const a = std.testing.allocator;
    const long = try a.alloc(u8, 4097);
    defer a.free(long);
    @memset(long, 'x');
    try std.testing.expectError(error.PathTooLong, parsePaths(a, long));
}

test "parsePaths: unterminated quote" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedQuote, parsePaths(a, "\"my dir"));
}

test "paths_to_string: single" {
    const a = std.testing.allocator;
    const paths = [_][]const u8{"src/"};
    const out = try paths_to_string(a, &paths);
    defer a.free(out);
    try std.testing.expectEqualStrings("src/", out);
}

test "paths_to_string: multiple" {
    const a = std.testing.allocator;
    const paths = [_][]const u8{ "src/", "test/" };
    const out = try paths_to_string(a, &paths);
    defer a.free(out);
    try std.testing.expectEqualStrings("src/ test/", out);
}

test "paths_to_string: quotes path with space" {
    const a = std.testing.allocator;
    const paths = [_][]const u8{"my dir/file"};
    const out = try paths_to_string(a, &paths);
    defer a.free(out);
    try std.testing.expectEqualStrings("\"my dir/file\"", out);
}

test "paths_to_string: escapes quote/backslash" {
    const a = std.testing.allocator;
    const paths = [_][]const u8{"a\"b"};
    const out = try paths_to_string(a, &paths);
    defer a.free(out);
    try std.testing.expectEqualStrings("\"a\\\"b\"", out);
}

test "paths_to_string: empty list" {
    const a = std.testing.allocator;
    const out = try paths_to_string(a, &.{});
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "paths_to_string ∘ parsePaths roundtrip symmetric" {
    const a = std.testing.allocator;
    const inputs = [_][]const u8{
        "src/",
        "src/ test/",
        "\"my dir/file\"",
        "\"a\\\"b\"",
    };
    for (inputs) |input| {
        const paths = try parsePaths(a, input);
        defer {
            for (paths) |p| a.free(p);
            a.free(paths);
        }
        const out = try paths_to_string(a, paths);
        defer a.free(out);
        try std.testing.expectEqualStrings(input, out);
    }
}

test "parsePaths: empty quote skipped (M4)" {
    const a = std.testing.allocator;
    const paths = try parsePaths(a, "\"\" src/");
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("src/", paths[0]);
}

test "FilterSpec.clone OOM no payload leak (M5/B2)" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneOomHelper, .{});
}

fn cloneOomHelper(a: std.mem.Allocator) !void {
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    const paths = blk: {
        const ps = try a.alloc([]u8, 1);
        errdefer a.free(ps);
        ps[0] = try a.dupe(u8, "src/");
        break :blk ps;
    };
    try spec.addCondition(a, .{ .paths = paths });
    var cloned = try spec.clone(a);
    cloned.deinit(a);
}

test {
    std.testing.refAllDecls(@This());
}
