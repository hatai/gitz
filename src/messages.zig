//! reducer の入出力。所有ペイロードは複製・`deinit` を持つ（spec §4「所有権規約」）。
//! zigzag 非依存。
const std = @import("std");
const status = @import("git/status.zig");
const Section = status.Section;
const Focus = @import("model.zig").Focus;

pub const Msg = union(enum) {
    key_down, // j / ↓
    key_up, // k / ↑
    toggle_stage, // space / s / ダブルクリック
    focus_next, // tab
    focus_commit, // c
    request_refresh, // r
    request_commit, // Ctrl+S
    scroll_diff_down, // Ctrl+d / ホイール下（diff ペイン）
    scroll_diff_up, // Ctrl+u / ホイール上（diff ペイン）
    diff_cursor_down, // diff フォーカス時 j / ↓（行カーソルを次の本文行へ）
    diff_cursor_up, // diff フォーカス時 k / ↑（行カーソルを前の本文行へ）
    diff_hunk_next, // diff フォーカス時 ]（次ハンク本文先頭へ）
    diff_hunk_prev, // diff フォーカス時 [（前ハンク本文先頭へ）
    toggle_line_selection, // diff フォーカス時 v（anchor のトグル）
    stage_lines, // diff フォーカス時 s / space / Enter（選択レンジを stage/unstage）
    select_hunk, // diff フォーカス時 # （現在ハンク本文全体を選択範囲へ）
    stage_hunk, // diff フォーカス時 H （現在ハンクを即 stage/unstage）
    select_line_at: usize, // diff クリックの絶対行（カーソルへ解決・anchor クリア）
    quit,
    select_index: usize, // マウスでファイル行クリック
    set_focus: Focus, // ペインクリックでフォーカス変更
    // commit テキスト編集自体は zigzag TextArea が正本（多行・カーソル・多バイトを担う）。
    // view が TextArea の現在値を毎フレーム同期する：
    commit_text_changed: []const u8, // TextArea の現在テキスト（借用: reducer が複製する）
    // 解釈器からの結果（所有: 複製済み）
    status_loaded: []status.StatusEntry,
    diff_loaded: []u8,
    git_error: []u8,
    committed,

    pub fn deinit(self: *Msg, a: std.mem.Allocator) void {
        // 網羅的 switch: 所有バリアントを追加したら必ずここに解放処理を書く
        // （else を使わないことでコンパイラが新バリアントの判断を強制する）。
        switch (self.*) {
            // 所有: 複製済みペイロードを解放する
            .status_loaded => |entries| {
                for (entries) |*e| {
                    a.free(e.path);
                    if (e.orig_path) |p| a.free(p);
                }
                a.free(entries);
            },
            .diff_loaded => |s| a.free(s),
            .git_error => |s| a.free(s),
            // 借用 / 単純: 解放不要（commit_text_changed は reducer 側が複製するため借用）
            .key_down,
            .key_up,
            .toggle_stage,
            .focus_next,
            .focus_commit,
            .request_refresh,
            .request_commit,
            .scroll_diff_down,
            .scroll_diff_up,
            .diff_cursor_down,
            .diff_cursor_up,
            .diff_hunk_next,
            .diff_hunk_prev,
            .toggle_line_selection,
            .stage_lines,
            .select_hunk,
            .stage_hunk,
            .select_line_at,
            .quit,
            .select_index,
            .set_focus,
            .commit_text_changed,
            .committed,
            => {},
        }
    }
};

pub const AppCmd = union(enum) {
    none,
    refresh_status,
    stage: OwnedPath,
    unstage: OwnedPath,
    load_diff: LoadDiff,
    commit: []u8, // 所有: メッセージ複製
    apply_patch: ApplyPatch,
    quit,

    pub const OwnedPath = struct { path: []u8, orig_path: ?[]u8, section: Section };
    pub const LoadDiff = struct { path: []u8, orig_path: ?[]u8, section: Section };
    /// 部分ステージング: 単一ハンクのパッチ（所有）と適用方向。
    /// reverse=false: stage（git apply --cached）。reverse=true: unstage（--reverse）。
    /// git_dir: 絶対 git-dir（worktree/submodule 対応）。null = フォールバック（cwd 相対 .git/...）。
    /// デフォルト null 必須: 既存の8箇所の `.{ .patch=..., .reverse=... }` リテラル呼出を壊さないため。
    pub const ApplyPatch = struct { patch: []u8, reverse: bool, git_dir: ?[]const u8 = null };

    pub fn deinit(self: *AppCmd, a: std.mem.Allocator) void {
        // 網羅的 switch: 所有バリアントを追加したら必ずここに解放処理を書く
        // （else を使わないことでコンパイラが新バリアントの判断を強制する）。
        switch (self.*) {
            // 所有: 複製済みペイロードを解放する
            .stage, .unstage => |op| {
                a.free(op.path);
                if (op.orig_path) |p| a.free(p);
            },
            .load_diff => |ld| {
                a.free(ld.path);
                if (ld.orig_path) |p| a.free(p);
            },
            .commit => |m| a.free(m),
            .apply_patch => |ap| {
                a.free(ap.patch);
                if (ap.git_dir) |g| a.free(g);
            },
            // 単純: 解放不要
            .none,
            .refresh_status,
            .quit,
            => {},
        }
    }
};

