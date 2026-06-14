//! 描画層（Task 10）。`Model` を zigzag の文字列組み立て API で
//! 2 ペイン + コミット欄 + ステータスバーに描く（spec §5 のレイアウト）。
//!
//! zigzag 依存のため:
//! - レイアウト矩形の計算（`computeLayout`）は **純粋関数** として TDD で単体テストする。
//! - 描画呼び出し（`render`）は zigzag 依存・自動 test なし。`test { refAllDecls }` で
//!   型検査だけ強制し、視覚的な確認は手動（非 tty では unverified）。
//!
//! 所有権/アロケータ規約（api-notes 準拠）:
//! - view が返す一時文字列はすべて `ctx.allocator`（フレーム arena）で確保する。
//! - ステートフルな TextArea は **この層では生成しない**。Task 11 のランタイムラッパが保持し、
//!   その内容を `Msg.commit_text_changed` 経由で `model.commit_message` に同期する。
//!   本層はキャッシュ済み `model.commit_message` を描く（編集カーソルは Task 11 が描く）。

const std = @import("std");
const zz = @import("zigzag");
const Model = @import("model.zig").Model;
const Focus = @import("model.zig").Focus;
const Section = @import("git/status.zig").Section;

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };
pub const Layout = struct { changes: Rect, diff: Rect, commit: Rect, status: Rect };

/// 端末サイズから各ペインの矩形を決める純粋関数。
/// 左 40% を Changes、右 60% を Diff、下部 commit_h 行を Commit、最下行を status。
/// 極小端末でも underflow しないようにクランプする。
pub fn computeLayout(w: u16, h: u16, commit_h_req: u16) Layout {
    const status_h: u16 = 1;
    // status(1) + commit(最低1) + top(最低1) = 最低3行を確保。
    const min_h: u16 = status_h + 1 + 1;
    const hh = if (h < min_h) min_h else h;
    var commit_h = commit_h_req;
    if (commit_h + status_h + 1 > hh) commit_h = hh - status_h - 1;
    const top_h: u16 = hh - commit_h - status_h;
    // u16 乗算のオーバーフロー回避のため u32 で計算してから戻す。
    const left_w: u16 = if (w == 0) 0 else @intCast(@as(u32, w) * 40 / 100);
    const right_w: u16 = w - left_w;
    return .{
        .changes = .{ .x = 0, .y = 0, .w = left_w, .h = top_h },
        .diff = .{ .x = left_w, .y = 0, .w = right_w, .h = top_h },
        .commit = .{ .x = 0, .y = top_h, .w = w, .h = commit_h },
        .status = .{ .x = 0, .y = hh - status_h, .w = w, .h = status_h },
    };
}

// --- zigzag 依存の描画ヘルパ（自動 test なし。型検査は refAllDecls 経由） ---

/// セクション見出しのラベル。
fn sectionTitle(s: Section) []const u8 {
    return switch (s) {
        .staged => "Staged",
        .unstaged => "Unstaged",
        .untracked => "Untracked",
    };
}

/// 1 ファイル行を組み立てる。`selected` のとき反転表示、rename は `old → new`。
/// `ctx.allocator`（フレーム arena）で確保する。失敗時はフォールバック文字列。
fn renderFileLine(
    ctx: *const zz.Context,
    item: anytype,
    selected: bool,
) []const u8 {
    const a = ctx.allocator;
    const label = if (item.orig_path) |orig|
        std.fmt.allocPrint(a, "  {s} \u{2192} {s}", .{ orig, item.path }) catch "  ?"
    else
        std.fmt.allocPrint(a, "  {s}", .{item.path}) catch "  ?";
    if (selected) {
        const style = zz.Style{ .reverse_attr = true };
        return style.render(a, label) catch label;
    }
    return label;
}

/// Changes ペイン: Staged / Unstaged / Untracked のセクション見出しと各ファイル行。
fn renderChanges(model: *const Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    var lines: std.ArrayList([]const u8) = .empty;
    // arena なので deinit 不要（フレーム終端でまとめて解放される）。

    const head_style = zz.Style{ .bold_attr = true };
    const sections = [_]Section{ .staged, .unstaged, .untracked };
    for (sections) |sec| {
        const title = head_style.render(a, sectionTitle(sec)) catch sectionTitle(sec);
        lines.append(a, title) catch return title;
        for (model.files.items, 0..) |f, i| {
            if (f.section != sec) continue;
            const sel = (i == model.selected) and (model.focus == .changes);
            lines.append(a, renderFileLine(ctx, f, sel)) catch {};
        }
    }
    if (lines.items.len == 0) return "(no changes)";
    return zz.joinVertical(a, lines.items) catch "(changes render error)";
}

