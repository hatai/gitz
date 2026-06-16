const std = @import("std");
const status = @import("git/status.zig");

pub const Focus = enum { changes, diff, commit };

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
    selected_hunk: usize, // diff ペインの現在ハンク（0始まり）。ファイル切替で 0、diff 再読込で clamp。
    commit_message: []u8, // TextArea の内容（空可）
    focus: Focus,
    busy: bool, // reducer の二重実行ゲート（全 in-flight 副作用で true）。表示はしない。
    working: bool, // スピナ表示用（変更系=stage/unstage/commit/apply_patch の実行中のみ true）。runtime が管理。
    error_text: []u8, // 直近エラー（空可）
    mouse_enabled: bool,

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
            .selected_hunk = 0,
            .commit_message = try a.dupe(u8, ""),
            .focus = .changes,
            .busy = false,
            .working = false,
            .error_text = try a.dupe(u8, ""),
            .mouse_enabled = true,
        };
    }

    pub fn deinit(self: *Model) void {
        const a = self.allocator;
        a.free(self.repo_root);
        a.free(self.branch);
        for (self.files.items) |*f| {
            a.free(f.path);
            if (f.orig_path) |p| a.free(p);
        }
        self.files.deinit(a);
        a.free(self.diff_text);
        a.free(self.commit_message);
        a.free(self.error_text);
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

        // 選択を (section, path) で復元（旧 files 解放前に照合）。見つからなければ index クランプにフォールバック。
        var new_selected: usize = self.selected;
        if (prev) |p| {
            for (next.items, 0..) |f, i| {
                if (f.section == p.section and std.mem.eql(u8, f.path, p.path)) {
                    new_selected = i;
                    break;
                }
            }
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
