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
const hunk = @import("diff/hunk.zig");

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

/// Changes ペインの 1 行ぶんを表す。`storage_index` が null なら見出し行（クリック不可）、
/// 非 null なら `model.files.items[storage_index]` を指すファイル行。
/// view が「何行目に何を描くか」を決める唯一の真実源。Task 9 のマウス adapter は
/// クリック行 row を `changesRowLayout` に通して `storage_index` を引けば
/// `Msg.select_index` を正しく作れる（見出し行は null なので無視できる）。
pub const ChangesRow = struct { section: Section, storage_index: ?usize };

/// Changes ペインの行レイアウト（見出し + ファイル行）を**純粋に**列挙する。
/// 描画とマウス当たり判定の双方がこの 1 関数を共有することで、両者のズレを構造的に防ぐ。
/// row 配列を `out` に詰め、詰めた行数を返す（`out.len` で上限クランプ）。
///
/// ⚠️ クロスレイヤの seam（既知の制約・Task 10 単独では解消不可）:
///   ファイル行は section（staged→unstaged→untracked）でグルーピングして並べるが、
///   `model.files.items` の**格納順**は git porcelain v2 の出力順（path 順・section interleave）で
///   section ソートされていない（model.zig replaceFiles / git/status.zig parse 共にソート無し）。
///   一方 update.zig の key_down/key_up は `model.selected` を**格納順**で線形に動かす。
///   そのため格納順 != 表示順のとき、j/k のハイライトが画面上を非連続にジャンプする
///   （選択されるファイル自体は常に正しい。型/メモリのバグではなく振る舞い上の不整合）。
///   根本修正は本層の**外**: model.zig `replaceFiles` で `next` を section 優先
///   （staged→unstaged→untracked、その中で path）にソートしてから入れ替えれば、
///   格納順 == 表示順となり j/k 移動・ハイライト・本関数の row→index がすべて一致する
///   （`replaceFiles` の既存テストは単一エントリでソート不変、update.zig テストは addFile 経由で
///   replaceFiles 非依存のため、その 1 箇所のソート追加は既存 50 テストを壊さない）。
///   本関数はそのソート有無に関わらず正しい row→index を返す（ハイライトも格納 index で判定）。
pub fn changesRowLayout(model: *const Model, out: []ChangesRow) usize {
    const sections = [_]Section{ .staged, .unstaged, .untracked };
    var n: usize = 0;
    for (sections) |sec| {
        if (n >= out.len) break;
        out[n] = .{ .section = sec, .storage_index = null }; // 見出し行
        n += 1;
        for (model.files.items, 0..) |f, i| {
            if (f.section != sec) continue;
            if (n >= out.len) return n;
            out[n] = .{ .section = sec, .storage_index = i };
            n += 1;
        }
    }
    return n;
}

/// 選択行を可視範囲に収めるスクロールオフセットを返す純粋関数（Item 5: ensure-visible）。
/// `selected` は **visual row**（見出し含む表示行）、`visible` は表示可能行数（>=1 を渡すこと）。
/// 選択が上にはみ出すなら scroll=selected、下にはみ出すなら scroll=selected-visible+1。
pub fn ensureVisible(scroll: usize, selected: usize, visible: usize) usize {
    const vis = if (visible == 0) 1 else visible;
    if (selected < scroll) return selected;
    if (selected >= scroll + vis) return selected - vis + 1;
    return scroll;
}

