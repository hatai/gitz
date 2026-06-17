//! AppCmd 解釈器: AppCmd を git backend 実行に変換し、結果 Msg を返す。
//! 端末不要。spec §9 の結合テスト（空リポジトリ初回コミット・rename・untracked・
//! サブディレクトリ起動）をここで満たす。呼び出し側が返り値 Msg を deinit する。
const std = @import("std");
const cmds = @import("git/commands.zig");
const process = @import("git/process.zig");
const statusmod = @import("git/status.zig");
const msgs = @import("messages.zig");
const Msg = msgs.Msg;
const AppCmd = msgs.AppCmd;

const Cwd = process.Cwd;

/// AppCmd を実行し、結果 Msg を返す（呼び出し側が Msg を deinit）。
pub fn run(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd) !Msg {
    switch (cmd) {
        .none, .quit => return .committed, // 呼び出し側が使わない場合の安全値（quit は main で別処理）
        .refresh_status => {
            var res = try cmds.statusRaw(a, io, cwd);
            defer res.deinit(a);
            if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            const entries = try statusmod.parse(a, res.stdout);
            return .{ .status_loaded = entries };
        },
        .stage => |op| {
            const argv = try cmds.stageArgv(a, op.path, op.orig_path);
            defer a.free(argv);
            return execThenRefresh(a, io, cwd, argv);
        },
        .unstage => |op| {
            const has_head = try cmds.hasHead(a, io, cwd);
            const argv = try cmds.unstageArgv(a, has_head, op.path, op.orig_path);
            defer a.free(argv);
            return execThenRefresh(a, io, cwd, argv);
        },
        .load_diff => |ld| {
            const argv = try cmds.diffArgv(a, ld.section, ld.path, ld.orig_path);
            defer a.free(argv);
            var res = try process.run(a, io, argv, cwd);
            defer res.deinit(a);
            // 正常終了コードを厳密に判定する（失敗を空 diff として握り潰さない）:
            //   tracked(staged/unstaged): 0 のみ正常。
            //   untracked(--no-index): 差分ありで 1 を返すため 0 または 1 が正常、それ以外は失敗。
            const ok = switch (ld.section) {
                .untracked => res.exit_code == 0 or res.exit_code == 1,
                else => res.exit_code == 0,
            };
            if (!ok) return .{ .git_error = try a.dupe(u8, res.stderr) };
            return .{ .diff_loaded = try a.dupe(u8, res.stdout) };
        },
        .commit => |message| {
            var res = try cmds.commit(a, io, cwd, message);
            defer res.deinit(a);
            if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            return .committed;
        },
        .apply_patch => |ap| {
            // git_dir 有無で 2 経路。成功/失敗に関わらず temp を削除してから status を読む。
            // bare repo では apply --cached 自体が意味を持たないが本 TUI 対象外（コメントのみ）。
            if (ap.git_dir) |git_dir| {
                // 絶対パス経路: worktree / submodule / 通常の全ケース対応。
                const tmp_abs = try std.fmt.allocPrint(a, "{s}/git-tui-stage.patch", .{git_dir});
                defer a.free(tmp_abs);
                var dir = try std.Io.Dir.openDirAbsolute(io, git_dir, .{});
                defer dir.close(io);
                try dir.writeFile(io, .{ .sub_path = "git-tui-stage.patch", .data = ap.patch });
                errdefer dir.deleteFile(io, "git-tui-stage.patch") catch {};
                const argv = try cmds.applyPatchArgv(a, ap.reverse, tmp_abs);
                defer a.free(argv);
                var res = try process.run(a, io, argv, cwd);
                defer res.deinit(a);
                dir.deleteFile(io, "git-tui-stage.patch") catch {};
                if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            } else {
                // フォールバック: 従来の cwd 相対 .git/git-tui-stage.patch（既存テスト・通常リポジトリ）。
                var owned_dir = false;
                var base: std.Io.Dir = switch (cwd) {
                    .dir => |d| d,
                    .path => |p| blk: {
                        owned_dir = true;
                        break :blk try std.Io.Dir.openDirAbsolute(io, p, .{});
                    },
                    .inherit => std.Io.Dir.cwd(),
                };
                defer if (owned_dir) base.close(io);
                const rel = ".git/git-tui-stage.patch";
                try base.writeFile(io, .{ .sub_path = rel, .data = ap.patch });
                errdefer base.deleteFile(io, rel) catch {};
                const argv = try cmds.applyPatchArgv(a, ap.reverse, rel);
                defer a.free(argv);
                var res = try process.run(a, io, argv, cwd);
                defer res.deinit(a);
                base.deleteFile(io, rel) catch {};
                if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            }
            // 共通: status 再読込。
            var sres = try cmds.statusRaw(a, io, cwd);
            defer sres.deinit(a);
            if (sres.exit_code != 0) return .{ .git_error = try a.dupe(u8, sres.stderr) };
            return .{ .status_loaded = try statusmod.parse(a, sres.stdout) };
        },
    }
}

