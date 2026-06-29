//! git 各操作の argv 生成（純粋関数・テスト容易）と、`process.run` を呼ぶ
//! 高レベル関数。spec §3/§8 準拠。argv 生成は呼び出し側が free する。

const std = @import("std");
const process = @import("process.zig");
const filter_mod = @import("../filter.zig");
const FilterSpec = filter_mod.FilterSpec;

pub const Section = @import("status.zig").Section;
const Cwd = process.Cwd;

/// 動的確保した文字列のみを追跡し、deinit で解放する。
/// `args` は process.run へ渡す argv（toOwnedSlice なので free 対象）。
/// `owned` は動的確保した文字列のみ（allocPrint 系）。借用文字列は含まない。
pub const OwnedArgv = struct {
    args: []const []const u8,
    owned: std.ArrayList([]const u8),

    pub fn deinit(self: *OwnedArgv, a: std.mem.Allocator) void {
        for (self.owned.items) |s| a.free(s);
        self.owned.deinit(a);
        a.free(self.args);
    }
};

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
    // `-c core.quotePath=false` を git の直後に挿入し、日本語ファイル名の diff ヘッダ
    // (`diff --git` / `---` / `+++`) を octal エスケープ（`\346` 等）せず raw UTF-8 で出す。
    // 実 git で日本語ファイル名がエスケープされる問題への対処（受け入れ基準5）。
    switch (section) {
        .staged => try list.appendSlice(a, &.{ "git", "-c", "core.quotePath=false", "diff", "--cached", "--", path }),
        .unstaged => try list.appendSlice(a, &.{ "git", "-c", "core.quotePath=false", "diff", "--", path }),
        .untracked => try list.appendSlice(a, &.{ "git", "-c", "core.quotePath=false", "diff", "--no-index", "--", "/dev/null", path }),
    }
    if (orig_path) |o| if (section != .untracked) try list.append(a, o);
    return list.toOwnedSlice(a);
}

/// "git apply --cached [--reverse] <file_path>"。呼び出し側が free。
/// file_path は cwd 相対（appcmd が cwd 配下の .git/ に書く）。-p1 は git diff 既定と一致するため不要。
pub fn applyPatchArgv(a: std.mem.Allocator, reverse: bool, file_path: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "apply", "--cached" });
    if (reverse) try list.append(a, "--reverse");
    try list.append(a, file_path);
    return list.toOwnedSlice(a);
}

/// `git log` argv（初回 + paging 共用）。skip=0 のとき --skip を付けない。
/// ★B1: `<snapshot_tip>` を revision として明示限定（rev-parse 後の HEAD 移動でも一貫性保持）。
/// ★M8/M-N6: filter.isEmpty() でなければ `--fixed-strings --author=<literal>` を追加。
/// 動的確保した文字列のみ owned へ追跡。借用（snapshot_tip）は free しない。
pub fn logArgv(
    a: std.mem.Allocator,
    skip: usize,
    max_count: usize,
    snapshot_tip: []const u8,
    filter: FilterSpec,
) !OwnedArgv {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| a.free(s);
        owned.deinit(a);
    }
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "log", "--topo-order",
    });
    if (skip > 0) {
        const skip_arg = try std.fmt.allocPrint(a, "--skip={d}", .{skip});
        try owned.append(a, skip_arg);
        try list.append(a, skip_arg);
    }
    const max_arg = try std.fmt.allocPrint(a, "--max-count={d}", .{max_count});
    try owned.append(a, max_arg);
    try list.append(a, max_arg);
    try appendFilterOptions(a, &list, &owned, filter);
    try list.appendSlice(a, &.{
        "--pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d",
        "-z",
        "--decorate=short",
        "--no-color",
    });
    try list.append(a, snapshot_tip);
    try appendPaths(a, &list, &owned, filter);
    return .{ .args = try list.toOwnedSlice(a), .owned = owned };
}