/// Changes ペイン: Staged / Unstaged / Untracked のセクション見出しと各ファイル行。
/// `height` 行を超えた分は `model.changes_scroll` からのウィンドウとして描画する（Item 5）。0 のとき最低 1 行。
/// 行の並びは `changesRowLayout`（純粋・テスト済み）に委譲し、当たり判定とのズレを防ぐ。
///
/// ⚠️ Item 5 の一貫性不変条件: 本関数が **`model.changes_scroll` の唯一の writer**。マウス adapter
/// （input.fromZigzagMouse）は同フィールドを read するだけ。表示するオフセットと格納するオフセットが
/// 同一関数で確定するため、クリック行解決と描画ウィンドウが構造的にズレない。そのため引数は `*Model`。
fn renderChanges(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    var lines: std.ArrayList([]const u8) = .empty;
    // arena なので deinit 不要（フレーム終端でまとめて解放される）。

    const limit: usize = if (height == 0) 1 else height;
    const head_style = zz.Style{ .bold_attr = true };

    // 行レイアウトを arena に **全行** 確保（見出し 3 + ファイル数）。fold 下の selected も探せるよう
    // limit でクランプせず全展開してから、ensure-visible でウィンドウ先頭を決める。
    const cap = model.files.items.len + 3;
    const rows = a.alloc(ChangesRow, @max(cap, 1)) catch return "(changes render error)";
    const want = changesRowLayout(model, rows);

    // selected（格納 index）の **visual row** を探し、見えるよう changes_scroll を更新（唯一の writer）。
    if (model.files.items.len > 0) {
        for (rows[0..want], 0..) |row, vr| {
            if (row.storage_index) |i| {
                if (i == model.selected) {
                    model.changes_scroll = ensureVisible(model.changes_scroll, vr, limit);
                    break;
                }
            }
        }
    }
    // changes_scroll が末尾超過にならないようクランプ（行数が減ったケース）。
    if (model.changes_scroll >= want) model.changes_scroll = if (want == 0) 0 else want - 1;

    const start = model.changes_scroll;
    const end = @min(want, start + limit);
    for (rows[start..end]) |row| {
        if (row.storage_index) |i| {
            const f = model.files.items[i];
            const sel = (i == model.selected) and (model.focus == .changes);
            lines.append(a, renderFileLine(ctx, f, sel)) catch {};
        } else {
            const title = head_style.render(a, sectionTitle(row.section)) catch sectionTitle(row.section);
            lines.append(a, title) catch return title;
        }
    }
    if (lines.items.len == 0) return "(no changes)";
    // プレーン改行で結合する（zz.joinVertical は全行を最長行幅にパディングするため使わない）。
    // パディングは fitPane の place が担う。joinVertical を使うと短い行も最長行幅になり、
    // fitPane が全行をペイン幅に切り詰めて余計な "..." を付けてしまう。
    return std.mem.join(a, "\n", lines.items) catch "(changes render error)";
}

/// スクロールオフセットを総行数に対してクランプする純粋関数（Item 4: 末尾超過の空表示を防ぐ）。
/// 上限は「総行数 - 1」（最終行が先頭に来るまで）。total==0 なら 0（saturating sub）。
pub fn clampScroll(scroll: usize, total: usize) usize {
    if (total == 0) return 0;
    const max_off = total - 1;
    return @min(scroll, max_off);
}