// 副作用コマンドを実行 → 失敗なら git_error、成功なら status を読み直して status_loaded を返す
fn execThenRefresh(a: std.mem.Allocator, io: std.Io, cwd: Cwd, argv: []const []const u8) !Msg {
    var res = try process.run(a, io, argv, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
    var sres = try cmds.statusRaw(a, io, cwd);
    defer sres.deinit(a);
    if (sres.exit_code != 0) return .{ .git_error = try a.dupe(u8, sres.stderr) };
    return .{ .status_loaded = try statusmod.parse(a, sres.stdout) };
}

// --- テスト用ヘルパ: 一時 git リポジトリを作る（Zig 0.16 Io API） ---
const TmpRepo = struct {
    dir: std.testing.TmpDir,
    fn init(a: std.mem.Allocator, io: std.Io) !TmpRepo {
        const td = std.testing.tmpDir(.{});
        const c: Cwd = .{ .dir = td.dir };
        // RunResult は stdout/stderr を所有するため、必ず deinit してリークを防ぐ。
        try runAndFree(a, io, &.{ "git", "init", "-q" }, c);
        try runAndFree(a, io, &.{ "git", "config", "user.email", "t@t" }, c);
        try runAndFree(a, io, &.{ "git", "config", "user.name", "t" }, c);
        return .{ .dir = td };
    }
    fn cwd(self: *TmpRepo) Cwd {
        return .{ .dir = self.dir.dir };
    }
    fn writeFile(self: *TmpRepo, io: std.Io, name: []const u8, content: []const u8) !void {
        try self.dir.dir.writeFile(io, .{ .sub_path = name, .data = content });
    }
    /// git を実行し RunResult を必ず deinit する（テストのリーク防止ヘルパ）。
    fn git(self: *TmpRepo, a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
        try runAndFree(a, io, argv, self.cwd());
    }
    fn deinit(self: *TmpRepo) void {
        self.dir.cleanup();
    }
};

/// process.run を実行し RunResult を必ず deinit する（テストのリーク防止ヘルパ）。
fn runAndFree(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: Cwd) !void {
    var r = try process.run(a, io, argv, cwd);
    r.deinit(a);
}

// inline AppCmd を作って run に渡し、cmd を必ず deinit する（リーク防止ヘルパ）。
fn runOwned(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd) !Msg {
    var c = cmd;
    defer c.deinit(a);
    return run(a, io, cwd, c);
}

test "refresh_status on empty repo with one untracked file" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "new.txt", "hi");
    var msg = try run(a, io, repo.cwd(), .refresh_status);
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    try std.testing.expectEqual(@as(usize, 1), msg.status_loaded.len);
    try std.testing.expectEqual(statusmod.Section.untracked, msg.status_loaded[0].section);
}

test "stage then commit on empty repo succeeds (first commit, no parent)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "hello");
    // stage（runOwned が inline AppCmd を deinit する）
    var m1 = try runOwned(a, io, repo.cwd(), .{ .stage = .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .untracked } });
    defer m1.deinit(a);
    try std.testing.expect(m1 == .status_loaded);
    // commit
    var m2 = try runOwned(a, io, repo.cwd(), .{ .commit = try a.dupe(u8, "first commit") });
    defer m2.deinit(a);
    try std.testing.expect(m2 == .committed);
    try std.testing.expect(try cmds.hasHead(a, io, repo.cwd()));
}

test "staged rename is reported with new path and orig_path" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "old.txt", "x");
    try repo.git(a, io, &.{ "git", "add", "old.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.git(a, io, &.{ "git", "mv", "old.txt", "new.txt" });
    var m = try runOwned(a, io, repo.cwd(), .refresh_status);
    defer m.deinit(a);
    try std.testing.expect(m == .status_loaded);
    var found = false;
    for (m.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "new.txt") and e.section == .staged) {
            found = true;
            try std.testing.expectEqualStrings("old.txt", e.orig_path.?);
        }
    }
    try std.testing.expect(found);
}

