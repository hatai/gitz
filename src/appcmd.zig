//! AppCmd 解釈器: AppCmd を git backend 実行に変換し、結果 Msg を返す。
//! 端末不要。spec §9 の結合テスト（空リポジトリ初回コミット・rename・untracked・
//! サブディレクトリ起動）をここで満たす。呼び出し側が返り値 Msg を deinit する。
const std = @import("std");
const cmds = @import("git/commands.zig");
const process = @import("git/process.zig");
const statusmod = @import("git/status.zig");
const log = @import("git/log.zig");
const show = @import("git/show.zig");
const msgs = @import("messages.zig");
const Msg = msgs.Msg;
const AppCmd = msgs.AppCmd;
const FilterSpec = msgs.FilterSpec;

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
        // --- TODO 2 phase 1: log/detail 副作用コマンド ---
        // load_log は headState tri-state を取る（unborn/err 対応）。load_log_page は tip 固定で
        // bad revision 検出を行うため runLogPageInt へ分離（H-06/H-07/M-12）。
        .load_log => |c| return runLogInt(a, io, cwd, c),
        .load_log_page => |c| return runLogPageInt(a, io, cwd, c),
        .load_commit_detail => |hash_req| {
            const argv = try cmds.showNameStatusArgv(a, hash_req);
            defer a.free(argv);
            var res = process.run(a, io, argv, cwd) catch
                return .{ .git_error = try a.dupe(u8, "git show 実行エラー") };
            defer res.deinit(a);
            if (res.exit_code != 0) {
                // detail は reducer で stale reject されるので git_error で安全。
                const text = a.dupe(u8, res.stderr) catch return .{ .git_error = try a.dupe(u8, "git show 失敗") };
                return .{ .git_error = text };
            }
            // R26: entries は parse が所有確保済み。hash を dupe。順序厳守。
            const entries = try show.parseNameStatus(a, res.stdout);
            errdefer {
                for (entries) |*e| e.deinit(a);
                a.free(entries);
            }
            const hash = try a.dupe(u8, hash_req);
            errdefer a.free(hash);
            return .{ .commit_detail_loaded = .{ .request_hash = hash, .entries = entries } };
        },
        .load_detail_diff => |ldd| {
            const argv = try cmds.showFileDiffArgv(a, ldd.hash, ldd.path);
            defer a.free(argv);
            var res = process.run(a, io, argv, cwd) catch
                return .{ .git_error = try a.dupe(u8, "git show 実行エラー") };
            defer res.deinit(a);
            if (res.exit_code != 0) {
                const text = a.dupe(u8, res.stderr) catch return .{ .git_error = try a.dupe(u8, "git show 失敗") };
                return .{ .git_error = text };
            }
            // R26: text/hash/path の 3 つを所有。順序: text → hash → path。
            const text = try a.dupe(u8, res.stdout);
            errdefer a.free(text);
            const hash = try a.dupe(u8, ldd.hash);
            errdefer a.free(hash);
            const path = try a.dupe(u8, ldd.path);
            errdefer a.free(path);
            return .{ .detail_diff_loaded = .{ .request_hash = hash, .request_path = path, .text = text } };
        },
    }
}

