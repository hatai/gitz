//! 純粋 reducer: `update(model, msg) -> AppCmd`。
//! Model を破壊的（in-place）に更新しつつ、副作用は AppCmd で表現する。
//! AppCmd ペイロードは Model から**複製**する（借用しない）。zigzag 非依存。
const std = @import("std");
const Model = @import("model.zig").Model;
const Focus = @import("model.zig").Focus;
const msgs = @import("messages.zig");
const Msg = msgs.Msg;
const AppCmd = msgs.AppCmd;
const status = @import("git/status.zig");
const hunk = @import("diff/hunk.zig");

/// Model を破壊的に更新し、必要な副作用を AppCmd で返す。
/// 返した AppCmd は呼び出し側（解釈器/テスト）が deinit する。
pub fn update(model: *Model, msg: Msg) !AppCmd {
    switch (msg) {
        .key_down => {
            if (model.selected + 1 < model.files.items.len) model.selected += 1;
            model.diff_scroll = 0;
            model.selected_hunk = 0;
            return loadDiffCmd(model);
        },
        .key_up => {
            if (model.selected > 0) model.selected -= 1;
            model.diff_scroll = 0;
            model.selected_hunk = 0;
            return loadDiffCmd(model);
        },
        .select_index => |i| {
            if (i < model.files.items.len) model.selected = i;
            model.focus = .changes;
            model.diff_scroll = 0;
            model.selected_hunk = 0;
            return loadDiffCmd(model);
        },
        .scroll_diff_down => {
            model.diff_scroll += 1;
            return .none;
        },
        .scroll_diff_up => {
            if (model.diff_scroll > 0) model.diff_scroll -= 1;
            return .none;
        },
        .focus_next => {
            model.focus = switch (model.focus) {
                .changes => .diff,
                .diff => .commit,
                .commit => .changes,
            };
            return .none;
        },
        .focus_commit => {
            model.focus = .commit;
            return .none;
        },
        .set_focus => |f| {
            model.focus = f;
            return .none;
        },
        .toggle_stage => {
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            const op = AppCmd.OwnedPath{
                .path = try model.allocator.dupe(u8, f.path),
                .orig_path = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null,
                .section = f.section,
            };
            // staged なら unstage、それ以外（unstaged/untracked）は stage
            return if (f.section == .staged) .{ .unstage = op } else .{ .stage = op };
        },
        .request_refresh => return .refresh_status,
        .request_commit => {
            // busy 中（直前の副作用が実行中）の Ctrl+S は無視する。二重コミットを防ぐ（基準7/UX）。
            if (model.busy) return .none;
            if (model.commit_message.len == 0) {
                try model.setStr(&model.error_text, "コミットメッセージが空です");
                return .none;
            }
            return .{ .commit = try model.allocator.dupe(u8, model.commit_message) };
        },
        // TextArea の現在値を Model にキャッシュ同期する（編集自体は TextArea が担う）。
        .commit_text_changed => |text| {
            try model.setStr(&model.commit_message, text);
            return .none;
        },
        .hunk_next => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (model.selected_hunk + 1 < parsed.hunks.len) model.selected_hunk += 1;
            return .none;
        },
        .hunk_prev => {
            if (model.selected_hunk > 0) model.selected_hunk -= 1;
            return .none;
        },
        .select_hunk_at_line => |line| {
            model.focus = .diff; // diff ペインクリックはフォーカスも移す
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            // 空 diff（0 ハンク）は selected_hunk を 0 に正規化（diff_loaded と同じ不変条件）。
            // 非空でクリックがどのハンクにも当たらない（file_header 等）場合は現状維持。
            if (parsed.hunks.len == 0) {
                model.selected_hunk = 0;
            } else if (hunk.hunkIndexForLine(parsed, line)) |i| {
                model.selected_hunk = i;
            }
            return .none;
        },
        .stage_hunk => {
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            if (f.section == .untracked) {
                try model.setStr(&model.error_text, "untracked はファイル単位で stage してください");
                return .none;
            }
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = @min(model.selected_hunk, parsed.hunks.len - 1);
            const patch = try hunk.buildPatch(model.allocator, parsed, idx);
            return .{ .apply_patch = .{ .patch = patch, .reverse = (f.section == .staged) } };
        },
        .diff_cursor_down => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            var total: usize = 0;
            var cit = std.mem.splitScalar(u8, model.diff_text, '\n');
            while (cit.next()) |_| total += 1;
            var n = model.diff_cursor + 1;
            while (n < total) : (n += 1) {
                if (isBodyLine(parsed, n)) {
                    model.diff_cursor = n;
                    break;
                }
            }
            return .none;
        },
        .diff_cursor_up => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            var n = model.diff_cursor;
            while (n > 0) {
                n -= 1;
                if (isBodyLine(parsed, n)) {
                    model.diff_cursor = n;
                    break;
                }
            }
            return .none;
        },
        .diff_hunk_next => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const cur = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const next = @min(cur + 1, parsed.hunks.len - 1);
            const h = parsed.hunks[next];
            model.diff_cursor = if (h.line_count > 1) h.start_line + 1 else h.start_line;
            model.diff_anchor = null;
            return .none;
        },
        .diff_hunk_prev => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const cur = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const prev = if (cur == 0) 0 else cur - 1;
            const h = parsed.hunks[prev];
            model.diff_cursor = if (h.line_count > 1) h.start_line + 1 else h.start_line;
            model.diff_anchor = null;
            return .none;
        },
        .toggle_line_selection => {
            model.diff_anchor = if (model.diff_anchor == null) model.diff_cursor else null;
            return .none;
        },
        .select_line_at => |line| {
            model.focus = .diff;
            model.diff_cursor = line;
            try clampCursor(model); // 本文外クリックはハンク本文へクランプ・anchor リセット
            return .none;
        },
        .stage_lines => {
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            if (f.section == .untracked) {
                try model.setStr(&model.error_text, "untracked はファイル単位で stage してください");
                return .none;
            }
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse return .none;
            const anchor = model.diff_anchor orelse model.diff_cursor;
            const lo = @min(model.diff_cursor, anchor);
            const hi = @max(model.diff_cursor, anchor);
            const maybe = try hunk.buildLinePatch(model.allocator, parsed, idx, lo, hi, f.section == .staged);
            if (maybe) |patch| {
                model.diff_anchor = null; // 選択消費
                return .{ .apply_patch = .{ .patch = patch, .reverse = (f.section == .staged) } };
            }
            try model.setStr(&model.error_text, "選択範囲に stage できる変更行がありません");
            return .none;
        },
        .quit => return .quit,
        // 解釈器からの結果
        .status_loaded => |entries| {
            model.busy = false;
            try model.replaceFiles(entries);
            return loadDiffCmd(model);
        },
        .diff_loaded => |text| {
            model.busy = false;
            try model.setStr(&model.diff_text, text);
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            model.selected_hunk = if (parsed.hunks.len == 0) 0 else @min(model.selected_hunk, parsed.hunks.len - 1);
            try clampCursor(model);
            return .none;
        },
        .git_error => |text| {
            model.busy = false;
            try model.setStr(&model.error_text, text);
            return .none;
        },
        .committed => {
            model.busy = false;
            try model.setStr(&model.commit_message, "");
            return .refresh_status;
        },
    }
}