fn appendFilterOptions(
    a: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    filter: FilterSpec,
) (std.mem.Allocator.Error || filter_mod.DateError)!void {
    if (filter.isEmpty()) return;
    if (filter.getAuthor()) |text| {
        try list.append(a, "--fixed-strings");
        const arg = try std.fmt.allocPrint(a, "--author={s}", .{text});
        try owned.append(a, arg);
        try list.append(a, arg);
    }
    if (filter.getSince()) |text| {
        const ds = try filter_mod.parseDate(text);
        const git_str = try filter_mod.formatGitDate(a, ds, false);
        owned.append(a, git_str) catch {
            a.free(git_str);
            return error.OutOfMemory;
        };
        const arg = std.fmt.allocPrint(a, "--since={s}", .{git_str}) catch return error.OutOfMemory;
        owned.append(a, arg) catch {
            a.free(arg);
            return error.OutOfMemory;
        };
        try list.append(a, arg);
    }
    if (filter.getUntil()) |text| {
        const ds = try filter_mod.parseDate(text);
        const is_date_only = (ds.hour == null);
        const git_str = try filter_mod.formatGitDate(a, ds, is_date_only);
        owned.append(a, git_str) catch {
            a.free(git_str);
            return error.OutOfMemory;
        };
        const arg = std.fmt.allocPrint(a, "--until={s}", .{git_str}) catch return error.OutOfMemory;
        owned.append(a, arg) catch {
            a.free(arg);
            return error.OutOfMemory;
        };
        try list.append(a, arg);
    }
}

fn appendPaths(
    a: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    filter: FilterSpec,
) std.mem.Allocator.Error!void {
    const paths = filter.getPaths();
    if (paths.len == 0) return;
    try list.append(a, "--");
    for (paths) |p| {
        const dup = try a.dupe(u8, p);
        try owned.append(a, dup);
        try list.append(a, dup);
    }
}

/// `git log --topo-order --skip=N --max-count=100 <snapshot_tip>` argv（paging 用）。
/// ★H-06/H-07: snapshot_tip を固定し同一 snapshot を参照する。
/// ★M8/M-N6: filter 追加（logArgv と同様）。
pub fn logPageArgv(
    a: std.mem.Allocator,
    skip: usize,
    max_count: usize,
    snapshot_tip: []const u8,
    filter: FilterSpec,
) !OwnedArgv {
    return logArgv(a, skip, max_count, snapshot_tip, filter);
}

/// `git show --name-status` argv。H4/H5: 第一親との差・header なし・NUL 区切り。
pub fn showNameStatusArgv(a: std.mem.Allocator, hash: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "show",
        "--diff-merges=first-parent", "--format=", "--name-status", "-z",
    });
    try list.append(a, hash);
    return list.toOwnedSlice(a);
}

/// `git show <hash> -- <path>` argv。H4: name-status と同じ第一親基準。
pub fn showFileDiffArgv(a: std.mem.Allocator, hash: []const u8, path: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "show",
        "--diff-merges=first-parent", "--format=",
    });
    try list.append(a, hash);
    try list.append(a, "--");
    try list.append(a, path);
    return list.toOwnedSlice(a);
}

/// `["git", "rev-parse", "--absolute-git-dir"]` を生成（純粋・呼出側 free）。
/// worktree / submodule でも実 git-dir へ解決するため apply_patch の書込先特定に使う。
pub fn gitDirArgv(a: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "rev-parse", "--absolute-git-dir" });
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