/// Run git log for load_log (initial page, skip=0) and return log_loaded Msg.
/// phase 3a §6.1: headState tri-state → rev-parse HEAD（snapshot_tip）→ logArgv with filter。
/// 全エラー経路を LogLoadFailed / LogLoadFailedSilent へ正規化（B4/M3/MINOR7）。
fn runLogInt(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd.LoadLog) !Msg {
    // R20: headState 呼び出しを catch（spawn/OOM も LogLoadFailed へ）。
    const hs = cmds.headState(a, io, cwd) catch
        return mkLoadFailedOrSilent(a, cmd, "git リポジトリ状態の確認に失敗", null);
    switch (hs) {
        .unborn => {
            // R6/m-N1: 空配列 + request_tip="" + is_unborn=true で返す。
            const entries = try a.alloc(log.Commit, 0);
            errdefer a.free(entries);
            return .{ .log_loaded = .{
                .request_skip = cmd.skip,
                .request_max_count = cmd.max_count,
                .request_generation = cmd.generation,
                .request_tip = try a.dupe(u8, ""),
                .is_unborn = true,
                .entries = entries,
            } };
        },
        .err => return mkLoadFailedOrSilent(a, cmd, "git リポジトリ状態が壊れています", null),
        .ok => {},
    }
    // ★B1: rev-parse HEAD で snapshot_tip を取得（フィルタと独立・race 回避）。
    const snapshot_tip = cmds.revParseHead(a, io, cwd) catch
        return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
    if (snapshot_tip == null) return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
    defer a.free(snapshot_tip.?);
    // logArgv へ snapshot_tip を明示限定 + filter を渡す（M8/M11）。
    var argv = try cmds.logArgv(a, cmd.skip, cmd.max_count, snapshot_tip.?, cmd.filter);
    defer argv.deinit(a);
    // MINOR7: StreamTooLong 含む RunError を LogLoadFailed へ正規化。
    var res = process.run(a, io, argv.args, cwd) catch
        return mkLoadFailedOrSilent(a, cmd, "git log 実行エラー", snapshot_tip);
    defer res.deinit(a);
    if (res.exit_code != 0) {
        const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n");
        const text = a.dupe(u8, stderr_trimmed) catch return mkLoadFailedSilent(cmd);
        return .{ .log_load_failed = .{
            .request_generation = cmd.generation,
            .request_tip = dupeOpt(a, snapshot_tip) catch null,
            .error_text = text,
        } };
    }
    const entries = log.parse(a, res.stdout) catch
        return mkLoadFailedOrSilent(a, cmd, "git log パース失敗", snapshot_tip);
    errdefer {
        for (entries) |*c| c.deinit(a);
        a.free(entries);
    }
    // ★B1: request_tip には rev-parse HEAD の結果を dupe して所有。
    return .{ .log_loaded = .{
        .request_skip = cmd.skip,
        .request_max_count = cmd.max_count,
        .request_generation = cmd.generation,
        .request_tip = try a.dupe(u8, snapshot_tip.?),
        .is_unborn = false,
        .entries = entries,
    } };
}

/// §6.1: LogLoadFailed を構築。tip が解決済みなら request_tip へ dupe。
/// OOM 極限で error_text dupe が失敗する場合は LogLoadFailedSilent へ fallback。
fn mkLoadFailedOrSilent(
    a: std.mem.Allocator,
    cmd: AppCmd.LoadLog,
    prefix: []const u8,
    tip: ?[]const u8,
) Msg {
    const text = a.dupe(u8, prefix) catch return mkLoadFailedSilent(cmd);
    const tip_dup = dupeOpt(a, tip) catch {
        a.free(text);
        return mkLoadFailedSilent(cmd);
    };
    return .{ .log_load_failed = .{
        .request_generation = cmd.generation,
        .request_tip = tip_dup,
        .error_text = text,
    } };
}

/// §6.1: OOM 極限の silent 版。payload 無し・generation 照合のみ。
fn mkLoadFailedSilent(cmd: AppCmd.LoadLog) Msg {
    return .{ .log_load_failed_silent = .{ .request_generation = cmd.generation } };
}

/// ?[]const u8 → ?[]u8 への dupe ヘルパ（null はそのまま）。
fn dupeOpt(a: std.mem.Allocator, val: ?[]const u8) !?[]u8 {
    if (val) |v| return try a.dupe(u8, v);
    return null;
}

