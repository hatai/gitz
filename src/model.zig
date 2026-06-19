const std = @import("std");
const status = @import("git/status.zig");
const log_mod = @import("git/log.zig");
const show_mod = @import("git/show.zig");
const graph_mod = @import("git/graph.zig");

/// 最後に load_diff を発行したファイル識別子（層 1: codex B1 対策）。path のみで追跡すると
/// partial stage で `? f` → `1 AM` 展開時の section 変化を取り逃がすため、section も持つ。
/// `orig_path` は含めない（section 変化検出を優先）。
pub const DiffOwner = struct { path: []u8, section: status.Section };

pub const Focus = enum { changes, diff, commit };

pub const ViewMode = enum { changes, log };
pub const DetailKind = enum { files, diff };

pub const FileItem = struct {
    path: []u8,
    orig_path: ?[]u8,
    section: status.Section,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    repo_root: []u8,
    has_head: bool,
    branch: []u8,
    files: std.ArrayList(FileItem),
    selected: usize,
    changes_scroll: usize, // Changes ペインの先頭表示**行**（見出し含む visual row オフセット）
    diff_text: []u8, // 選択ファイルの diff（空可）
    diff_scroll: usize, // diff ペインの先頭表示行（スクロールオフセット）
    diff_cursor: usize, // diff ペインのカーソル（絶対 diff 行 index）。行単位選択の基準。
    diff_anchor: ?usize, // ビジュアル選択の anchor（絶対 diff 行）。null=範囲未選択。
    diff_owner: ?DiffOwner, // 最後に load_diff を発行したファイル。null = 未発行（初回）。
    commit_message: []u8, // TextArea の内容（空可）
    focus: Focus,
    busy: bool, // reducer の二重実行ゲート（全 in-flight 副作用で true）。表示はしない。
    working: bool, // スピナ表示用（変更系=stage/unstage/commit/apply_patch の実行中のみ true）。runtime が管理。
    error_text: []u8, // 直近エラー（空可）
    git_dir: ?[]u8, // 絶対 git-dir パス。null = 解決失敗（フォールバック用）。起動時のみ設定。
    mouse_enabled: bool,

    // --- TODO 2 phase 1: log/detail ビュー ---
    view_mode: ViewMode,
    log_commits: std.ArrayList(@import("git/log.zig").Commit),
    log_selected: usize,
    log_scroll: usize,
    log_has_more: bool,
    log_request_generation: u64,
    log_page_requested: ?usize,
    log_restore_hash: ?[]u8,
    detail_kind: DetailKind,
    detail_files: std.ArrayList(@import("git/show.zig").NameStatus),
    detail_selected: usize,
    detail_scroll: usize,
    detail_owner_hash: ?[]u8,
    detail_diff: []u8,
    detail_diff_scroll: usize,
    detail_diff_owner_hash: ?[]u8,
    detail_diff_owner_path: ?[]u8,

    // --- TODO 2 phase 2: graph display + paging tip ---
    log_graph_state: graph_mod.GraphState,
    log_paging_tip: ?[]u8,

    pub fn init(a: std.mem.Allocator, repo_root: []const u8) !Model {
        return .{
            .allocator = a,
            .repo_root = try a.dupe(u8, repo_root),
            .has_head = false,
            .branch = try a.dupe(u8, ""),
            .files = .empty,
            .selected = 0,
            .changes_scroll = 0,
            .diff_text = try a.dupe(u8, ""),
            .diff_scroll = 0,
            .diff_cursor = 0,
            .diff_anchor = null,
            .diff_owner = null,
            .commit_message = try a.dupe(u8, ""),
            .focus = .changes,
            .busy = false,
            .working = false,
            .error_text = try a.dupe(u8, ""),
            .git_dir = null,
            .mouse_enabled = true,

            .view_mode = .changes,
            .log_commits = .empty,
            .log_selected = 0,
            .log_scroll = 0,
            .log_has_more = false,
            .log_request_generation = 0,
            .log_page_requested = null,
            .log_restore_hash = null,
            .detail_kind = .files,
            .detail_files = .empty,
            .detail_selected = 0,
            .detail_scroll = 0,
            .detail_owner_hash = null,
            .detail_diff = try a.dupe(u8, ""),
            .detail_diff_scroll = 0,
            .detail_diff_owner_hash = null,
            .detail_diff_owner_path = null,

            // --- TODO 2 phase 2: graph display + paging tip ---
            .log_graph_state = .invalid,
            .log_paging_tip = null,
        };
    }

    pub fn deinit(self: *Model) void {
        const a = self.allocator;
        a.free(self.repo_root);
        if (self.git_dir) |g| a.free(g);
        a.free(self.branch);
        for (self.files.items) |*f| {
            a.free(f.path);
            if (f.orig_path) |p| a.free(p);
        }
        self.files.deinit(a);
        a.free(self.diff_text);
        if (self.diff_owner) |o| a.free(o.path);
        a.free(self.commit_message);
        a.free(self.error_text);

        // --- TODO 2 phase 1: log/detail の解放 ---
        for (self.log_commits.items) |*c| c.deinit(a);
        self.log_commits.deinit(a);
        if (self.log_restore_hash) |h| a.free(h);
        for (self.detail_files.items) |*e| e.deinit(a);
        self.detail_files.deinit(a);
        if (self.detail_owner_hash) |h| a.free(h);
        a.free(self.detail_diff);
        if (self.detail_diff_owner_hash) |h| a.free(h);
        if (self.detail_diff_owner_path) |p| a.free(p);

        // --- TODO 2 phase 2 ---
        self.log_graph_state.deinit(a);
        if (self.log_paging_tip) |t| a.free(t);
    }

    /// files を新しいエントリ集合で置換。entries は**複製**する（借用しない）。entries 自体の所有権は
    /// 呼び出し側に残り、Msg.status_loaded の deinit で解放する（spec §4: 二重 free 防止）。
    /// **トランザクショナル**: 新リストを完全に構築してから既存と入れ替える。途中で確保失敗しても
    /// 既存の Model 状態は壊さない（中途半端な破壊を避ける）。
    pub fn replaceFiles(self: *Model, entries: []const status.StatusEntry) !void {
        const a = self.allocator;
        // 置換前の選択ファイル識別子（section + path）を控える。path は旧 files を指す借用 slice。
        // next 構築〜照合は旧 files 解放より前に行うので安全（解放後に prev は使わない）。
        const prev: ?struct { section: status.Section, path: []const u8 } =
            if (self.selected < self.files.items.len)
                .{ .section = self.files.items[self.selected].section, .path = self.files.items[self.selected].path }
            else
                null;

        var next: std.ArrayList(FileItem) = .empty;
        errdefer {
            for (next.items) |*f| {
                a.free(f.path);
                if (f.orig_path) |p| a.free(p);
            }
            next.deinit(a);
        }
        for (entries) |e| {
            const path = try a.dupe(u8, e.path);
            errdefer a.free(path);
            const orig: ?[]u8 = if (e.orig_path) |p| try a.dupe(u8, p) else null;
            errdefer if (orig) |o| a.free(o);
            try next.append(a, .{ .path = path, .orig_path = orig, .section = e.section });
        }
        // 表示順（section: staged→unstaged→untracked、その中で path 昇順）に並べ替え、
        // **格納順 == 表示順** にする。これにより j/k（model.selected を格納順で線形移動）の
        // ハイライトが画面上を連続的に動く（view.changesRowLayout の表示順と一致する）。
        std.mem.sort(FileItem, next.items, {}, lessThanForDisplay);

        // 選択を復元。2 段階: (1) (section, path) 完全一致、(2) path のみでフォールバック（unstaged>staged>untracked優先）。
        // 第 2 段階は部分 stage で section が変わったケース（? untracked.txt → 1 AM で
        // .untracked → .staged+.unstaged）へ選択を追従させる（Bug 2）。unstaged 優先は
        // 「まだ作業が残っている」側へ誘導し連続 stage を継続しやすくする。
        var new_selected: usize = self.selected;
        if (prev) |p| {
            var found_exact: ?usize = null;
            var found_path_only: ?usize = null;
            for (next.items, 0..) |f, i| {
                if (found_exact == null and f.section == p.section and std.mem.eql(u8, f.path, p.path)) {
                    found_exact = i;
                }
                if (found_path_only == null and std.mem.eql(u8, f.path, p.path)) {
                    found_path_only = i;
                }
            }
            if (found_exact) |i| {
                new_selected = i;
            } else if (found_path_only != null) {
                // 完全一致無し。path のみで一致するエントリから優先順位（unstaged>staged>untracked）で選ぶ。
                new_selected = selectByPathPriority(next.items, p.path);
            }
            // どちらも見つからなければ new_selected は self.selected のまま（下で index クランプ）。
        }

        // ここまで来れば成功。旧 files を解放して入れ替える（以降 prev.path は使わない）。
        for (self.files.items) |*f| {
            a.free(f.path);
            if (f.orig_path) |p| a.free(p);
        }
        self.files.deinit(a);
        self.files = next;
        self.selected = if (self.files.items.len == 0) 0 else @min(new_selected, self.files.items.len - 1);
    }

    /// 文字列フィールドを置換するヘルパ（旧を free して dup）。
    pub fn setStr(self: *Model, field: *[]u8, value: []const u8) !void {
        const a = self.allocator;
        const dup = try a.dupe(u8, value);
        a.free(field.*);
        field.* = dup;
    }

    /// diff_owner を置換する（旧を free して dup）。loadDiffCmd が呼ぶ（層 1）。
    pub fn setDiffOwner(self: *Model, path: []const u8, section: status.Section) !void {
        const a = self.allocator;
        const new_path = try a.dupe(u8, path);
        if (self.diff_owner) |old| a.free(old.path);
        self.diff_owner = .{ .path = new_path, .section = section };
    }

    /// diff_owner をクリアする（ファイル一覧が空になった等）。純粋。
    pub fn clearDiffOwner(self: *Model) void {
        const a = self.allocator;
        if (self.diff_owner) |old| a.free(old.path);
        self.diff_owner = null;
    }

    /// 入力 entries（Msg 所有）を deep-copy して新 ArrayList を構築し、成功後に旧を解放して swap（H6/R1）。
    pub fn replaceLogCommits(self: *Model, entries: []const log_mod.Commit) !void {
        const a = self.allocator;
        var next: std.ArrayList(log_mod.Commit) = .empty;
        errdefer {
            for (next.items) |*c| c.deinit(a);
            next.deinit(a);
        }
        for (entries) |e| {
            var cloned = try cloneCommit(a, e);
            errdefer cloned.deinit(a);
            try next.append(a, cloned);
        }
        for (self.log_commits.items) |*c| c.deinit(a);
        self.log_commits.deinit(a);
        self.log_commits = next;
    }

    /// 既存 log_commits.items と入力 new_entries を全て deep-copy した unified list を構築 → swap（H6/R1）。
    pub fn appendLogCommits(self: *Model, new_entries: []const log_mod.Commit) !void {
        const a = self.allocator;
        var next: std.ArrayList(log_mod.Commit) = .empty;
        errdefer {
            for (next.items) |*c| c.deinit(a);
            next.deinit(a);
        }
        for (self.log_commits.items) |c| {
            var cloned = try cloneCommit(a, c);
            errdefer cloned.deinit(a);
            try next.append(a, cloned);
        }
        for (new_entries) |e| {
            var cloned = try cloneCommit(a, e);
            errdefer cloned.deinit(a);
            try next.append(a, cloned);
        }
        for (self.log_commits.items) |*c| c.deinit(a);
        self.log_commits.deinit(a);
        self.log_commits = next;
    }

    /// detail_files への適用。NameStatus も deep-copy し append 毎に errdefer。
    pub fn replaceDetailFiles(self: *Model, entries: []const show_mod.NameStatus) !void {
        const a = self.allocator;
        var next: std.ArrayList(show_mod.NameStatus) = .empty;
        errdefer {
            for (next.items) |*e| e.deinit(a);
            next.deinit(a);
        }
        for (entries) |e| {
            const path = try a.dupe(u8, e.path);
            errdefer a.free(path);
            const orig: ?[]u8 = if (e.orig_path) |op| try a.dupe(u8, op) else null;
            errdefer if (orig) |o| a.free(o);
            try next.append(a, .{ .status = e.status, .path = path, .orig_path = orig });
        }
        for (self.detail_files.items) |*e| e.deinit(a);
        self.detail_files.deinit(a);
        self.detail_files = next;
    }

    /// H1: detail_owner_hash のセット（旧を free して dup）。
    pub fn setDetailOwnerHash(self: *Model, hash: []const u8) !void {
        const a = self.allocator;
        const new = try a.dupe(u8, hash);
        if (self.detail_owner_hash) |old| a.free(old);
        self.detail_owner_hash = new;
    }

    pub fn clearDetailOwner(self: *Model) void {
        const a = self.allocator;
        if (self.detail_owner_hash) |old| a.free(old);
        self.detail_owner_hash = null;
    }

    /// H1: detail_diff_owner のセット（hash と path 両方）。
    pub fn setDetailDiffOwner(self: *Model, hash: []const u8, path: []const u8) !void {
        const a = self.allocator;
        const new_hash = try a.dupe(u8, hash);
        errdefer a.free(new_hash);
        const new_path = try a.dupe(u8, path);
        errdefer a.free(new_path);
        if (self.detail_diff_owner_hash) |old| a.free(old);
        if (self.detail_diff_owner_path) |old| a.free(old);
        self.detail_diff_owner_hash = new_hash;
        self.detail_diff_owner_path = new_path;
    }

    pub fn clearDetailDiffOwner(self: *Model) void {
        const a = self.allocator;
        if (self.detail_diff_owner_hash) |old| a.free(old);
        if (self.detail_diff_owner_path) |old| a.free(old);
        self.detail_diff_owner_hash = null;
        self.detail_diff_owner_path = null;
    }

    /// R4: log_restore_hash のセット。
    pub fn setLogRestoreHash(self: *Model, hash: []const u8) !void {
        const a = self.allocator;
        const new = try a.dupe(u8, hash);
        if (self.log_restore_hash) |old| a.free(old);
        self.log_restore_hash = new;
    }

    pub fn clearLogRestoreHash(self: *Model) void {
        const a = self.allocator;
        if (self.log_restore_hash) |old| a.free(old);
        self.log_restore_hash = null;
    }

    /// phase 2: log_graph_state を新規 state へ置換（旧を deinit）。
    pub fn setLogGraphState(self: *Model, new_state: graph_mod.GraphState) void {
        self.log_graph_state.deinit(self.allocator);
        self.log_graph_state = new_state;
    }
    /// phase 2: log_graph_state を .invalid へ（旧を deinit）。
    pub fn invalidateLogGraph(self: *Model) void {
        self.log_graph_state.deinit(self.allocator);
        self.log_graph_state = .invalid;
    }
    /// phase 2: log_paging_tip をセット（旧を free して dup）。
    pub fn setLogPagingTip(self: *Model, hash: []const u8) !void {
        const a = self.allocator;
        const new = try a.dupe(u8, hash);
        if (self.log_paging_tip) |old| a.free(old);
        self.log_paging_tip = new;
    }
    /// phase 2: log_paging_tip をクリア。
    pub fn clearLogPagingTip(self: *Model) void {
        const a = self.allocator;
        if (self.log_paging_tip) |old| a.free(old);
        self.log_paging_tip = null;
    }

    /// 表示順の section ランク（staged が先頭、untracked が末尾）。
    fn sectionRank(s: status.Section) u8 {
        return switch (s) {
            .staged => 0,
            .unstaged => 1,
            .untracked => 2,
        };
    }

    /// 表示順比較: section ランク優先、同 section 内は path 昇順。
    fn lessThanForDisplay(_: void, a: FileItem, b: FileItem) bool {
        const ra = sectionRank(a.section);
        const rb = sectionRank(b.section);
        if (ra != rb) return ra < rb;
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

/// path のみが一致するエントリのうち、優先順位（unstaged > staged > untracked）で最も高いものの
/// index を返す。純粋・allocator 不要。Bug 2（部分 stage 後の選択追従）で replaceFiles が呼ぶ。
///
/// 呼び出し側は `found_path_only != null`（path に一致するエントリが少なくとも1つ存在）を保証して
/// 呼ぶため、本関数は常にヒットする。末尾の `return 0` は防御的フォールバックで、契約違反の呼出し
/// （path 一致エントリが無いのに呼んだ）時に index 0 へ退化して安全性を保つ。`unreachable` には
/// しない（一部のエッジで契約が崩れたときの安全側 / codex N3）。
///
/// 優先順位は sectionRank（staged=0 < unstaged=1 < untracked=2）とは**逆**（unstaged が先頭）。
/// sectionRank は表示順（staged が先頭）用で、選択追従の優先順位とは別物。混同しないよう個別定義。
fn selectByPathPriority(items: []const FileItem, path: []const u8) usize {
    const priorities = [_]status.Section{ .unstaged, .staged, .untracked };
    for (priorities) |sec| {
        for (items, 0..) |f, i| {
            if (f.section == sec and std.mem.eql(u8, f.path, path)) return i;
        }
    }
    // 防御的フォールバック（契約違反時）: index 0 へ退化。
    return 0;
}

/// 現在選択中のエントリが「rename の部分 stage 状態」（2 RM 等）かを純粋判定する。
/// true の条件（全て AND）:
///   1. files 非空 かつ selected が有効
///   2. selected エントリの section == .staged
///   3. selected エントリの orig_path != null（rename/copy 由来）
///   4. 同 path を持つ .unstaged エントリが files 内に存在（content modify がまだ残っている）
/// 条件 4 は 2 R.（rename+内容変更が両方 staged・完全 stage）と 2 RM（rename staged + content
/// modify unstaged）を区別する。view.renderDiff がメタ行表示の判定に使う。純粋・allocator 不要。
pub fn isRenamePartialState(model: *const Model) bool {
    if (model.files.items.len == 0) return false;
    if (model.selected >= model.files.items.len) return false;
    const cur = model.files.items[model.selected];
    if (cur.section != .staged) return false;
    if (cur.orig_path == null) return false;
    // 同 path の .unstaged エントリが存在するか
    for (model.files.items) |f| {
        if (f.section == .unstaged and std.mem.eql(u8, f.path, cur.path)) return true;
    }
    return false;
}

/// ビジュアル選択レンジ [lo, hi]（閉区間・絶対 diff 行 index）。anchor==null は単一カーソル行。
/// reducer（stage 対象）と view（ハイライト）が同一式から導き「見える選択 == stage 対象」を保つ。
pub fn selectionRange(cursor: usize, anchor: ?usize) struct { lo: usize, hi: usize } {
    const a = anchor orelse cursor;
    return .{ .lo = @min(cursor, a), .hi = @max(cursor, a) };
}

/// ヘルパ: Commit の deep-copy（R1: 各フィールド毎に errdefer で順次 rollback）。
fn cloneCommit(a: std.mem.Allocator, c: log_mod.Commit) !log_mod.Commit {
    var out: log_mod.Commit = undefined;
    out.hash = try a.dupe(u8, c.hash);
    errdefer a.free(out.hash);
    out.parents = try cloneStringSlice(a, c.parents);
    errdefer freeStringSlice(a, out.parents);
    out.author = try a.dupe(u8, c.author);
    errdefer a.free(out.author);
    out.subject = try a.dupe(u8, c.subject);
    errdefer a.free(out.subject);
    out.refs = try a.dupe(u8, c.refs);
    errdefer a.free(out.refs);
    out.epoch_sec = c.epoch_sec;
    return out;
}

fn cloneStringSlice(a: std.mem.Allocator, src: []const []u8) ![][]u8 {
    const out = try a.alloc([]u8, src.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |s| a.free(s);
        a.free(out);
    }
    for (src, 0..) |s, i| {
        out[i] = try a.dupe(u8, s);
        initialized = i + 1;
    }
    return out;
}

fn freeStringSlice(a: std.mem.Allocator, src: [][]u8) void {
    for (src) |s| a.free(s);
    a.free(src);
}

test "init/deinit leaves no leaks" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    try std.testing.expectEqualStrings("/tmp/repo", m.repo_root);
    try std.testing.expectEqual(Focus.changes, m.focus);
}

test "setStr frees old and stores new without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    try m.setStr(&m.diff_text, "diff A");
    try std.testing.expectEqualStrings("diff A", m.diff_text);
    try m.setStr(&m.diff_text, "diff B");
    try std.testing.expectEqualStrings("diff B", m.diff_text);
}