/// cwd を起点に絶対 git-dir パスを返す（worktree/submodule の .git ファイルも解決）。
/// 失敗（非リポジトリ・exit!=0）は null、spawn 失敗は RunError 伝播（repoRoot と同型）。
/// 呼出側が free（成功時のみ確保）。
pub fn gitDir(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !?[]u8 {
    const argv = try gitDirArgv(a);
    defer a.free(argv);
    var res = try process.run(a, io, argv, cwd);
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

/// `git rev-parse --verify HEAD` の argv（借用 static・free 不要）。
pub fn revParseHeadArgv() []const []const u8 {
    return &.{ "git", "rev-parse", "--verify", "HEAD" };
}

/// `git rev-parse --verify --end-of-options <rev>^{commit}` argv（branch/revspec 解決用・phase 3b #1）。
/// ★--end-of-options: 先頭 `-` の入力を option ではなく revspec として扱い injection を防ぐ（真の安全境界・実証済み）。
/// ★^{commit}: blob/tree hash を弾き commit のみ受理（peel 失敗は exit≠0 → null・実証済み）。
/// revspec から "<rev>^{commit}" を生成し owned へ追跡（logArgv の --author 文字列と同型・OwnedArgv.deinit が free・二重 free 無し）。
pub fn revParseVerifyArgv(a: std.mem.Allocator, revspec: []const u8) !OwnedArgv {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| a.free(s);
        owned.deinit(a);
    }
    try list.appendSlice(a, &.{ "git", "rev-parse", "--verify", "--end-of-options" });
    const rev_with_peel = std.fmt.allocPrint(a, "{s}^{{commit}}", .{revspec}) catch return error.OutOfMemory;
    owned.append(a, rev_with_peel) catch {
        a.free(rev_with_peel);
        return error.OutOfMemory;
    };
    try list.append(a, rev_with_peel);
    return .{ .args = try list.toOwnedSlice(a), .owned = owned };
}

/// `git rev-list --topo-order --parents <snapshot_tip>` argv（phase 3b #2 graph 投影用 substrate）。
/// 全履歴の hash + 実 parents を取得（フィルタ無し）。snapshot_tip は借用（logArgv と同型・owned に入れない）。
pub fn revListParentsArgv(a: std.mem.Allocator, snapshot_tip: []const u8) !OwnedArgv {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "rev-list", "--topo-order", "--parents" });
    try list.append(a, snapshot_tip); // 借用
    return .{ .args = try list.toOwnedSlice(a), .owned = .empty };
}