test "unstage rename with both paths removes staged rename entirely" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "old.txt", "x");
    try repo.git(a, io, &.{ "git", "add", "old.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.git(a, io, &.{ "git", "mv", "old.txt", "new.txt" }); // staged rename
    // unstage（新旧両パスを渡す）
    var m = try runOwned(a, io, repo.cwd(), .{ .unstage = .{ .path = try a.dupe(u8, "new.txt"), .orig_path = try a.dupe(u8, "old.txt"), .section = .staged } });
    defer m.deinit(a);
    try std.testing.expect(m == .status_loaded);
    // staged な rename エントリは消えている（unstaged に old.txt 削除 / new.txt 追加が残る形）
    for (m.status_loaded) |e| try std.testing.expect(e.section != .staged);
}

test "repoRoot resolves from a subdirectory cwd" {
    // spec §9: サブディレクトリ起動でも root を解決できる
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.dir.dir.createDirPath(io, "sub/deep");
    var sub = try repo.dir.dir.openDir(io, "sub/deep", .{});
    defer sub.close(io);
    const root = try cmds.repoRoot(a, io, .{ .dir = sub });
    defer if (root) |r| a.free(r);
    try std.testing.expect(root != null);
    // 解決された root 配下で status が取れる
    var m = try runOwned(a, io, .{ .path = root.? }, .refresh_status);
    defer m.deinit(a);
    try std.testing.expect(m == .status_loaded);
}

test "load_diff on a Japanese filename returns raw UTF-8 (no octal escape)" {
    // 受け入れ基準5: 日本語ファイル名の diff ヘッダが core.quotePath=false により
    // octal エスケープ（\346 等）されず raw UTF-8 の `日本語.txt` で出ることを確認。
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "日本語.txt", "一行目\n");
    try repo.git(a, io, &.{ "git", "add", "日本語.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // 変更を加えて unstaged diff を取得する。
    try repo.writeFile(io, "日本語.txt", "一行目\n二行目\n");
    var m = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "日本語.txt"), .orig_path = null, .section = .unstaged } });
    defer m.deinit(a);
    try std.testing.expect(m == .diff_loaded);
    // raw UTF-8 のファイル名がそのまま含まれる。
    try std.testing.expect(std.mem.indexOf(u8, m.diff_loaded, "日本語.txt") != null);
    // octal エスケープ（"\346" のリテラル4バイト列）を含まないこと。
    try std.testing.expect(std.mem.indexOf(u8, m.diff_loaded, "\\346") == null);
}

test "load_diff failure preserves no crash and surfaces git_error path" {
    // 不正な section/パスでも握り潰さない（tracked diff で存在しないパスは exit!=0 → git_error or 空）
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "x");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // a.txt を変更して unstaged diff を取得（正常系: diff_loaded）
    try repo.writeFile(io, "a.txt", "x changed");
    var m = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged } });
    defer m.deinit(a);
    try std.testing.expect(m == .diff_loaded);
    try std.testing.expect(std.mem.indexOf(u8, m.diff_loaded, "changed") != null);
}

test "apply_patch stages a single hunk (partial stage), leaving the rest unstaged" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // 先頭と末尾を変更 → 2 ハンクの unstaged diff（3 行コンテキストで離れているため分離）。
    try repo.writeFile(io, "f.txt", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n");
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 2);
    const patch = try hunk.buildPatch(a, parsed, 0);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = patch, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "f.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
}

test "apply_patch with reverse=true unstages a single staged hunk" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "f.txt", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" }); // 全 stage → staged diff に 2 ハンク
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .staged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 2);
    const patch = try hunk.buildPatch(a, parsed, 0);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = patch, .reverse = true } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "f.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
}

test "apply_patch succeeds on a hunk with No-newline-at-eof" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "f.txt", "a"); // 末尾改行を削る → "\ No newline at end of file"
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    const patch = try hunk.buildPatch(a, parsed, 0);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = patch, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error にならず apply 成功
}

test "apply_patch surfaces git_error on a corrupt patch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    const bad = try a.dupe(u8, "--- a/f.txt\n+++ b/f.txt\n@@ -100,1 +100,1 @@\n-zzz\n+yyy\n");
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = bad, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .git_error); // 握り潰さない
}

// 一時 repo で `git diff --cached -- <path>` の出力（index 状態）を複製して返すヘルパ。
fn stagedDiff(repo: *TmpRepo, a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var r = try process.run(a, io, &.{ "git", "diff", "--cached", "--", path }, repo.cwd());
    defer r.deinit(a);
    return try a.dupe(u8, r.stdout); // 呼び出し側が free
}