test "replaceFiles copies entries (caller still owns originals)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    const entries = try a.alloc(status.StatusEntry, 1);
    defer {
        a.free(entries[0].path);
        a.free(entries);
    } // 呼び出し側が originals を解放
    entries[0] = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged };
    try m.replaceFiles(entries); // Model は複製を持つ（二重 free しない）
    try std.testing.expectEqual(@as(usize, 1), m.files.items.len);
    try std.testing.expectEqualStrings("f.txt", m.files.items[0].path);
}

test "replaceFiles sorts by section (staged<unstaged<untracked) then path" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    // 入力は git 出力順を模した section interleave・path 不同順。
    const entries = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "z.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .untracked },
        .{ .path = try a.dupe(u8, "m.txt"), .orig_path = null, .section = .staged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (entries) |e| {
        a.free(e.path);
        if (e.orig_path) |p| a.free(p);
    };
    try m.replaceFiles(&entries);
    // 期待: staged(m) → unstaged(b, z 昇順) → untracked(a)。格納順 == 表示順。
    try std.testing.expectEqual(@as(usize, 4), m.files.items.len);
    try std.testing.expectEqualStrings("m.txt", m.files.items[0].path);
    try std.testing.expectEqual(status.Section.staged, m.files.items[0].section);
    try std.testing.expectEqualStrings("b.txt", m.files.items[1].path);
    try std.testing.expectEqualStrings("z.txt", m.files.items[2].path);
    try std.testing.expectEqual(status.Section.unstaged, m.files.items[2].section);
    try std.testing.expectEqualStrings("a.txt", m.files.items[3].path);
    try std.testing.expectEqual(status.Section.untracked, m.files.items[3].section);
}