/// diff 再読込/カーソル移動後にカーソルを本文行へ正規化し anchor をリセットする（純粋）。
/// - ハンク 0 個: cursor=0。
/// - カーソルが本文行でない（file_header / @@ ヘッダ行 / 範囲外）: 先頭ハンク本文先頭へ。
/// - 既にいずれかのハンク本文内: そのまま維持（リフレッシュ時のジャンプ防止）。
/// anchor は常に null へ（再読込/ファイル切替で選択は無効）。
fn clampCursor(model: *Model) !void {
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    model.diff_anchor = null;
    if (parsed.hunks.len == 0) {
        model.diff_cursor = 0;
        return;
    }
    // 本文行でない（@@ ヘッダ/file_header/範囲外）なら先頭ハンク本文先頭へ再配置
    // （spec: ヘッダクリックも本文へクランプ）。本文内ならジャンプ防止で維持。
    if (!isBodyLine(parsed, model.diff_cursor)) {
        const h0 = parsed.hunks[0];
        model.diff_cursor = if (h0.line_count > 1) h0.start_line + 1 else h0.start_line;
    }
}

/// 絶対行 `abs` が「本文行」（いずれかのハンク内 かつ @@ ヘッダ行でない）かを返す。
fn isBodyLine(parsed: hunk.ParsedDiff, abs: usize) bool {
    if (hunk.hunkIndexForLine(parsed, abs)) |i| return abs != parsed.hunks[i].start_line;
    return false;
}

/// 現在選択中のファイルの diff を読み込む AppCmd を返す。
/// ファイルが無ければ diff_text を空にして .none。
fn loadDiffCmd(model: *Model) !AppCmd {
    if (model.files.items.len == 0) {
        try model.setStr(&model.diff_text, "");
        return .none;
    }
    const f = model.files.items[model.selected];
    return .{ .load_diff = .{
        .path = try model.allocator.dupe(u8, f.path),
        .orig_path = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null,
        .section = f.section,
    } };
}