/// Diff ペイン: `model.diff_text` を `model.diff_scroll` を先頭行として描画。`+`/`-` を色分け。
/// focus==.diff かつ hunk>0 のとき、選択ハンクの @@ ヘッダ行を反転＋マーカー強調し、
/// その行が可視範囲に入るよう `model.diff_scroll` を ensure-visible で書き戻す（diff_scroll の唯一 writer）。
fn renderDiff(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.diff_text.len == 0) return "(no diff)";

    const add_style = zz.Style{ .foreground = zz.Color.green };
    const del_style = zz.Style{ .foreground = zz.Color.red };
    const sel_style = zz.Style{ .reverse_attr = true, .bold_attr = true };

    const limit: usize = if (height == 0) 1 else height;

    // ハンク境界を取得（arena）。失敗時は空スライスでハイライト無しの従来描画にフォールバック。
    const parsed = hunk.parse(a, model.diff_text) catch hunk.ParsedDiff{ .file_header = "", .hunks = &[_]hunk.Hunk{} };
    const hunks = parsed.hunks;

    // 選択ハンクが可視になるよう diff_scroll を ensure-visible（focus==.diff かつ hunk>0 のときのみ）。
    var sel_header_line: ?usize = null;
    if (model.focus == .diff and hunks.len > 0) {
        const sel = @min(model.selected_hunk, hunks.len - 1);
        sel_header_line = hunks[sel].start_line;
        model.diff_scroll = ensureVisible(model.diff_scroll, hunks[sel].start_line, limit);
    }

    // 総行数で clamp（末尾超過の空表示を防ぐ）。`diff_scroll` の writer は上の ensureVisible、
    // 表示オフセットはこの clampScroll の二段（spec §11 の seam: Ctrl+d/u はハンク外で引き戻される）。
    var total_lines: usize = 0;
    {
        var cit = std.mem.splitScalar(u8, model.diff_text, '\n');
        while (cit.next()) |_| total_lines += 1;
    }
    const scroll_off = clampScroll(model.diff_scroll, total_lines);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, model.diff_text, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx < scroll_off) continue;
        if (lines.items.len >= limit) break;
        // 選択ハンクの @@ ヘッダ行は反転＋左マーカーで強調する。
        if (sel_header_line != null and idx == sel_header_line.?) {
            const marked = std.fmt.allocPrint(a, "\u{258C}{s}", .{line}) catch line;
            lines.append(a, sel_style.render(a, marked) catch marked) catch break;
            continue;
        }
        const styled: []const u8 = if (line.len > 0 and line[0] == '+')
            (add_style.render(a, line) catch line)
        else if (line.len > 0 and line[0] == '-')
            (del_style.render(a, line) catch line)
        else
            line;
        lines.append(a, styled) catch break;
    }
    if (lines.items.len == 0) return "";
    // プレーン改行で結合（zz.joinVertical の最長行パディングを避ける。理由は renderChanges 参照）。
    return std.mem.join(a, "\n", lines.items) catch "(diff render error)";
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

/// 各ペインの内容を矩形 `r` のセル数に合わせて整形する。
/// - 高さ: `r.h` 行を超える行は捨てる（行単位なので ANSI を壊さない）。
/// - 幅: 各行を `r.w` 桁に**切り詰めてから** `zz.place.place` で `r.w` 桁に右パディングする。
///   切り詰めは `zz.measure.truncate`（ANSI エスケープを割らず、全角は 2 桁として計測）を使う。
///   ⚠️ これは表示崩れの根本対処: 切り詰めないと長い diff 行/パスがペイン幅を超え、
///   `joinHorizontal` 連結後に端末幅を超えてターミナルが行を折り返す。折り返しで各行が複数
///   物理行を占有し、フレーム全体が端末高を超えて上段がスクロールアウトする（実機で確認した
///   「上段が空白」の原因）。各行を幅に収めれば 1 論理行 = 1 物理行となり崩れない。
fn fitPane(a: std.mem.Allocator, content: []const u8, r: Rect) []const u8 {
    // 高さクランプ: 先頭 r.h 行だけ残す（r.h==0 は 1 行に丸める）。
    const max_lines: usize = if (r.h == 0) 1 else r.h;
    var clamped = content;
    var nl_count: usize = 0;
    var cut: usize = content.len;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            nl_count += 1;
            if (nl_count == max_lines) {
                cut = i;
                break;
            }
        }
    }
    if (nl_count >= max_lines) clamped = content[0..cut];

    // 幅クランプ（上限）: 各行を r.w 桁に切り詰める。
    const w: usize = r.w;
    var tl: std.ArrayList([]const u8) = .empty; // arena なので deinit 不要
    var lit = std.mem.splitScalar(u8, clamped, '\n');
    while (lit.next()) |line| {
        if (zz.width(line) <= w) {
            tl.append(a, line) catch {};
        } else {
            const cut_line = zz.measure.truncate(a, line, w) catch line;
            // 切り詰めで閉じスタイル(ESC[0m)が落ちると色がパディングへ漏れるため reset を付す
            //（reset は表示幅 0 なので桁計算に影響しない）。
            const safe = std.fmt.allocPrint(a, "{s}\x1b[0m", .{cut_line}) catch cut_line;
            tl.append(a, safe) catch {};
        }
    }
    const fitted = if (tl.items.len == 0) clamped else (zz.joinVertical(a, tl.items) catch clamped);
    // 幅パディング（下限）: 切り詰め済みの各行を r.w 桁まで右パディング。
    return zz.place.place(a, r.w, max_lines, .left, .top, fitted) catch fitted;
}