test "replaceFiles preserves selection by (section, path) across refresh" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 初回: 3 ファイル（unstaged a, b, c）。選択を b（index 1）にする。
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "c.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    m.selected = 1; // b.txt
    // リフレッシュ: 先頭に新ファイル z(staged) が増え、表示順が変わる。b.txt は unstaged のまま。
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "z.txt"), .orig_path = null, .section = .staged },
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "c.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    // 選択は b.txt を追従しているべき（index ではなく path で維持）。
    try std.testing.expectEqualStrings("b.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.unstaged, m.files.items[m.selected].section);
}

test "replaceFiles falls back to index clamp when selected file is gone" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    m.selected = 1; // b.txt
    // b.txt が消えて a.txt だけ → b は見つからず、selected は新 len にクランプ（0）。
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    try std.testing.expectEqualStrings("a.txt", m.files.items[m.selected].path);
}

test "Model.diff_owner starts null and survives init/deinit (Layer 1 field)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expectEqual(@as(?DiffOwner, null), m.diff_owner);
}

test "setDiffOwner replaces and clearDiffOwner frees (Layer 1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setDiffOwner("f.txt", .unstaged);
    try std.testing.expectEqualStrings("f.txt", m.diff_owner.?.path);
    try std.testing.expectEqual(status.Section.unstaged, m.diff_owner.?.section);
    // 上書き（旧を free して新へ）
    try m.setDiffOwner("g.txt", .staged);
    try std.testing.expectEqualStrings("g.txt", m.diff_owner.?.path);
    try std.testing.expectEqual(status.Section.staged, m.diff_owner.?.section);
    // クリア
    m.clearDiffOwner();
    try std.testing.expectEqual(@as(?DiffOwner, null), m.diff_owner);
}