/// load_log_page 専用の mkPageFailedOrSilent。prefix を所有 []u8 へ複製して log_page_failed を構築。
/// OOM で silent 版へ fallback。
fn mkPageFailedOrSilentForPage(a: std.mem.Allocator, cmd: AppCmd.LoadLogPage, prefix: []const u8) Msg {
    const text = a.dupe(u8, prefix) catch return mkPageFailedSilentForPage(cmd);
    return .{ .log_page_failed = .{ .request_skip = cmd.skip, .request_generation = cmd.generation, .error_text = text } };
}

/// load_log_page 専用の mkPageFailedSilent。OOM 極限の silent 版。
fn mkPageFailedSilentForPage(cmd: AppCmd.LoadLogPage) Msg {
    return .{ .log_page_failed_silent = .{ .request_skip = cmd.skip, .request_generation = cmd.generation } };
}

/// load_log_page 専用: tip_hash 固定で git log を実行（H-06/H-07）。
/// phase 3a §6.2/M3: bad revision（exit 128）は LogPageFailed へ（git_error ではない）。
/// MINOR7: StreamTooLong 含む RunError も LogPageFailed へ正規化。
fn runLogPageInt(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd.LoadLogPage) !Msg {
    var argv = try cmds.logPageArgv(a, cmd.skip, cmd.max_count, cmd.tip_hash, cmd.filter);
    defer argv.deinit(a);
    var res = process.run(a, io, argv.args, cwd) catch
        return mkPageFailedOrSilentForPage(a, cmd, "git log 実行エラー");
    defer res.deinit(a);
    if (res.exit_code != 0) {
        // M3: bad revision（tip が gc 等で消失）は LogPageFailed へ。
        //   reducer 側 handleLogPageFailed で clearLogSnapshotTip + 次 LoadLog で再解決。
        if (res.exit_code == 128) {
            const text = a.dupe(u8, "tip が期限切れです（履歴が移動しました）") catch
                return mkPageFailedSilentForPage(cmd);
            return .{ .log_page_failed = .{
                .request_skip = cmd.skip,
                .request_generation = cmd.generation,
                .error_text = text,
            } };
        }
        const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n");
        const text = a.dupe(u8, stderr_trimmed) catch
            return mkPageFailedSilentForPage(cmd);
        return .{ .log_page_failed = .{
            .request_skip = cmd.skip,
            .request_generation = cmd.generation,
            .error_text = text,
        } };
    }
    const entries = log.parse(a, res.stdout) catch
        return mkPageFailedOrSilentForPage(a, cmd, "git log パース失敗");
    errdefer {
        for (entries) |*c| c.deinit(a);
        a.free(entries);
    }
    // H-07: request_tip には cmd.tip_hash を dupe して所有。reducer で log_snapshot_tip と照合する。
    const tip_dup = try a.dupe(u8, cmd.tip_hash);
    errdefer a.free(tip_dup);
    return .{ .log_page_loaded = .{
        .request_skip = cmd.skip,
        .request_max_count = cmd.max_count,
        .request_generation = cmd.generation,
        .request_tip = tip_dup,
        .entries = entries,
    } };
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

test "apply_patch stages a partial hunk of a renamed file (git mv + unstaged modify)" {
    // spec 2026-06-17-rename-hunk-stage-design.md §2 実験2・§3.4 結合テスト。
    // git mv で rename が staged、内容変更が unstaged な 2 RM 状態で、unstaged 側 diff
    // （new.txt 単体・rename ヘッダ無し）の部分パッチを forward 適用 → 2 R. へ遷移する。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "old.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n");
    try repo.git(a, io, &.{ "git", "add", "old.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // rename を staged にし、その後内容を変更（unstaged）→ 2 RM 状態。
    try repo.git(a, io, &.{ "git", "mv", "old.txt", "new.txt" });
    try repo.writeFile(io, "new.txt", "a\nX\nc\nd\ne\nf\ng\nh\ni\nj\n");
    // unstaged 側 diff を取得: orig_path == null で load_diff を呼ぶ（2 RM 展開後の unstaged エントリ相当）。
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{
        .path = try a.dupe(u8, "new.txt"), .orig_path = null, .section = .unstaged,
    } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    // diff は rename ヘッダを含まない content-only 形式（spec §2 実験1 の検証）。
    try std.testing.expect(std.mem.indexOf(u8, dmsg.diff_loaded, "rename from") == null);
    try std.testing.expect(std.mem.indexOf(u8, dmsg.diff_loaded, "--- a/new.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dmsg.diff_loaded, "+++ b/new.txt") != null);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    // (b->X) 置換を部分 stage する。-b と +X の両方の絶対行を splitScalar で探し、
    // 両方を覆うレンジ [minus_b, plus_X] を選択する（前方 stage で - と + を対で残す必要がある）。
    // ★注意: buildLinePatch(reverse=false) で未選択の + は削除・未選択の - は文脈化される。
    //   よって -b だけを選ぶと「b の削除」だけが stage され +X が落ちる。必ず +X まで含めること。
    var minus_b: usize = 0;
    var plus_X: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) {
            if (std.mem.eql(u8, ln, "-b")) minus_b = i;
            if (std.mem.eql(u8, ln, "+X")) plus_X = i;
        }
    }
    try std.testing.expect(minus_b != 0);
    try std.testing.expect(plus_X != 0);
    try std.testing.expect(minus_b < plus_X); // -b の直後に +X が来る前提
    const maybe = try hunk.buildLinePatch(a, parsed, 0, minus_b, plus_X, false);
    try std.testing.expect(maybe != null);
    // forward 適用: git apply --cached が index の new.txt へ部分パッチを受理する。
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{
        .patch = maybe.?, .reverse = false,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error でないこと
    // 遷移後: staged rename + staged 内容変更 = 2 R.（staged エントリのみ、unstaged は無し）。
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "new.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged); // 2 R. の staged 側
    try std.testing.expect(!has_unstaged); // 内容変更は全て staged へ吸収された
    // index に (b->X) が入ったことを確認。rename を含むためパス指定なしで staged 全体を見る
    // （stagedDiff ヘルパは `-- <path>` 単体指定で、rename 元 old.txt 側がパスフィルタで落ちるため使えない）。
    var r2 = try process.run(a, io, &.{ "git", "diff", "--cached" }, repo.cwd());
    defer r2.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "+X\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "-b\n") != null);
}

// --- TODO 2 phase 1: log/detail 副作用の結合テスト ---

test "load_log returns log_loaded with 3 commits on a populated repo" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // 3 コミット作成（各コミットで 1 ファイル追加）。
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.git(a, io, &.{ "git", "add", "b.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c2" });
    try repo.writeFile(io, "c.txt", "c\n");
    try repo.git(a, io, &.{ "git", "add", "c.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c3" });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = 1, .filter = FilterSpec.init() } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 3), msg.log_loaded.entries.len);
    // 最新コミットが先頭（逆順）。
    try std.testing.expectEqualStrings("c3", msg.log_loaded.entries[0].subject);
    try std.testing.expectEqualStrings("c1", msg.log_loaded.entries[2].subject);
    // request metadata の転写確認。
    try std.testing.expectEqual(@as(usize, 0), msg.log_loaded.request_skip);
    try std.testing.expectEqual(@as(usize, 100), msg.log_loaded.request_max_count);
    try std.testing.expectEqual(@as(u64, 1), msg.log_loaded.request_generation);
    // ★B1: request_tip は rev-parse HEAD の結果（空文字ではない）。
    try std.testing.expect(msg.log_loaded.request_tip.len > 0);
    // ★m-N1: is_unborn=false（commit あり）。
    try std.testing.expect(!msg.log_loaded.is_unborn);
}