/// `Model` を端末 1 画面分の文字列に描画する（zigzag view 規約: 非エラーの `[]const u8`）。
/// すべての一時文字列は `ctx.allocator`（フレーム arena）で確保し、内部の `!` は catch で
/// フォールバック文字列に落とす。Task 11 のランタイムがこれを `Model.view` から呼ぶ想定。
///
/// spec §5 のレイアウト適用: `computeLayout` が返す 4 矩形（changes / diff / commit / status）を
/// すべて `fitPane` で各ペインのセル数に整形してから結合する。これにより左 40% / 右 60% の
/// 横分割と上段の高さが実際に enforce される（separator は不要 — 各ペインが自前の右パディングを
/// 持つので join 時の隙間文字列を入れると合計幅が端末幅を超えて折り返す）。
/// 幅は下限保証（`fitPane` の注記参照）。
/// `model` は **`*Model`**（renderChanges が ensure-visible で `changes_scroll` を更新する唯一の
/// writer のため）。他の render ヘルパは `*const Model` のままで coerce される。
pub fn render(model: *Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    const layout = computeLayout(ctx.width, ctx.height, 5);

    const changes = fitPane(a, renderChanges(model, ctx, layout.changes.h), layout.changes);
    const diff = fitPane(a, renderDiff(model, ctx, layout.diff.h), layout.diff);
    const commit = fitPane(a, renderCommit(model, ctx), layout.commit);
    const status = fitPane(a, renderStatus(model, ctx), layout.status);

    // 上段（Changes | Diff）を横結合し、その下に Commit / Status を縦結合する。
    // 各ペインは fitPane で幅を確保済みなので separator は入れない（入れると幅超過で折り返す）。
    const top = zz.joinHorizontal(a, &.{ changes, diff }) catch changes;
    return zz.joinVertical(a, &.{ top, commit, status }) catch top;
}

test "ensureVisible scrolls to reveal selection above/below/within window" {
    // 上にはみ出す: scroll=5, selected=2 → scroll=2
    try std.testing.expectEqual(@as(usize, 2), ensureVisible(5, 2, 4));
    // 下にはみ出す: scroll=0, selected=10, visible=4 → 10-4+1 = 7
    try std.testing.expectEqual(@as(usize, 7), ensureVisible(0, 10, 4));
    // 範囲内: scroll=3, selected=4, visible=4（[3,7) に 4 が含まれる）→ 据え置き
    try std.testing.expectEqual(@as(usize, 3), ensureVisible(3, 4, 4));
    // 末尾ぴったり: scroll=3, selected=6, visible=4（[3,7) の最後）→ 据え置き
    try std.testing.expectEqual(@as(usize, 3), ensureVisible(3, 6, 4));
    // visible=0 は 1 に丸めて underflow しない
    try std.testing.expectEqual(@as(usize, 5), ensureVisible(0, 5, 0));
}

test "clampScroll caps offset at total-1 and handles empty" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(0, 0)); // 空
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 0)); // 空でも 0
    try std.testing.expectEqual(@as(usize, 3), clampScroll(3, 10)); // 範囲内は据え置き
    try std.testing.expectEqual(@as(usize, 9), clampScroll(100, 10)); // 超過は total-1 にクランプ
    try std.testing.expectEqual(@as(usize, 0), clampScroll(100, 1)); // 1 行なら先頭固定
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