test "selectByPathPriority prefers unstaged over staged and untracked" {
    const a = std.testing.allocator;
    const path_f = try a.dupe(u8, "f.txt");
    defer a.free(path_f);
    const items = [_]FileItem{
        .{ .path = path_f, .orig_path = null, .section = .staged },
        .{ .path = path_f, .orig_path = null, .section = .unstaged },
        .{ .path = path_f, .orig_path = null, .section = .untracked },
    };
    try std.testing.expectEqual(@as(usize, 1), selectByPathPriority(&items, "f.txt"));
}

test "selectByPathPriority falls back to staged when no unstaged match" {
    const a = std.testing.allocator;
    const path_f = try a.dupe(u8, "f.txt");
    defer a.free(path_f);
    const path_g = try a.dupe(u8, "g.txt");
    defer a.free(path_g);
    const items = [_]FileItem{
        .{ .path = path_g, .orig_path = null, .section = .unstaged },
        .{ .path = path_f, .orig_path = null, .section = .staged },
        .{ .path = path_f, .orig_path = null, .section = .untracked },
    };
    try std.testing.expectEqual(@as(usize, 1), selectByPathPriority(&items, "f.txt")); // staged 優先
}

test "selectByPathPriority falls back to untracked when only untracked matches" {
    const a = std.testing.allocator;
    const path_f = try a.dupe(u8, "f.txt");
    defer a.free(path_f);
    const items = [_]FileItem{
        .{ .path = path_f, .orig_path = null, .section = .untracked },
    };
    try std.testing.expectEqual(@as(usize, 0), selectByPathPriority(&items, "f.txt"));
}

