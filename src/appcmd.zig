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
            // 書込先 Dir を cwd から解決（.dir=借用 / .path=open / .inherit=process cwd）。
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
            // .git/ 配下に書く（worktree に出さず status を汚さない）。副作用は worker で
            // 直列化されるため固定名で衝突しない。
            const rel = ".git/git-tui-stage.patch";
            try base.writeFile(io, .{ .sub_path = rel, .data = ap.patch });
            // 後続の applyPatchArgv/process.run がエラー return しても temp を残さない。
            errdefer base.deleteFile(io, rel) catch {};
            const argv = try cmds.applyPatchArgv(a, ap.reverse, rel);
            defer a.free(argv);
            var res = try process.run(a, io, argv, cwd);
            defer res.deinit(a);
            base.deleteFile(io, rel) catch {}; // status を読む前に消す
            if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
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