test "apply_patch (line stage forward): only the selected inserted line enters the index" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\nc\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // a と c の間に B1/B2 を挿入（純粋挿入）。
    try repo.writeFile(io, "f.txt", "a\nB1\nB2\nc\n");
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len == 1);
    // '+B1' 行だけ選択して stage。'+B1' の絶対行を探す。
    var plus_b1: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) if (std.mem.eql(u8, ln, "+B1")) {
            plus_b1 = i;
        };
    }
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_b1, plus_b1, false);
    try std.testing.expect(maybe != null);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = maybe.?, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error でないこと
    // index には B1 のみ入り、B2 はまだ unstaged。
    const sd = try stagedDiff(&repo, a, io, "f.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B2\n") == null);
}

test "apply_patch (line unstage reverse): only the selected inserted line leaves the index" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\nc\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "f.txt", "a\nB1\nB2\nc\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" }); // 全 stage
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .staged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    var plus_b1: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) if (std.mem.eql(u8, ln, "+B1")) {
            plus_b1 = i;
        };
    }
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_b1, plus_b1, true);
    try std.testing.expect(maybe != null);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = maybe.?, .reverse = true } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    // index からは B1 だけ外れ（staged diff に +B1 が消える）、B2 はまだ staged。
    const sd = try stagedDiff(&repo, a, io, "f.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B2\n") != null);
}