test "selectByPathPriority defensive fallback returns 0 on no match" {
    const a = std.testing.allocator;
    const path_g = try a.dupe(u8, "g.txt");
    defer a.free(path_g);
    const items = [_]FileItem{
        .{ .path = path_g, .orig_path = null, .section = .unstaged },
    };
    // "f.txt" は無いが契約違反呼出 → index 0 へ退化（クラッシュしない）
    try std.testing.expectEqual(@as(usize, 0), selectByPathPriority(&items, "f.txt"));
}

test "isRenamePartialState: 2 RM staged entry with unstaged sibling returns true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 RM 展開後: staged(new.txt, orig=old.txt) + unstaged(new.txt, orig=null)
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .staged,
    });
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = null,
        .section = .unstaged,
    });
    m.selected = 0; // staged 側を選択
    try std.testing.expect(isRenamePartialState(&m));
}

test "isRenamePartialState: 2 R. (full stage, no unstaged sibling) returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .staged,
    });
    // unstaged 兄弟無し（完全 stage）→ false
    m.selected = 0;
    try std.testing.expect(!isRenamePartialState(&m));
}

test "isRenamePartialState: 1 AM staged entry (orig_path null) returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{
        .path = try a.dupe(u8, "f.txt"),
        .orig_path = null,
        .section = .staged,
    });
    try m.files.append(a, .{
        .path = try a.dupe(u8, "f.txt"),
        .orig_path = null,
        .section = .unstaged,
    });
    m.selected = 0;
    try std.testing.expect(!isRenamePartialState(&m)); // orig_path null
}