fn addFile(m: *Model, path: []const u8, section: status.Section) !void {
    try m.files.append(m.allocator, .{ .path = try m.allocator.dupe(u8, path), .orig_path = null, .section = section });
}

test "key_down moves selection within bounds" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "a", .unstaged);
    try addFile(&m, "b", .unstaged);
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    var c1 = try update(&m, .key_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected);
    var c2 = try update(&m, .key_down);
    c2.deinit(a); // 末尾で止まる
    try std.testing.expectEqual(@as(usize, 1), m.selected);
}

test "toggle_stage on unstaged returns stage cmd with copied path" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    var cmd = try update(&m, .toggle_stage);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .stage);
    try std.testing.expectEqualStrings("f.txt", cmd.stage.path);
}

test "request_commit with empty message sets error and no commit" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var cmd = try update(&m, .request_commit);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
}

test "commit_text_changed syncs TextArea value (incl. Japanese) and request_commit uses it" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // view が TextArea から同期してくる想定（多行・日本語も TextArea が編集済み）
    var c0 = try update(&m, .{ .commit_text_changed = "1行目\n2行目 日本語" });
    c0.deinit(a);
    try std.testing.expectEqualStrings("1行目\n2行目 日本語", m.commit_message);
    var c1 = try update(&m, .request_commit);
    defer c1.deinit(a);
    try std.testing.expect(c1 == .commit);
    try std.testing.expectEqualStrings("1行目\n2行目 日本語", c1.commit);
}

test "request_commit while busy returns none and emits no commit" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setStr(&m.commit_message, "msg"); // メッセージは非空（空エラーと区別する）
    m.busy = true;
    var cmd = try update(&m, .request_commit);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none); // busy ゲートで commit を発行しない
    try std.testing.expect(m.error_text.len == 0); // 空メッセージエラーでもない
}

test "key_down requests diff reload for new selection" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "a", .unstaged);
    try addFile(&m, "b", .unstaged);
    var cmd = try update(&m, .key_down);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_diff);
    try std.testing.expectEqualStrings("b", cmd.load_diff.path);
}

test "scroll_diff adjusts offset and clamps at zero" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var c1 = try update(&m, .scroll_diff_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.diff_scroll);
    var c2 = try update(&m, .scroll_diff_up);
    c2.deinit(a);
    var c3 = try update(&m, .scroll_diff_up);
    c3.deinit(a); // 0 で止まる
    try std.testing.expectEqual(@as(usize, 0), m.diff_scroll);
}

test "git_error preserves file list and only sets error_text/busy" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "a", .unstaged);
    try addFile(&m, "b", .unstaged);
    m.busy = true;
    var msg = Msg{ .git_error = try a.dupe(u8, "fatal: boom") };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.files.items.len); // ファイル一覧は保持
    try std.testing.expect(!m.busy);
    try std.testing.expectEqualStrings("fatal: boom", m.error_text);
}

// 2 ハンクを持つ unstaged diff を model に直接セットするヘルパ。
fn seedTwoHunkDiff(m: *Model) !void {
    const diff =
        "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n" ++
        "@@ -1,2 +1,2 @@\n a\n-b\n+B\n" ++ // @@ は行3
        "@@ -10,2 +10,3 @@\n x\n+Y\n z\n"; // @@ は行7
    try m.setStr(&m.diff_text, diff);
}

test "hunk_next/hunk_prev move within hunk count and clamp" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
    var c1 = try update(&m, .hunk_next);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected_hunk);
    var c2 = try update(&m, .hunk_next); // 末尾で止まる（2 ハンク）
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected_hunk);
    var c3 = try update(&m, .hunk_prev);
    c3.deinit(a);
    var c4 = try update(&m, .hunk_prev); // 0 で止まる
    c4.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
}

test "stage_hunk on unstaged returns apply_patch with reverse=false and selected hunk" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.selected_hunk = 1;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -10,2 +10,3 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -1,2 +1,2 @@") == null);
}

test "stage_hunk on staged sets reverse=true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .staged);
    try seedTwoHunkDiff(&m);
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(cmd.apply_patch.reverse);
}

test "stage_hunk on untracked is no-op with guidance message" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "new.txt", .untracked);
    try seedTwoHunkDiff(&m);
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
}

test "stage_hunk on rename (orig_path != null) is no-op with guidance message" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{ .path = try a.dupe(u8, "new.txt"), .orig_path = try a.dupe(u8, "old.txt"), .section = .staged });
    try seedTwoHunkDiff(&m);
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
}

test "stage_hunk while busy or with zero hunks returns none" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.busy = true;
    var c1 = try update(&m, .stage_hunk);
    c1.deinit(a);
    try std.testing.expect(c1 == .none);
    m.busy = false;
    try m.setStr(&m.diff_text, ""); // 0 ハンク
    var c2 = try update(&m, .stage_hunk);
    c2.deinit(a);
    try std.testing.expect(c2 == .none);
}