/// HEAD hash を dupe して返す（呼出側 free）。exit 128（unborn 等）は null。
/// headState が .ok のときだけ呼ぶことを前提（.unborn/.err は呼出元で処理済み）。
pub fn revParseHead(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !?[]u8 {
    var res = try process.run(a, io, revParseHeadArgv(), cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    return try a.dupe(u8, trimmed);
}

/// revspec を commit hash へ解決（呼出側 free）。exit≠0（不明 branch/rev・blob/tree・peel 失敗）は null。
/// ★phase 3b #1: branch フィルタの snapshot_tip 解決に使用（revParseHead の汎化版）。
pub fn revParseVerify(a: std.mem.Allocator, io: std.Io, cwd: Cwd, revspec: []const u8) !?[]u8 {
    var argv = try revParseVerifyArgv(a, revspec);
    defer argv.deinit(a);
    var res = try process.run(a, io, argv.args, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    return try a.dupe(u8, trimmed);
}

/// R5/R19/R23: HEAD 状態の tri-state（ok/unborn/err）。
pub const HeadState = enum { ok, unborn, err };

/// R5/R19/R23: rev-parse --verify HEAD だけでは unborn と壊れた HEAD・object 欠損・権限エラーを区別できない
/// （どれも exit 128 を返し得る）。3 段階で厳密判定する:
///   (1) rev-parse --verify HEAD の exit code（0=ok / 128=(2)へ / その他=err）
///   (2) exit 128 のとき symbolic-ref --short HEAD で branch 名を取得（失敗=err）
///   (3) branch 名で show-ref --verify --quiet refs/heads/<branch> を実行:
///       exit 0 → ref が存在するが HEAD が exit 128 → dangling（object 無し）→ err
///       exit 1 → ref が存在しない → unborn
///       その他 → err
///   ※R23b 実測: show-ref --verify <ref> は不存在時に exit 128 を返す（exit 1 ではない）。
///     --quiet を付けると不存在時に exit 1・存在時に exit 0 になるので必ず --quiet 付きで使う。
pub fn headState(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !HeadState {
    var res1 = try process.run(a, io, &.{ "git", "rev-parse", "--verify", "HEAD" }, cwd);
    defer res1.deinit(a);
    return switch (res1.exit_code) {
        0 => .ok,
        128 => blk: {
            // (2) symbolic-ref で branch 名取得
            var res2 = try process.run(a, io, &.{ "git", "symbolic-ref", "--short", "HEAD" }, cwd);
            defer res2.deinit(a);
            if (res2.exit_code != 0) break :blk .err;
            const branch = std.mem.trimEnd(u8, res2.stdout, "\n");
            if (branch.len == 0) break :blk .err;
            // (3) show-ref --verify --quiet で ref 実在確認
            const ref_buf = try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch});
            defer a.free(ref_buf);
            var res3 = try process.run(a, io, &.{ "git", "show-ref", "--verify", "--quiet", ref_buf }, cwd);
            defer res3.deinit(a);
            break :blk switch (res3.exit_code) {
                0 => .err, // ref が有るのに HEAD exit 128 = dangling
                1 => .unborn, // ref 無し = 空リポジトリ
                else => .err,
            };
        },
        else => .err,
    };
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
    // git, -c, core.quotePath=false が先頭に入るため index は +2 シフト。
    try std.testing.expectEqualStrings("--no-index", argv[4]);
    try std.testing.expectEqualStrings("/dev/null", argv[6]);
}

test "diffArgv staged uses --cached" {
    const a = std.testing.allocator;
    const argv = try diffArgv(a, .staged, "f.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("diff", argv[3]);
    try std.testing.expectEqualStrings("--cached", argv[4]);
}

test "diffArgv untracked ignores orig_path" {
    const a = std.testing.allocator;
    const argv = try diffArgv(a, .untracked, "new.txt", "old.txt");
    defer a.free(argv);
    // -c core.quotePath=false(+2) + /dev/null + new.txt のみ。orig_path は untracked では無視される。
    try std.testing.expectEqual(@as(usize, 8), argv.len);
}

test "diffArgv injects -c core.quotePath=false right after git (all sections)" {
    const a = std.testing.allocator;
    inline for (.{ Section.staged, Section.unstaged, Section.untracked }) |sec| {
        const argv = try diffArgv(a, sec, "日本語.txt", null);
        defer a.free(argv);
        try std.testing.expectEqualStrings("git", argv[0]);
        try std.testing.expectEqualStrings("-c", argv[1]);
        try std.testing.expectEqualStrings("core.quotePath=false", argv[2]);
        try std.testing.expectEqualStrings("diff", argv[3]);
    }
}

test "applyPatchArgv: forward has no --reverse, file_path last" {
    const a = std.testing.allocator;
    const argv = try applyPatchArgv(a, false, ".git/git-tui-stage.patch");
    defer a.free(argv);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("apply", argv[1]);
    try std.testing.expectEqualStrings("--cached", argv[2]);
    try std.testing.expectEqualStrings(".git/git-tui-stage.patch", argv[3]);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
}

test "applyPatchArgv: reverse inserts --reverse before file_path" {
    const a = std.testing.allocator;
    const argv = try applyPatchArgv(a, true, ".git/git-tui-stage.patch");
    defer a.free(argv);
    try std.testing.expectEqualStrings("--reverse", argv[3]);
    try std.testing.expectEqualStrings(".git/git-tui-stage.patch", argv[4]);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
}

test "gitDirArgv builds rev-parse --absolute-git-dir" {
    const a = std.testing.allocator;
    const argv = try gitDirArgv(a);
    defer a.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("rev-parse", argv[1]);
    try std.testing.expectEqualStrings("--absolute-git-dir", argv[2]);
}

test "logArgv: empty filter + snapshot_tip unchanged structure" {
    const a = std.testing.allocator;
    var argv = try logArgv(a, 0, 100, "snap1234", FilterSpec.init());
    defer argv.deinit(a);
    try std.testing.expectEqualStrings("git", argv.args[0]);
    try std.testing.expectEqualStrings("-c", argv.args[1]);
    try std.testing.expectEqualStrings("core.quotePath=false", argv.args[2]);
    try std.testing.expectEqualStrings("log", argv.args[3]);
    try std.testing.expectEqualStrings("--topo-order", argv.args[4]);
    // skip=0 so no --skip
    var has_skip = false;
    for (argv.args) |arg| if (std.mem.startsWith(u8, arg, "--skip")) {
        has_skip = true;
    };
    try std.testing.expect(!has_skip);
    var has_pretty = false;
    var has_z = false;
    var has_decorate = false;
    var has_nocolor = false;
    var has_maxcount = false;
    var has_snapshot = false;
    for (argv.args) |arg| {
        if (std.mem.startsWith(u8, arg, "--pretty=format")) has_pretty = true;
        if (std.mem.eql(u8, arg, "-z")) has_z = true;
        if (std.mem.eql(u8, arg, "--decorate=short")) has_decorate = true;
        if (std.mem.eql(u8, arg, "--no-color")) has_nocolor = true;
        if (std.mem.startsWith(u8, arg, "--max-count=")) has_maxcount = true;
        if (std.mem.eql(u8, arg, "snap1234")) has_snapshot = true;
    }
    try std.testing.expect(has_pretty);
    try std.testing.expect(has_z);
    try std.testing.expect(has_decorate);
    try std.testing.expect(has_nocolor);
    try std.testing.expect(has_maxcount);
    try std.testing.expect(has_snapshot);
    // snapshot_tip is the last arg (revision pin)
    try std.testing.expectEqualStrings("snap1234", argv.args[argv.args.len - 1]);
}

test "logArgv: skip=100 includes --skip=100" {
    const a = std.testing.allocator;
    var argv = try logArgv(a, 100, 100, "snap1234", FilterSpec.init());
    defer argv.deinit(a);
    var found_skip: ?[]const u8 = null;
    for (argv.args) |arg| if (std.mem.startsWith(u8, arg, "--skip=")) {
        found_skip = arg;
    };
    try std.testing.expect(found_skip != null);
    try std.testing.expectEqualStrings("--skip=100", found_skip.?);
}

test "logArgv: author filter adds --fixed-strings and --author" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var has_fixed = false;
    var has_author = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--fixed-strings")) has_fixed = true;
        if (std.mem.eql(u8, arg, "--author=foo")) has_author = true;
    }
    try std.testing.expect(has_fixed);
    try std.testing.expect(has_author);
}

test "logArgv: UTF-8 author preserved in argv" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "山田太郎") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var found = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--author=山田太郎")) found = true;
    }
    try std.testing.expect(found);
}