test "isRenamePartialState: 2 .R unstaged entry returns false (section mismatch)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .unstaged,
    });
    m.selected = 0;
    try std.testing.expect(!isRenamePartialState(&m)); // section が unstaged
}

test "isRenamePartialState: empty files returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expect(!isRenamePartialState(&m));
}

test "Bug 2: partial stage of untracked follows selection to unstaged entry" {
    // untracked.txt 選択中 → 部分 stage で ? → 1 AM 展開。.unstaged 側へ追従すること。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();

    // 初回: untracked.txt のみ
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    try std.testing.expectEqualStrings("untracked.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.untracked, m.files.items[m.selected].section);

    // 部分 stage 後: 1 AM 展開で staged + unstaged の 2 エントリ + 別の untracked が残ったとする
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .staged },
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "other.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    // ★Bug 2 の核心: 同 path の .unstaged 側へ追従
    // 表示順ソート後: staged(untracked.txt) / unstaged(untracked.txt) / untracked(other.txt)
    //   → staged が先頭。完全一致 (untracked, "untracked.txt") は無し（section 変わった）。
    //   path-only フォールバック: unstaged 優先 → index 1。
    try std.testing.expectEqualStrings("untracked.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.unstaged, m.files.items[m.selected].section);
}

test "Bug 2: full stage of untracked follows selection to staged entry" {
    // untracked 完全 stage → unstaged 側は消え staged のみ残る → staged へ追従
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);

    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .staged },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    try std.testing.expectEqualStrings("f.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.staged, m.files.items[m.selected].section);
}

