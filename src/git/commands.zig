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
    if (!filter.isEmpty()) {
        try list.append(a, "--fixed-strings");
        const author_arg = try std.fmt.allocPrint(a, "--author={s}", .{filter.author.?});
        try owned.append(a, author_arg);
        try list.append(a, author_arg);
    }
    try list.appendSlice(a, &.{
        "--pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d",
        "-z",
        "--decorate=short",
        "--no-color",
    });
    try list.append(a, snapshot_tip);
    return .{ .args = try list.toOwnedSlice(a), .owned = owned };
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

/// HEAD hash を dupe して返す（呼出側 free）。exit 128（unborn 等）は null。
/// headState が .ok のときだけ呼ぶことを前提（.unborn/.err は呼出元で処理済み）。
pub fn revParseHead(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !?[]u8 {
    var res = try process.run(a, io, revParseHeadArgv(), cwd);
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
    try spec.setAuthor(a, "foo");
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
    try spec.setAuthor(a, "山田太郎");
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
    try spec.setAuthor(a, "bar");
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
    try spec.setAuthor(a, "foo");
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
test {
    std.testing.refAllDecls(@This());
}