test "load_log on empty (unborn) repo returns log_loaded with 0 entries" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // commit なし・untracked ファイルのみ（HEAD 未生成 = unborn）。
    try repo.writeFile(io, "x.txt", "x\n");
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = 7, .filter = FilterSpec.init() } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 0), msg.log_loaded.entries.len);
    try std.testing.expectEqual(@as(u64, 7), msg.log_loaded.request_generation);
    // ★m-N1: is_unborn=true・request_tip は空文字。
    try std.testing.expect(msg.log_loaded.is_unborn);
    try std.testing.expectEqualStrings("", msg.log_loaded.request_tip);
}

test "load_log_page returns log_page_loaded and respects skip" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // 5 コミット作成。
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const name = try std.fmt.allocPrint(a, "f{d}.txt", .{i});
        defer a.free(name);
        try repo.writeFile(io, name, "x\n");
        try repo.git(a, io, &.{ "git", "add", name });
        const msg_str = try std.fmt.allocPrint(a, "m{d}", .{i});
        defer a.free(msg_str);
        try repo.git(a, io, &.{ "git", "commit", "-q", "-m", msg_str });
    }
    // skip=2, max_count=100 → 先頭2件（m4, m3）を飛ばして m2,m1,m0 の 3 件。
    // H-06: tip_hash = "HEAD" で現 tip を固定（ページング中に tip が移動しないよう）。
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log_page = .{
        .skip = 2,
        .max_count = 100,
        .generation = 3,
        .tip_hash = try a.dupe(u8, "HEAD"),
        .filter = FilterSpec.init(),
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_page_loaded);
    try std.testing.expectEqual(@as(usize, 3), msg.log_page_loaded.entries.len);
    try std.testing.expectEqualStrings("m2", msg.log_page_loaded.entries[0].subject);
    try std.testing.expectEqual(@as(usize, 2), msg.log_page_loaded.request_skip);
    try std.testing.expectEqual(@as(u64, 3), msg.log_page_loaded.request_generation);
    // H-07: request_tip には tip_hash が dupe されて転写される。
    try std.testing.expectEqualStrings("HEAD", msg.log_page_loaded.request_tip);
}