/// Diff ペイン: `model.diff_text` を `model.diff_scroll` を先頭行として描画。`+`/`-` を色分け。
fn renderDiff(model: *const Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.diff_text.len == 0) return "(no diff)";

    const add_style = zz.Style{ .foreground = zz.Color.green };
    const del_style = zz.Style{ .foreground = zz.Color.red };

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, model.diff_text, '\n');
    var idx: usize = 0;
    const limit: usize = if (height == 0) 1 else height;
    while (it.next()) |line| : (idx += 1) {
        if (idx < model.diff_scroll) continue;
        if (lines.items.len >= limit) break;
        const styled: []const u8 = if (line.len > 0 and line[0] == '+')
            (add_style.render(a, line) catch line)
        else if (line.len > 0 and line[0] == '-')
            (del_style.render(a, line) catch line)
        else
            line;
        lines.append(a, styled) catch break;
    }
    if (lines.items.len == 0) return "";
    return zz.joinVertical(a, lines.items) catch "(diff render error)";
}

/// Commit ペイン: キャッシュ済み `model.commit_message` を描く。
/// `focus==.commit` のとき見出しを強調（編集カーソルは Task 11 のランタイムが TextArea で描く）。
fn renderCommit(model: *const Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    const focused = model.focus == .commit;
    const head_text = if (focused) "Commit message [Ctrl+S to commit]" else "Commit message";
    const head_style = zz.Style{ .bold_attr = true, .reverse_attr = focused };
    const head = head_style.render(a, head_text) catch head_text;
    const body = if (model.commit_message.len == 0) "(empty)" else model.commit_message;
    return std.fmt.allocPrint(a, "{s}\n{s}", .{ head, body }) catch head;
}

/// Status バー: branch / busy スピナ / error_text / キーヒント。
fn renderStatus(model: *const Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    const branch = if (model.branch.len == 0) "(detached)" else model.branch;
    const spin = if (model.busy) " [busy]" else "";
    const hint = "  j/k move  space stage  c commit  r refresh  q quit";
    const base = std.fmt.allocPrint(a, " {s}{s}", .{ branch, spin }) catch " ?";
    if (model.error_text.len > 0) {
        const err_style = zz.Style{ .foreground = zz.Color.red, .bold_attr = true };
        const err = err_style.render(a, model.error_text) catch model.error_text;
        return std.fmt.allocPrint(a, "{s}  {s}{s}", .{ base, err, hint }) catch base;
    }
    return std.fmt.allocPrint(a, "{s}{s}", .{ base, hint }) catch base;
}

/// `Model` を端末 1 画面分の文字列に描画する（zigzag view 規約: 非エラーの `[]const u8`）。
/// すべての一時文字列は `ctx.allocator`（フレーム arena）で確保し、内部の `!` は catch で
/// フォールバック文字列に落とす。Task 11 のランタイムがこれを `Model.view` から呼ぶ想定。
pub fn render(model: *const Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    const layout = computeLayout(ctx.width, ctx.height, 5);

    const changes = renderChanges(model, ctx);
    const diff = renderDiff(model, ctx, layout.diff.h);
    const commit = renderCommit(model, ctx);
    const status = renderStatus(model, ctx);

    // 上段（Changes | Diff）を横結合し、その下に Commit / Status を縦結合する。
    const top = zz.joinHorizontal(a, &.{ changes, "  ", diff }) catch changes;
    return zz.joinVertical(a, &.{ top, commit, status }) catch top;
}

test "layout splits width 40/60 and reserves commit+status rows" {
    const l = computeLayout(100, 30, 5);
    try std.testing.expectEqual(@as(u16, 40), l.changes.w);
    try std.testing.expectEqual(@as(u16, 60), l.diff.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
    try std.testing.expectEqual(@as(u16, 5), l.commit.h);
    // status は最下行
    try std.testing.expectEqual(@as(u16, 29), l.status.y);
}

test "layout clamps on tiny terminals without underflow" {
    // h が極小でも top/commit/status がそれぞれ最低 1 行を確保し、合計が破綻しない。
    const l = computeLayout(10, 1, 5);
    try std.testing.expect(l.changes.h >= 1);
    try std.testing.expect(l.commit.h >= 1);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
}

test "layout zero width yields zero panes" {
    const l = computeLayout(0, 30, 5);
    try std.testing.expectEqual(@as(u16, 0), l.changes.w);
    try std.testing.expectEqual(@as(u16, 0), l.diff.w);
}

test {
    std.testing.refAllDecls(@This());
}
