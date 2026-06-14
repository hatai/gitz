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
        switch (self.*) {
            .status_loaded => |entries| {
                for (entries) |*e| {
                    a.free(e.path);
                    if (e.orig_path) |p| a.free(p);
                }
                a.free(entries);
            },
            .diff_loaded => |s| a.free(s),
            .git_error => |s| a.free(s),
            else => {},
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
    quit,

    pub const OwnedPath = struct { path: []u8, orig_path: ?[]u8, section: Section };
    pub const LoadDiff = struct { path: []u8, orig_path: ?[]u8, section: Section };

    pub fn deinit(self: *AppCmd, a: std.mem.Allocator) void {
        switch (self.*) {
            .stage, .unstage => |op| {
                a.free(op.path);
                if (op.orig_path) |p| a.free(p);
            },
            .load_diff => |ld| {
                a.free(ld.path);
                if (ld.orig_path) |p| a.free(p);
            },
            .commit => |m| a.free(m),
            else => {},
        }
    }
};

test "AppCmd.commit owns its message and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .commit = try a.dupe(u8, "hello") };
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("hello", cmd.commit);
}