test "Model.log fields initialize to defaults (ViewMode=changes, empty log_commits)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expectEqual(ViewMode.changes, m.view_mode);
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.log_selected);
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_restore_hash);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
    try std.testing.expectEqual(DetailKind.files, m.detail_kind);
}

test "replaceLogCommits deep-copies entries and frees old (H6/R1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const log = @import("git/log.zig");
    const c = log.Commit{
        .hash = try a.dupe(u8, "h1"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a1"),
        .epoch_sec = 1,
        .subject = try a.dupe(u8, "s1"),
        .refs = try a.dupe(u8, ""),
    };
    defer {
        a.free(c.hash);
        a.free(c.parents);
        a.free(c.author);
        a.free(c.subject);
        a.free(c.refs);
    }
    try m.replaceLogCommits(&.{c});
    try std.testing.expectEqual(@as(usize, 1), m.log_commits.items.len);
    try std.testing.expectEqualStrings("h1", m.log_commits.items[0].hash);
    // Deep-copy: different memory from input
    try std.testing.expect(c.hash.ptr != m.log_commits.items[0].hash.ptr);
}

test "appendLogCommits deep-copies new entries to existing list (H6/R1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const log = @import("git/log.zig");
    const c1 = log.Commit{
        .hash = try a.dupe(u8, "h1"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a1"),
        .epoch_sec = 1,
        .subject = try a.dupe(u8, "s1"),
        .refs = try a.dupe(u8, ""),
    };
    try m.replaceLogCommits(&.{c1});
    defer {
        a.free(c1.hash);
        a.free(c1.parents);
        a.free(c1.author);
        a.free(c1.subject);
        a.free(c1.refs);
    }
    const c2 = log.Commit{
        .hash = try a.dupe(u8, "h2"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a2"),
        .epoch_sec = 2,
        .subject = try a.dupe(u8, "s2"),
        .refs = try a.dupe(u8, ""),
    };
    defer {
        a.free(c2.hash);
        a.free(c2.parents);
        a.free(c2.author);
        a.free(c2.subject);
        a.free(c2.refs);
    }
    try m.appendLogCommits(&.{c2});
    try std.testing.expectEqual(@as(usize, 2), m.log_commits.items.len);
    try std.testing.expectEqualStrings("h1", m.log_commits.items[0].hash);
    try std.testing.expectEqualStrings("h2", m.log_commits.items[1].hash);
}

test "setDetailOwnerHash / clearDetailOwner cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setDetailOwnerHash("abc");
    try std.testing.expectEqualStrings("abc", m.detail_owner_hash.?);
    try m.setDetailOwnerHash("def"); // free old abc, set new def
    try std.testing.expectEqualStrings("def", m.detail_owner_hash.?);
    m.clearDetailOwner();
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
}