test "logPageArgv: skip + snapshot_tip + empty filter" {
    const a = std.testing.allocator;
    var argv = try logPageArgv(a, 100, 100, "abc123", FilterSpec.init());
    defer argv.deinit(a);
    // snapshot_tip is the last arg
    try std.testing.expectEqualStrings("abc123", argv.args[argv.args.len - 1]);
    var has_topo = false;
    var has_skip = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--topo-order")) has_topo = true;
        if (std.mem.eql(u8, arg, "--skip=100")) has_skip = true;
    }
    try std.testing.expect(has_topo);
    try std.testing.expect(has_skip);
}

test "logPageArgv: author filter adds --fixed-strings and --author" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "bar") });
    var argv = try logPageArgv(a, 0, 100, "abc123", spec);
    defer argv.deinit(a);
    var has_fixed = false;
    var has_author = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--fixed-strings")) has_fixed = true;
        if (std.mem.eql(u8, arg, "--author=bar")) has_author = true;
    }
    try std.testing.expect(has_fixed);
    try std.testing.expect(has_author);
}

test "OwnedArgv.deinit frees owned strings only (borrowed safe)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    // snapshot_tip is borrowed (literal) — not freed by deinit
    var argv = try logArgv(a, 0, 100, "borrowed_tip", spec);
    // deinit must free --max-count, --author strings + args slice, but NOT "borrowed_tip"
    argv.deinit(a);
}

test "revParseHeadArgv returns git rev-parse --verify HEAD" {
    const argv = revParseHeadArgv();
    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("rev-parse", argv[1]);
    try std.testing.expectEqualStrings("--verify", argv[2]);
    try std.testing.expectEqualStrings("HEAD", argv[3]);
}

test "revParseVerifyArgv: git rev-parse --verify --end-of-options <rev>^{commit} (phase 3b #1)" {
    const a = std.testing.allocator;
    var argv = try revParseVerifyArgv(a, "dev");
    defer argv.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), argv.args.len);
    try std.testing.expectEqualStrings("git", argv.args[0]);
    try std.testing.expectEqualStrings("rev-parse", argv.args[1]);
    try std.testing.expectEqualStrings("--verify", argv.args[2]);
    try std.testing.expectEqualStrings("--end-of-options", argv.args[3]);
    try std.testing.expectEqualStrings("dev^{commit}", argv.args[4]);
    try std.testing.expectEqual(@as(usize, 1), argv.owned.items.len);
    try std.testing.expectEqualStrings("dev^{commit}", argv.owned.items[0]);
}