// fitPane は本番では ctx.allocator（フレーム arena）で動き、中間確保はフレーム終端で
// まとめて解放される契約。テストもその契約に合わせ arena を渡す（中間確保を個別 free しない）。
test "fitPane clamps height to rect and pads each line to rect width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 4 行を高さ 3 の矩形に収める → 先頭 3 行のみ、各行 10 桁に右パディング。
    const out = fitPane(a, "ab\ncd\nef\ngh", .{ .x = 0, .y = 0, .w = 10, .h = 3 });
    var it = std.mem.splitScalar(u8, out, '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        try std.testing.expectEqual(@as(usize, 10), zz.width(line));
    }
    try std.testing.expectEqual(@as(usize, 3), n); // 3 行ちょうど（4 行目は捨てる）
}

test "fitPane truncates overlong lines to rect width (no overflow/wrap)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 幅 8 の矩形に長い行 → ペイン幅を超えないよう切り詰める（端末折り返し防止）。
    const out = fitPane(a, "hello world this is long", .{ .x = 0, .y = 0, .w = 8, .h = 1 });
    try std.testing.expectEqual(@as(usize, 8), zz.width(out));
}

test "fitPane truncates a styled overlong line without exceeding width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 40 桁の緑スタイル行を幅 10 に → ANSI を割らずに 10 桁へ収める。
    const styled = "\x1b[32m" ++ ("g" ** 40) ++ "\x1b[0m";
    const out = fitPane(a, styled, .{ .x = 0, .y = 0, .w = 10, .h = 1 });
    try std.testing.expectEqual(@as(usize, 10), zz.width(out));
}

test "changesRowLayout groups by section and maps rows back to storage indices" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 格納順 = porcelain v2 の path 順（section interleave）: A(unstaged) B(staged) C(unstaged)。
    try m.files.append(a, .{ .path = try a.dupe(u8, "A"), .orig_path = null, .section = .unstaged });
    try m.files.append(a, .{ .path = try a.dupe(u8, "B"), .orig_path = null, .section = .staged });
    try m.files.append(a, .{ .path = try a.dupe(u8, "C"), .orig_path = null, .section = .unstaged });

    var buf: [16]ChangesRow = undefined;
    const n = changesRowLayout(&m, &buf);
    // 期待される行: [Staged head][B=1][Unstaged head][A=0][C=2][Untracked head]
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expect(buf[0].section == .staged and buf[0].storage_index == null);
    try std.testing.expectEqual(@as(?usize, 1), buf[1].storage_index); // B
    try std.testing.expect(buf[2].section == .unstaged and buf[2].storage_index == null);
    try std.testing.expectEqual(@as(?usize, 0), buf[3].storage_index); // A
    try std.testing.expectEqual(@as(?usize, 2), buf[4].storage_index); // C
    try std.testing.expect(buf[5].section == .untracked and buf[5].storage_index == null);
    // クリック行 row=1 → 格納 index 1（B）に正しく解決でき、マウス adapter が select_index を作れる。
    try std.testing.expectEqual(@as(?usize, 1), buf[1].storage_index);
}

test "changesRowLayout clamps to the provided output slice" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{ .path = try a.dupe(u8, "A"), .orig_path = null, .section = .unstaged });
    var buf: [2]ChangesRow = undefined; // 見出し+1 行で打ち切り
    const n = changesRowLayout(&m, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
}

// 短い行と長い行が混在しても、短い行には省略記号が付かず、長い行だけが
// ペイン幅に切り詰められることを保証する回帰テスト（joinVertical パディング由来の
// 「全行 "..."」バグの再発防止）。
test "fitPane keeps short lines intact and only truncates long ones (no spurious ellipsis)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "short header\n" ++ ("x" ** 120);
    const out = fitPane(a, content, .{ .x = 0, .y = 0, .w = 20, .h = 5 });
    var it = std.mem.splitScalar(u8, out, '\n');
    const row0 = it.next().?;
    // 短い行は省略記号を含まない（末尾は空白パディング）。
    try std.testing.expect(std.mem.indexOf(u8, row0, "...") == null);
    try std.testing.expectEqual(@as(usize, 20), zz.width(row0));
    const row1 = it.next().?;
    // 長い行は 20 桁に収まる（切り詰め）。
    try std.testing.expectEqual(@as(usize, 20), zz.width(row1));
}

test {
    std.testing.refAllDecls(@This());
}