test "setDetailDiffOwner / clearDetailDiffOwner cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setDetailDiffOwner("abc", "src/f.txt");
    try std.testing.expectEqualStrings("abc", m.detail_diff_owner_hash.?);
    try std.testing.expectEqualStrings("src/f.txt", m.detail_diff_owner_path.?);
    m.clearDetailDiffOwner();
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_diff_owner_hash);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_diff_owner_path);
}

test "setLogRestoreHash / clearLogRestoreHash cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setLogRestoreHash("h1");
    try std.testing.expectEqualStrings("h1", m.log_restore_hash.?);
    m.clearLogRestoreHash();
    try std.testing.expectEqual(@as(?[]u8, null), m.log_restore_hash);
}

// --- TODO 2 phase 2: graph state + paging tip helpers ---

test "Model.log_graph_state initializes to .invalid" {
    var m = try Model.init(std.testing.allocator, "/r");
    defer m.deinit();
    try std.testing.expect(m.log_graph_state == .invalid);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_paging_tip);
}

test "setLogPagingTip / clearLogPagingTip cycle without leak" {
    var m = try Model.init(std.testing.allocator, "/r");
    defer m.deinit();
    try m.setLogPagingTip("abc");
    try std.testing.expectEqualStrings("abc", m.log_paging_tip.?);
    try m.setLogPagingTip("def");
    try std.testing.expectEqualStrings("def", m.log_paging_tip.?);
    m.clearLogPagingTip();
    try std.testing.expectEqual(@as(?[]u8, null), m.log_paging_tip);
}