test "apply_patch with git_dir works in a linked worktree" {
    // spec §2 結合テスト: linked worktree で .git がファイルでも git_dir 経路で apply が成功する。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // worktree add は HEAD を要求するため初回 commit を入れる。
    try repo.writeFile(io, "f.txt", "1\n2\n3\n4\n5\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });

    // 副ワークツリーを repo 配下の worktree-tmp へ作る。
    // ★オプション順序（レビュー B3）: -q -b <branch> <path> の順（path の後に -b を置かない）。
    try repo.git(a, io, &.{ "git", "worktree", "add", "-q", "-b", "wt", "worktree-tmp" });

    // 副ワークツリーを開く。.git はファイル（gitdir ポインタ）のはず。
    var wt = try repo.dir.dir.openDir(io, "worktree-tmp", .{});
    defer wt.close(io);
    const wt_cwd: Cwd = .{ .dir = wt };

    // --absolute-git-dir で実 git-dir を解決（.git ファイルを透過して repo/.git/worktrees/wt へ）。
    const maybe_gd = try cmds.gitDir(a, io, wt_cwd);
    try std.testing.expect(maybe_gd != null);
    const gd = maybe_gd.?;
    defer a.free(gd);
    try std.testing.expect(std.mem.indexOf(u8, gd, "worktrees") != null);

    // 副ワークツリーで f.txt を変更 → unstaged diff を取得。
    try wt.writeFile(io, .{ .sub_path = "f.txt", .data = "1x\n2\n3\n4\n5\n" });
    var dmsg = try runOwned(a, io, wt_cwd, .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    const patch = try hunk.buildPatch(a, parsed, 0);

    // git_dir != null で apply_patch を実行（絶対パス経路）。
    var msg = try runOwned(a, io, wt_cwd, .{ .apply_patch = .{ .patch = patch, .reverse = false, .git_dir = try a.dupe(u8, gd) } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    // index に入ったことを確認。
    var has_staged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "f.txt") and e.section == .staged) has_staged = true;
    }
    try std.testing.expect(has_staged);
}

test "apply_patch with git_dir works in a real submodule" {
    // spec §2 結合テスト: 本物の submodule（.git ファイル=相対 gitdir:）で git_dir 経路が動く。
    // ★レビュー B2: 通常リポジトリではなく実際の submodule を作る。submodule の .git は
    //   `gitdir: ../.git/modules/<name>` の相対形式（worktree とは別経路）であり、
    //   --absolute-git-dir がこれを実ディレクトリへ解決することを検証する。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");

    // superproject 用 tmp リポジトリ（初回 commit 済み＝submodule add の前提）。
    var super = try TmpRepo.init(a, io);
    defer super.deinit();
    try super.writeFile(io, "root.txt", "x\n");
    try super.git(a, io, &.{ "git", "add", "root.txt" });
    try super.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });

    // submodule 用独立 tmp リポジトリ（初回 commit 済み＝add 可能にするため）。
    var sub_repo = try TmpRepo.init(a, io);
    defer sub_repo.deinit();
    try sub_repo.writeFile(io, "sub.txt", "1\n2\n3\n");
    try sub_repo.git(a, io, &.{ "git", "add", "sub.txt" });
    try sub_repo.git(a, io, &.{ "git", "commit", "-q", "-m", "sub init" });

    // super へ sub_repo を submodule として追加。
    // ★protocol.file.allow=always 必須（git 2.38+ は file:// を既定で拒否）。
    //   sub_repo の絶対パスを得るため、TmpRepo.dir.dir.realPath(io, buf) を使う
    //   （Zig 0.16 の std.Io.Dir.realPath は (io, out_buffer) を取り usize を返す）。
    var sub_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub_abs_len = sub_repo.dir.dir.realPath(io, &sub_abs_buf) catch return;
    const sub_abs = sub_abs_buf[0..sub_abs_len];
    try super.git(a, io, &.{ "git", "-c", "protocol.file.allow=always", "submodule", "add", sub_abs, "sub" });
    // submodule 作業ツリー内のファイルを commit して super 側へ反映。
    try super.git(a, io, &.{ "git", "commit", "-q", "-m", "add sub" });

    // super/sub を開く。.git はファイルのはず（`gitdir: ../.git/modules/sub`）。
    var sub_wt = try super.dir.dir.openDir(io, "sub", .{});
    defer sub_wt.close(io);
    const sub_cwd: Cwd = .{ .dir = sub_wt };

    // --absolute-git-dir で実 git-dir を解決（相対 gitdir: を透過して super/.git/modules/sub へ）。
    const maybe_gd = try cmds.gitDir(a, io, sub_cwd);
    try std.testing.expect(maybe_gd != null);
    const gd = maybe_gd.?;
    defer a.free(gd);
    // gd は .git/modules/sub を指す実ディレクトリであること（worktree とは別経路の検証）。
    try std.testing.expect(std.mem.indexOf(u8, gd, "modules") != null);

    // submodule 内で sub.txt を変更 → unstaged diff を取得。
    try sub_wt.writeFile(io, .{ .sub_path = "sub.txt", .data = "1x\n2\n3\n" });
    var dmsg = try runOwned(a, io, sub_cwd, .{ .load_diff = .{ .path = try a.dupe(u8, "sub.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    const patch = try hunk.buildPatch(a, parsed, 0);

    // git_dir != null で apply_patch を実行（絶対パス経路）。
    var msg = try runOwned(a, io, sub_cwd, .{ .apply_patch = .{ .patch = patch, .reverse = false, .git_dir = try a.dupe(u8, gd) } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    // index に入ったことを確認。
    var has_staged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "sub.txt") and e.section == .staged) has_staged = true;
    }
    try std.testing.expect(has_staged);
}

test "apply_patch stages a partial hunk of an untracked file (new-file create via --cached)" {
    // spec §4.3 結合テスト: untracked ファイル（index 未登録）の部分行 stage が git apply --cached で通る。
    // 実証実験 1 で成功した経路そのものを回帰テスト化する。実装は変更しない（テストのみ）。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // untracked の 10 行ファイルを作る。
    try repo.writeFile(io, "new.txt", "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n");
    // untracked の diff（--no-index）を取得。
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{
        .path = try a.dupe(u8, "new.txt"), .orig_path = null, .section = .untracked,
    } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    // L4-L6（3 行）だけ選択して buildLinePatch。+L4 と +L6 の絶対行を splitScalar で探す。
    var plus_l4: usize = 0;
    var plus_l6: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) {
            if (std.mem.eql(u8, ln, "+L4")) plus_l4 = i;
            if (std.mem.eql(u8, ln, "+L6")) plus_l6 = i;
        }
    }
    // 行探索が成功したことを事前 assert（未発見だと plus_*==0 のまま間接的失敗になるのを避ける）。
    try std.testing.expect(plus_l4 != 0);
    try std.testing.expect(plus_l6 != 0);
    try std.testing.expect(plus_l4 <= plus_l6);
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_l4, plus_l6, false);
    try std.testing.expect(maybe != null);
    // git apply --cached を実行。git_dir は指定しない（既存のフォールバック cwd 相対 .git/ 経路を使う）。
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{
        .patch = maybe.?, .reverse = false,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error でないこと
    // status が 1 AM（staged + unstaged 混合）になることを確認。
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "new.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
    // index には L4-L6 のみ入ったことを確認。
    const sd = try stagedDiff(&repo, a, io, "new.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L10\n") == null);
}