test "AppCmd.commit owns its message and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .commit = try a.dupe(u8, "hello") };
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("hello", cmd.commit);
}

test "AppCmd.apply_patch owns its patch and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .apply_patch = .{ .patch = try a.dupe(u8, "@@ -1 +1 @@\n-a\n+b\n"), .reverse = true } };
    defer cmd.deinit(a);
    try std.testing.expect(cmd.apply_patch.reverse);
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-a\n+b\n", cmd.apply_patch.patch);
}

// --- Msg.status_loaded: 複数要素 + orig_path 有無の混在を確保し deinit でリークなし ---

/// status_loaded 用フィクスチャを確保して Msg を組み立て、deinit で全解放する。
/// dupe が途中で OOM になっても確保済みスロットだけを正しく free する（errdefer）。
/// checkAllAllocationFailures から呼ぶことで部分確保失敗時の不正 free/leak を検証する。
fn buildStatusLoadedAndFree(a: std.mem.Allocator) !void {
    const entries = try a.alloc(status.StatusEntry, 3);
    // 確保途中で失敗した場合、初期化済みスロットの path/orig_path だけを解放する。
    // 各スロットは path を入れた直後に initialized を増やし、orig_path は
    // 先に null を入れてから上書きする（block errdefer が未初期化 orig_path を触らない）。
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*e| {
            a.free(e.path);
            if (e.orig_path) |p| a.free(p);
        }
        a.free(entries);
    }

    // 要素0: orig_path なし
    entries[0] = .{ .path = try a.dupe(u8, "src/main.zig"), .orig_path = null, .section = .unstaged };
    initialized = 1;

    // 要素1: orig_path あり（rename）
    entries[1] = .{ .path = try a.dupe(u8, "new.txt"), .orig_path = null, .section = .staged };
    initialized = 2;
    entries[1].orig_path = try a.dupe(u8, "old.txt");

    // 要素2: orig_path なし（untracked）
    entries[2] = .{ .path = try a.dupe(u8, "新規ファイル.txt"), .orig_path = null, .section = .untracked };
    initialized = 3;

    var msg = Msg{ .status_loaded = entries };
    msg.deinit(a); // deinit が slice と各 path/orig_path を所有・解放する
}

test "Msg.status_loaded deinit frees mixed entries without leak" {
    try buildStatusLoadedAndFree(std.testing.allocator);
}

test "Msg.status_loaded no invalid free / leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildStatusLoadedAndFree, .{});
}

test "Msg.diff_loaded deinit frees owned slice without leak" {
    const a = std.testing.allocator;
    var msg = Msg{ .diff_loaded = try a.dupe(u8, "diff --git a/x b/x\n") };
    msg.deinit(a);
}

test "Msg.git_error deinit frees owned slice without leak" {
    const a = std.testing.allocator;
    var msg = Msg{ .git_error = try a.dupe(u8, "fatal: boom") };
    msg.deinit(a);
}

// --- AppCmd: stage / unstage / load_diff の所有パスを deinit が解放する ---

test "AppCmd.stage deinit frees path and orig_path without leak" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .stage = .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .staged,
    } };
    cmd.deinit(a);
}

test "AppCmd.unstage deinit frees path with null orig_path without leak" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .unstage = .{
        .path = try a.dupe(u8, "f.txt"),
        .orig_path = null,
        .section = .staged,
    } };
    cmd.deinit(a);
}

test "AppCmd.load_diff deinit frees path and orig_path without leak" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .load_diff = .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .unstaged,
    } };
    cmd.deinit(a);
}
