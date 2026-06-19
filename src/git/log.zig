//! git log 出力の NUL 区切りパーサ（zigzag 非依存）。
//! `--pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d -z --decorate=short --no-color`
//! 出力をパースし、Commit スライスを返す。

const std = @import("std");

pub const Commit = struct {
    hash: []u8,
    parents: [][]u8,
    author: []u8,
    epoch_sec: i64,
    subject: []u8,
    refs: []u8,
    pub fn deinit(self: *Commit, a: std.mem.Allocator) void {
        a.free(self.hash);
        for (self.parents) |p| a.free(p);
        a.free(self.parents);
        a.free(self.author);
        a.free(self.subject);
        a.free(self.refs);
    }
};

pub const ParseError = error{ InvalidFormat, OutOfMemory };

/// 呼び出し側が返り値スライスと各要素を deinit する（status.parse と同じ契約）。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError![]Commit {
    var list: std.ArrayList(Commit) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit(a);
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, raw, 0);
    while (true) {
        const hash = it.next() orelse break;
        if (hash.len == 0) break;
        // R15: partial final group (fewer than 6 tokens) is silently dropped, not an error.
        const p_str = it.next() orelse break;
        const an = it.next() orelse break;
        const at = it.next() orelse break;
        const s = it.next() orelse break;
        const d = it.next() orelse break;

        // 各フィールドをループ本体スコープで dup し、errdefer を伝播させる。
        // blk: { ... break :blk x; } の中に errdefer を置くと break で打ち消されて
        // 後続割り当て失敗時に解放されずリークするため、status.zig と同じく
        // フィールドごとに直接 errdefer を登録する。
        const epoch_sec = std.fmt.parseInt(i64, at, 10) catch return error.InvalidFormat;

        const h = try a.dupe(u8, hash);
        errdefer a.free(h);

        var parents: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parents.items) |p| a.free(p);
            parents.deinit(a);
        }
        {
            var pit = std.mem.splitScalar(u8, p_str, ' ');
            while (pit.next()) |ph| {
                if (ph.len == 0) continue;
                const ph_dup = try a.dupe(u8, ph);
                errdefer a.free(ph_dup);
                try parents.append(a, ph_dup);
            }
        }
        const parents_slice = try parents.toOwnedSlice(a);
        // toOwnedSlice 後は parents ArrayList は空になり元の errdefer は無害化するので、
        // 新たに parents_slice の解放を登録する（二重解放にはならない）。
        errdefer {
            for (parents_slice) |p| a.free(p);
            a.free(parents_slice);
        }

        const author = try a.dupe(u8, an);
        errdefer a.free(author);

        const subject = try a.dupe(u8, s);
        errdefer a.free(subject);

        const refs = try a.dupe(u8, d);
        errdefer a.free(refs);

        try list.append(a, .{
            .hash = h,
            .parents = parents_slice,
            .author = author,
            .epoch_sec = epoch_sec,
            .subject = subject,
            .refs = refs,
        });
    }
    return list.toOwnedSlice(a);
}

test "parse: single commit with 6 NUL-separated fields" {
    const a = std.testing.allocator;
    const raw = "abc123\x00parent1\x00山田太郎\x001700000000\x00日本語件名\x00 (HEAD -> main)\x00";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqualStrings("abc123", commits[0].hash);
    try std.testing.expectEqual(@as(usize, 1), commits[0].parents.len);
    try std.testing.expectEqualStrings("parent1", commits[0].parents[0]);
    try std.testing.expectEqualStrings("山田太郎", commits[0].author);
    try std.testing.expectEqual(@as(i64, 1700000000), commits[0].epoch_sec);
    try std.testing.expectEqualStrings("日本語件名", commits[0].subject);
    try std.testing.expectEqualStrings(" (HEAD -> main)", commits[0].refs);
}

test "parse: root commit (empty P, parents.len == 0)" {
    const a = std.testing.allocator;
    const raw = "root123\x00\x00author\x001700000000\x00subj\x00\x00";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqual(@as(usize, 0), commits[0].parents.len);
    try std.testing.expectEqualStrings("", commits[0].refs);
}

test "parse: merge commit (P has 2 hashes space-separated)" {
    const a = std.testing.allocator;
    const raw = "merge1\x00p1 p2\x00author\x001700000000\x00merge subj\x00\x00";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqual(@as(usize, 2), commits[0].parents.len);
    try std.testing.expectEqualStrings("p1", commits[0].parents[0]);
    try std.testing.expectEqualStrings("p2", commits[0].parents[1]);
}

test "parse: multiple commits (3 commits)" {
    const a = std.testing.allocator;
    const raw = "h1\x00p1\x00a1\x001\x00s1\x00\x00h2\x00p2\x00a2\x002\x00s2\x00\x00h3\x00p3\x00a3\x003\x00s3\x00\x00";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 3), commits.len);
    try std.testing.expectEqualStrings("h1", commits[0].hash);
    try std.testing.expectEqualStrings("h3", commits[2].hash);
}

test "parse: trailing NUL absent (last commit ends right after %d)" {
    const a = std.testing.allocator;
    const raw = "h1\x00p1\x00a1\x001\x00s1\x00 (HEAD -> main)";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqualStrings(" (HEAD -> main)", commits[0].refs);
}

test "parse: empty raw returns empty slice" {
    const a = std.testing.allocator;
    const commits = try parse(a, "");
    defer a.free(commits);
    try std.testing.expectEqual(@as(usize, 0), commits.len);
}

test "parse: non-numeric epoch returns InvalidFormat" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidFormat, parse(a, "h\x00p\x00a\x00NaN\x00s\x00\x00"));
}

test "parse: no invalid free / leak when allocation fails" {
    const raw = "h1\x00p1 p2\x00a1\x001\x00s1\x00\x00h2\x00p3\x00a2\x002\x00s2\x00\x00";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndFree, .{raw});
}

fn parseAndFree(a: std.mem.Allocator, raw: []const u8) !void {
    const commits = try parse(a, raw);
    for (commits) |*c| c.deinit(a);
    a.free(commits);
}

test {
    std.testing.refAllDecls(@This());
}