test "revParseVerifyArgv: UTF-8 revspec preserved in peel suffix" {
    const a = std.testing.allocator;
    var argv = try revParseVerifyArgv(a, "feature/日本語");
    defer argv.deinit(a);
    try std.testing.expectEqualStrings("feature/日本語^{commit}", argv.args[4]);
}

test "revListParentsArgv: git rev-list --topo-order --parents <snapshot_tip> (phase 3b #2)" {
    const a = std.testing.allocator;
    var argv = try revListParentsArgv(a, "snap9999");
    defer argv.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), argv.args.len);
    try std.testing.expectEqualStrings("git", argv.args[0]);
    try std.testing.expectEqualStrings("rev-list", argv.args[1]);
    try std.testing.expectEqualStrings("--topo-order", argv.args[2]);
    try std.testing.expectEqualStrings("--parents", argv.args[3]);
    try std.testing.expectEqualStrings("snap9999", argv.args[4]); // 末尾・借用
    try std.testing.expectEqual(@as(usize, 0), argv.owned.items.len); // owned 空（snapshot_tip 借用）
}

test "showNameStatusArgv: --diff-merges=first-parent --format= --name-status -z" {
    const a = std.testing.allocator;
    const argv = try showNameStatusArgv(a, "abc123");
    defer a.free(argv);
    var has_diffmerges = false;
    var has_format = false;
    var has_namestatus = false;
    var has_z = false;
    var has_hash = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--diff-merges=first-parent")) has_diffmerges = true;
        if (std.mem.eql(u8, arg, "--format=")) has_format = true;
        if (std.mem.eql(u8, arg, "--name-status")) has_namestatus = true;
        if (std.mem.eql(u8, arg, "-z")) has_z = true;
        if (std.mem.eql(u8, arg, "abc123")) has_hash = true;
    }
    try std.testing.expect(has_diffmerges);
    try std.testing.expect(has_format);
    try std.testing.expect(has_namestatus);
    try std.testing.expect(has_z);
    try std.testing.expect(has_hash);
}

test "showFileDiffArgv: --diff-merges=first-parent --format= <hash> -- <path>" {
    const a = std.testing.allocator;
    const argv = try showFileDiffArgv(a, "abc123", "src/main.zig");
    defer a.free(argv);
    var has_diffmerges = false;
    var has_format = false;
    var has_dd = false;
    var has_hash = false;
    var has_path = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--diff-merges=first-parent")) has_diffmerges = true;
        if (std.mem.eql(u8, arg, "--format=")) has_format = true;
        if (std.mem.eql(u8, arg, "--")) has_dd = true;
        if (std.mem.eql(u8, arg, "abc123")) has_hash = true;
        if (std.mem.eql(u8, arg, "src/main.zig")) has_path = true;
    }
    try std.testing.expect(has_diffmerges);
    try std.testing.expect(has_format);
    try std.testing.expect(has_dd);
    try std.testing.expect(has_hash);
    try std.testing.expect(has_path);
}

// 高レベル関数（実行系）はテスト未参照だと Zig のレイジー解析でボディが
// 解析されない。refAllDecls で全 decl を参照し、process.run/Cwd/RunResult への
// 型整合をコンパイル時に検証する。
test "logArgv: since-only filter adds --since" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .since = try a.dupe(u8, "2026-06-01") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var has_since = false;
    var has_fixed = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--since=2026-06-01 00:00:00")) has_since = true;
        if (std.mem.eql(u8, arg, "--fixed-strings")) has_fixed = true;
    }
    try std.testing.expect(has_since);
    try std.testing.expect(!has_fixed);
}

test "logArgv: until date-only adds +1day --until" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .until = try a.dupe(u8, "2026-06-01") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var has_until = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--until=2026-06-02 00:00:00")) has_until = true;
    }
    try std.testing.expect(has_until);
}

test "logArgv: until HH:MM unchanged" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .until = try a.dupe(u8, "2026-06-01 12:00") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var has_until = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--until=2026-06-01 12:00:00")) has_until = true;
    }
    try std.testing.expect(has_until);
}