test "select_hunk_at_line resolves line to hunk; count==0 stays 0 (no underflow)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    // hunk1 の @@ 行は絶対行 7（header3 + hunk0[@@,a,-b,+B]=行3..6 → hunk1 @@ は行7）。
    var c1 = try update(&m, .{ .select_hunk_at_line = 7 });
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected_hunk);
    try std.testing.expectEqual(Focus.diff, m.focus);
    try m.setStr(&m.diff_text, ""); // 0 ハンクでも underflow しない
    var c2 = try update(&m, .{ .select_hunk_at_line = 5 });
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
}

test "file navigation resets selected_hunk; diff_loaded clamps it" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try addFile(&m, "g.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.selected_hunk = 1;
    var c1 = try update(&m, .key_down); // 別ファイルへ → 0 リセット
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
    m.selected_hunk = 5;
    var msg = Msg{ .diff_loaded = try a.dupe(u8, "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n") };
    defer msg.deinit(a); // diff_loaded は setStr で複製するため呼び出し側が原本を解放（所有権規約）
    var c2 = try update(&m, msg);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
}

// seedTwoHunkDiff の絶対行: file_header 0..2 / @@h0=3 ' a'4 '-b'5 '+B'6 / @@h1=7 ' x'8 '+Y'9 ' z'10
test "diff_cursor_down/up skip @@ headers and clamp to body lines" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 4; // h0 本文先頭 ' a'
    var c1 = try update(&m, .diff_cursor_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), m.diff_cursor); // '-b'
    m.diff_cursor = 6; // h0 末尾本文 '+B'
    var c2 = try update(&m, .diff_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor); // @@h1(7) を飛ばして ' x'(8)
    m.diff_cursor = 8;
    var c3 = try update(&m, .diff_cursor_up);
    c3.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // 戻りも @@h1 を飛ばす
}

test "diff_hunk_next/prev jump to hunk body tops and clear anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 4; // h0
    m.diff_anchor = 4;
    var c1 = try update(&m, .diff_hunk_next);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor); // h1 本文先頭
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
    var c2 = try update(&m, .diff_hunk_prev);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.diff_cursor); // h0 本文先頭
}

test "toggle_line_selection sets then clears anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    var c1 = try update(&m, .toggle_line_selection);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor);
    var c2 = try update(&m, .toggle_line_selection);
    c2.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "stage_lines on unstaged builds apply_patch for the cursor line and clears anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 6; // '+B'（h0 の変更行）
    m.diff_anchor = 6;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+B\n") != null);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択消費
}

test "stage_lines on staged sets reverse=true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .staged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 6;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(cmd.apply_patch.reverse);
}

test "stage_lines on context-only selection is no-op (null patch)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 4; // ' a' 文脈行のみ
    m.diff_anchor = null;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "stage_lines guards: untracked / busy" {
    const a = std.testing.allocator;
    {
        var m = try Model.init(a, "/r");
        defer m.deinit();
        try addFile(&m, "u.txt", .untracked);
        try seedTwoHunkDiff(&m);
        m.diff_cursor = 6;
        var c1 = try update(&m, .stage_lines);
        c1.deinit(a);
        try std.testing.expect(c1 == .none);
        try std.testing.expect(m.error_text.len > 0);
    }
    {
        var m = try Model.init(a, "/r");
        defer m.deinit();
        try addFile(&m, "f.txt", .unstaged);
        try seedTwoHunkDiff(&m);
        m.busy = true;
        var c2 = try update(&m, .stage_lines);
        c2.deinit(a);
        try std.testing.expect(c2 == .none);
    }
}

test "diff_loaded clamps cursor into a hunk body and resets anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.diff_cursor = 999;
    m.diff_anchor = 3;
    const diff = try a.dupe(u8, "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,1 +1,2 @@\n a\n+B\n");
    defer a.free(diff); // diff_loaded は setStr で複製するため呼び出し側が原本を解放（所有権規約）
    var cmd = try update(&m, .{ .diff_loaded = diff });
    cmd.deinit(a);
    // ヘッダ3行(0..2) / @@=3 / ' a'=4 / '+B'=5 → 範囲外 999 は先頭ハンク本文先頭(start_line+1=4) へ。
    try std.testing.expectEqual(@as(usize, 4), m.diff_cursor);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "select_line_at moves cursor, sets diff focus, clears anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_anchor = 4;
    var cmd = try update(&m, .{ .select_line_at = 9 }); // h1 '+Y'
    cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 9), m.diff_cursor);
    try std.testing.expect(m.focus == .diff);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}