test "load_commit_detail returns commit_detail_loaded with name-status entries" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // 初期 commit 後、2 ファイル変更（modify + add）の commit を作る。
    try repo.writeFile(io, "a.txt", "1\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "a.txt", "1\n2\n"); // modify
    try repo.writeFile(io, "b.txt", "new\n"); // add
    try repo.git(a, io, &.{ "git", "add", "a.txt", "b.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "second" });
    // HEAD のハッシュを取得。
    var hr = try process.run(a, io, &.{ "git", "rev-parse", "HEAD" }, repo.cwd());
    defer hr.deinit(a);
    const hash = try a.dupe(u8, std.mem.trimEnd(u8, hr.stdout, "\n"));
    defer a.free(hash);
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_commit_detail = try a.dupe(u8, hash) });
    defer msg.deinit(a);
    try std.testing.expect(msg == .commit_detail_loaded);
    try std.testing.expectEqualStrings(hash, msg.commit_detail_loaded.request_hash);
    // 2 エントリ（a.txt=M, b.txt=A）。順序は git 依存だが両方含まれることを検証。
    try std.testing.expectEqual(@as(usize, 2), msg.commit_detail_loaded.entries.len);
    var found_m = false;
    var found_a = false;
    for (msg.commit_detail_loaded.entries) |e| {
        if (std.mem.eql(u8, e.path, "a.txt") and e.status == 'M') found_m = true;
        if (std.mem.eql(u8, e.path, "b.txt") and e.status == 'A') found_a = true;
    }
    try std.testing.expect(found_m and found_a);
}

