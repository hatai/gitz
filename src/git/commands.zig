//! git 各操作の argv 生成（純粋関数・テスト容易）と、`process.run` を呼ぶ
//! 高レベル関数。spec §3/§8 準拠。argv 生成は呼び出し側が free する。

const std = @import("std");
const process = @import("process.zig");

pub const Section = @import("status.zig").Section;
const Cwd = process.Cwd;

/// stage の argv。rename のときは新旧両パスを渡す。呼び出し側が free。
pub fn stageArgv(a: std.mem.Allocator, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "add", "--", path });
    if (orig_path) |o| try list.append(a, o);
    return list.toOwnedSlice(a);
}

/// HEAD があれば restore --staged、無ければ rm --cached。両パスを渡す。
pub fn unstageArgv(a: std.mem.Allocator, has_head: bool, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    if (has_head) {
        try list.appendSlice(a, &.{ "git", "restore", "--staged", "--", path });
    } else {
        try list.appendSlice(a, &.{ "git", "rm", "--cached", "--", path });
    }
    if (orig_path) |o| try list.append(a, o);
    return list.toOwnedSlice(a);
}

pub fn diffArgv(a: std.mem.Allocator, section: Section, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    switch (section) {
        .staged => try list.appendSlice(a, &.{ "git", "diff", "--cached", "--", path }),
        .unstaged => try list.appendSlice(a, &.{ "git", "diff", "--", path }),
        .untracked => try list.appendSlice(a, &.{ "git", "diff", "--no-index", "--", "/dev/null", path }),
    }
    if (orig_path) |o| if (section != .untracked) try list.append(a, o);
    return list.toOwnedSlice(a);
}

// --- 高レベル関数（実行系・Zig 0.16 Io API） ---

/// cwd を起点にリポジトリルートを返す。cwd を明示できるのでサブディレクトリ起動もテスト可能。
/// アプリ起動時は `.inherit`（プロセスのカレント）を渡す。呼び出し側が free。
pub fn repoRoot(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !?[]u8 {
    var res = try process.run(a, io, &.{ "git", "rev-parse", "--show-toplevel" }, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    return try a.dupe(u8, trimmed);
}

pub fn hasHead(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !bool {
    var res = try process.run(a, io, &.{ "git", "rev-parse", "--verify", "HEAD" }, cwd);
    defer res.deinit(a);
    return res.exit_code == 0;
}

/// ブランチ名（unborn HEAD でも `git symbolic-ref --short HEAD` は名前を返す）。呼び出し側が free。
pub fn branchName(a: std.mem.Allocator, io: std.Io, cwd: Cwd) ![]u8 {
    var res = try process.run(a, io, &.{ "git", "symbolic-ref", "--short", "HEAD" }, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return a.dupe(u8, "(detached)");
    return a.dupe(u8, std.mem.trimEnd(u8, res.stdout, "\n"));
}

pub fn statusRaw(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !process.RunResult {
    return process.run(a, io, &.{ "git", "status", "--porcelain=v2", "-z" }, cwd);
}

/// メッセージは `-m` で渡す（stdin パイプは 0.16 では使わない）。複数行・日本語も可。
pub fn commit(a: std.mem.Allocator, io: std.Io, cwd: Cwd, message: []const u8) !process.RunResult {
    return process.run(a, io, &.{ "git", "commit", "-m", message }, cwd);
}

// --- tests ---

test "stageArgv passes path; both paths for rename" {
    const a = std.testing.allocator;
    const argv = try stageArgv(a, "new.txt", "old.txt");
    defer a.free(argv);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("add", argv[1]);
    try std.testing.expectEqualStrings("--", argv[2]);
    try std.testing.expectEqualStrings("new.txt", argv[3]);
    try std.testing.expectEqualStrings("old.txt", argv[4]);
}

test "stageArgv without orig_path has no trailing path" {
    const a = std.testing.allocator;
    const argv = try stageArgv(a, "f.txt", null);
    defer a.free(argv);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("f.txt", argv[3]);
}

test "unstageArgv uses rm --cached when no HEAD" {
    const a = std.testing.allocator;
    const argv = try unstageArgv(a, false, "f.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("rm", argv[1]);
    try std.testing.expectEqualStrings("--cached", argv[2]);
}

test "unstageArgv uses restore --staged when HEAD exists" {
    const a = std.testing.allocator;
    const argv = try unstageArgv(a, true, "f.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("restore", argv[1]);
    try std.testing.expectEqualStrings("--staged", argv[2]);
}

test "diffArgv untracked uses --no-index against /dev/null" {
    const a = std.testing.allocator;
    const argv = try diffArgv(a, .untracked, "new.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("--no-index", argv[2]);
    try std.testing.expectEqualStrings("/dev/null", argv[4]);
}

test "diffArgv staged uses --cached" {
    const a = std.testing.allocator;
    const argv = try diffArgv(a, .staged, "f.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("diff", argv[1]);
    try std.testing.expectEqualStrings("--cached", argv[2]);
}

test "diffArgv untracked ignores orig_path" {
    const a = std.testing.allocator;
    const argv = try diffArgv(a, .untracked, "new.txt", "old.txt");
    defer a.free(argv);
    // /dev/null + new.txt のみ。orig_path は untracked では無視される。
    try std.testing.expectEqual(@as(usize, 6), argv.len);
}

// 高レベル関数（実行系）はテスト未参照だと Zig のレイジー解析でボディが
// 解析されない。refAllDecls で全 decl を参照し、process.run/Cwd/RunResult への
// 型整合をコンパイル時に検証する。
test {
    std.testing.refAllDecls(@This());
}