test "logArgv: paths-only appends -- after snapshot_tip" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    const paths = try a.alloc([]u8, 2);
    paths[0] = try a.dupe(u8, "src/");
    paths[1] = try a.dupe(u8, "test/");
    try spec.addCondition(a, .{ .paths = paths });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var snapshot_idx: ?usize = null;
    var dd_idx: ?usize = null;
    for (argv.args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "snap1234")) snapshot_idx = i;
        if (std.mem.eql(u8, arg, "--")) dd_idx = i;
    }
    try std.testing.expect(snapshot_idx != null);
    try std.testing.expect(dd_idx != null);
    try std.testing.expect(snapshot_idx.? < dd_idx.?);
    try std.testing.expectEqualStrings("src/", argv.args[dd_idx.? + 1]);
    try std.testing.expectEqualStrings("test/", argv.args[dd_idx.? + 2]);
}

test "logArgv: all variants sorted by variant order" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .until = try a.dupe(u8, "2026-06-01") });
    const paths = try a.alloc([]u8, 1);
    paths[0] = try a.dupe(u8, "src/");
    try spec.addCondition(a, .{ .paths = paths });
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    try spec.addCondition(a, .{ .since = try a.dupe(u8, "2026-06-01") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var author_idx: ?usize = null;
    var since_idx: ?usize = null;
    var until_idx: ?usize = null;
    var dd_idx: ?usize = null;
    for (argv.args, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "--author=")) author_idx = i;
        if (std.mem.startsWith(u8, arg, "--since=")) since_idx = i;
        if (std.mem.startsWith(u8, arg, "--until=")) until_idx = i;
        if (std.mem.eql(u8, arg, "--")) dd_idx = i;
    }
    try std.testing.expect(author_idx != null);
    try std.testing.expect(since_idx != null);
    try std.testing.expect(until_idx != null);
    try std.testing.expect(dd_idx != null);
    try std.testing.expect(author_idx.? < since_idx.?);
    try std.testing.expect(since_idx.? < until_idx.?);
    try std.testing.expect(until_idx.? < dd_idx.?);
}

test "logArgv: --fixed-strings only when author present" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .since = try a.dupe(u8, "2026-06-01") });
    try spec.addCondition(a, .{ .until = try a.dupe(u8, "2026-06-30") });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var has_fixed = false;
    for (argv.args) |arg| {
        if (std.mem.eql(u8, arg, "--fixed-strings")) has_fixed = true;
    }
    try std.testing.expect(!has_fixed);
}

test "logArgv: branch condition does not leak into argv (revision-side only, phase 3b #1)" {
    // ★B3 解法の核心不変条件: branch は runLogInt が snapshot_tip 解決に消費し、logArgv の argv へは
    //   一切出ない（--branches も branch 文字列も無い）。paths 等の他フィルタは従来通り argv 末尾へ。
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    const paths = try a.alloc([]u8, 1);
    paths[0] = try a.dupe(u8, "src/");
    try spec.addCondition(a, .{ .paths = paths });
    var argv = try logArgv(a, 0, 100, "snap1234", spec);
    defer argv.deinit(a);
    var has_branch_leak = false;
    for (argv.args) |arg| {
        if (std.mem.startsWith(u8, arg, "--branches")) has_branch_leak = true;
        if (std.mem.eql(u8, arg, "dev")) has_branch_leak = true;
    }
    try std.testing.expect(!has_branch_leak);
    // paths は snapshot_tip の後の -- 以降へ（author/date と compose 可能）。
    var snapshot_idx: ?usize = null;
    var dd_idx: ?usize = null;
    for (argv.args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "snap1234")) snapshot_idx = i;
        if (std.mem.eql(u8, arg, "--")) dd_idx = i;
    }
    try std.testing.expect(snapshot_idx != null);
    try std.testing.expect(dd_idx != null);
    try std.testing.expect(snapshot_idx.? < dd_idx.?);
    try std.testing.expectEqualStrings("src/", argv.args[dd_idx.? + 1]);
}

test {
    std.testing.refAllDecls(@This());
}