test "load_detail_diff returns detail_diff_loaded with diff text" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "1\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "a.txt", "1\n2\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "second" });
    // HEAD のハッシュを取得。
    var hr = try process.run(a, io, &.{ "git", "rev-parse", "HEAD" }, repo.cwd());
    defer hr.deinit(a);
    const hash = try a.dupe(u8, std.mem.trimEnd(u8, hr.stdout, "\n"));
    defer a.free(hash);
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_detail_diff = .{ .hash = try a.dupe(u8, hash), .path = try a.dupe(u8, "a.txt") } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .detail_diff_loaded);
    try std.testing.expectEqualStrings(hash, msg.detail_diff_loaded.request_hash);
    try std.testing.expectEqualStrings("a.txt", msg.detail_diff_loaded.request_path);
    // 追加行 +2 が diff 本文に含まれる。
    try std.testing.expect(std.mem.indexOf(u8, msg.detail_diff_loaded.text, "+2") != null);
}

// --- TODO 2 phase 3a Task 8: author filter + snapshot_tip + typed failures 結合テスト ---

test "runLogInt: filter by author returns matching commits only" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // 異なる作者で 3 コミット作成。
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "-c", "user.name=alice", "commit", "-q", "-m", "c1" });
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.git(a, io, &.{ "git", "add", "b.txt" });
    try repo.git(a, io, &.{ "git", "-c", "user.name=bob", "commit", "-q", "-m", "c2" });
    try repo.writeFile(io, "c.txt", "c\n");
    try repo.git(a, io, &.{ "git", "add", "c.txt" });
    try repo.git(a, io, &.{ "git", "-c", "user.name=alice", "commit", "-q", "-m", "c3" });
    // author=alice でフィルタ → c1, c3 の 2 件。
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "alice");
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 2), msg.log_loaded.entries.len);
    // 両方とも author に alice を含む。
    for (msg.log_loaded.entries) |e| {
        try std.testing.expect(std.mem.indexOf(u8, e.author, "alice") != null);
    }
}

test "runLogInt: empty filter result returns 0 commits with valid snapshot_tip" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    // 存在しない作者でフィルタ → 0 件・snapshot_tip は HEAD と一致。
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "nonexistent");
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 0), msg.log_loaded.entries.len);
    // B1: snapshot_tip は HEAD hash（空一致でも tip は解決される）。
    try std.testing.expect(msg.log_loaded.request_tip.len > 0);
    try std.testing.expect(!msg.log_loaded.is_unborn);
}

test "runLogInt: literal bracket works with --fixed-strings" {
    // --fixed-strings により `[` も regex メタ文字ではなく literal として扱われる。
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "-c", "user.name=test[er", "commit", "-q", "-m", "c1" });
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "test[er");
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 1), msg.log_loaded.entries.len);
}

test "runLogInt: UTF-8 author filter works with --fixed-strings" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "-c", "user.name=山田太郎", "commit", "-q", "-m", "c1" });
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "山田");
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 1), msg.log_loaded.entries.len);
    try std.testing.expectEqualStrings("山田太郎", msg.log_loaded.entries[0].author);
}

test "runLogPageInt: bad revision (exit 128) → LogPageFailed not git_error (M3)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    // 存在しない hash を tip_hash へ → bad revision (exit 128)。
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log_page = .{
        .skip = 0,
        .max_count = 100,
        .generation = 1,
        .tip_hash = try a.dupe(u8, "0000000000000000000000000000000000000000"),
        .filter = FilterSpec.init(),
    } });
    defer msg.deinit(a);
    // M3: git_error ではなく LogPageFailed へ。
    try std.testing.expect(msg == .log_page_failed);
    try std.testing.expect(std.mem.indexOf(u8, msg.log_page_failed.error_text, "tip が期限切れ") != null);
}

test "runLogInt: request_tip matches rev-parse HEAD (B1)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    // 期待される HEAD hash を取得。
    var hr = try process.run(a, io, &.{ "git", "rev-parse", "HEAD" }, repo.cwd());
    defer hr.deinit(a);
    const expected_tip = std.mem.trimEnd(u8, hr.stdout, "\n");
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = FilterSpec.init(),
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    // B1: request_tip は rev-parse HEAD の結果と一致。
    try std.testing.expectEqualStrings(expected_tip, msg.log_loaded.request_tip);
}
