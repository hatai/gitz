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
const graph_mod = @import("git/graph.zig");
const FilterSpec = @import("filter.zig").FilterSpec;

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };
pub const Layout = struct { changes: Rect, diff: Rect, commit: Rect, status: Rect };

/// phase 3a §8.1/MINOR5/m-N5: renderLogMode が参照する modal へのポインタ。
/// main.zig が毎フレーム render 呼出前に設定する（`g_program`/`g_app` と同パターン）。
/// `null` のとき（main 起動前等）は modal overlay を出さず base view を返す。
pub var g_view_modal: ?*const zz.Modal = null;

/// phase 3b §8.2: FilterSpec の conditions を walk して理由文字列を構築。
/// `Filter: author="..." since=... until=... paths=...` 形式。arena 確保・free 不要。
fn filterReasonText(a: std.mem.Allocator, filter: FilterSpec) []const u8 {
    if (filter.isEmpty()) return "";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    buf.appendSlice(a, "Filter:") catch return "Filter:";
    if (filter.getBranch()) |text| {
        const part = std.fmt.allocPrint(a, " branch=\"{s}\"", .{text}) catch return "Filter:";
        defer a.free(part);
        buf.appendSlice(a, part) catch return "Filter:";
    }
    if (filter.getAuthor()) |text| {
        const part = std.fmt.allocPrint(a, " author=\"{s}\"", .{text}) catch return "Filter:";
        defer a.free(part);
        buf.appendSlice(a, part) catch return "Filter:";
    }
    if (filter.getSince()) |text| {
        const part = std.fmt.allocPrint(a, " since={s}", .{text}) catch return "Filter:";
        defer a.free(part);
        buf.appendSlice(a, part) catch return "Filter:";
    }
    if (filter.getUntil()) |text| {
        const part = std.fmt.allocPrint(a, " until={s}", .{text}) catch return "Filter:";
        defer a.free(part);
        buf.appendSlice(a, part) catch return "Filter:";
    }
    const paths = filter.getPaths();
    if (paths.len > 0) {
        buf.appendSlice(a, " paths=") catch return "Filter:";
        for (paths, 0..) |p, idx| {
            if (idx > 0) buf.appendSlice(a, ",") catch return "Filter:";
            buf.appendSlice(a, p) catch return "Filter:";
        }
    }
    return buf.toOwnedSlice(a) catch "Filter:";
}

/// 共通ヘルパ（L3）: status 1 行確保・top の最低高さ 1・u16 clamp。
/// changes/log 両モードのレイアウト計算で共有する（極小端末でも underflow しない）。
/// 戻り値 `top_h` は status 以外の領域（changes モードなら changes+commit、log モードなら log+detail）。
/// 呼び出し側は top_h を commit/log/detail の高さ配分に使う。
fn computeTopAndStatus(w: u16, h: u16) struct { top_h: u16, status_h: u16 } {
    _ = w;
    const status_h: u16 = 1;
    // status(1) + top(最低1) = 最低2行を確保（top の内訳は呼び出し側で更に clamp）。
    const min_h: u16 = status_h + 1;
    const hh = if (h < min_h) min_h else h;
    return .{ .top_h = hh - status_h, .status_h = status_h };
}

/// 端末サイズから各ペインの矩形を決める純粋関数。
/// 左 40% を Changes、右 60% を Diff、下部 commit_h 行を Commit、最下行を status。
/// 極小端末でも underflow しないようにクランプする。
/// ★L3: status/height の基本計算は `computeTopAndStatus` を基にしつつ、commit 最低 1 行を
///   追加で保証する（changes モードは commit ペインが必須のため top 領域を更に commit と top で配分）。
pub fn computeLayout(w: u16, h: u16, commit_h_req: u16) Layout {
    // changes モードは status(1) + commit(最低1) + top(最低1) = 最低 3 行を確保する。
    // computeTopAndStatus は status+top の最低 2 行しか保証しないため、ここで追加の clamp を行う。
    const status_h: u16 = 1;
    const min_h: u16 = status_h + 1 + 1; // status + commit(最低1) + top(最低1) = 3
    const hh = if (h < min_h) min_h else h;
    const top_total: u16 = hh - status_h; // commit + changes/diff 用の top 領域
    var commit_h = commit_h_req;
    if (commit_h + 1 > top_total) commit_h = top_total - 1; // top 最低 1 行を残す
    const top_h: u16 = top_total - commit_h;
    // u16 乗算のオーバーフロー回避のため u32 で計算してから戻す。
    const left_w: u16 = if (w == 0) 0 else @intCast(@as(u32, w) * 40 / 100);
    const right_w: u16 = w - left_w;
    // status の y 座標は (top_h + commit_h) = top_total（hh - status_h と同義）。
    return .{
        .changes = .{ .x = 0, .y = 0, .w = left_w, .h = top_h },
        .diff = .{ .x = left_w, .y = 0, .w = right_w, .h = top_h },
        .commit = .{ .x = 0, .y = top_h, .w = w, .h = commit_h },
        .status = .{ .x = 0, .y = top_h + commit_h, .w = w, .h = status_h },
    };
}

// --- TODO 2 phase 1: log モードのレイアウト（spec §3.3） ---

/// log モードのレイアウト矩形。左 40% log、右 60% detail、下 status 1 行。
pub const LogLayout = struct { log: Rect, detail: Rect, status: Rect };

/// log モードのレイアウト（左 40% log、右 60% detail、下 status 1 行）。
/// ★L3: `computeTopAndStatus` を共有し、極小端末でも underflow しない。
pub fn computeLogLayout(w: u16, h: u16) LogLayout {
    const ts = computeTopAndStatus(w, h);
    const left_w: u16 = if (w == 0) 0 else @intCast(@as(u32, w) * 40 / 100);
    return .{
        .log = .{ .x = 0, .y = 0, .w = left_w, .h = ts.top_h },
        .detail = .{ .x = left_w, .y = 0, .w = w - left_w, .h = ts.top_h },
        .status = .{ .x = 0, .y = ts.top_h, .w = w, .h = ts.status_h },
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

// --- TODO 2 phase 1: log/detail ペインの行レイアウト（spec §3.5・changesRowLayout と同型） ---

/// log ペインの 1 行ぶんを表す。見出し行は無く全行がコミット行。`storage_index` は
/// `model.log_commits.items` の添字。input.fromZigzagMouseForLog がクリック行→index 解決に使う。
pub const LogRow = struct { storage_index: ?usize };

/// detail ファイル一覧の 1 行ぶんを表す。`storage_index` は `model.detail_files.items` の添字。
/// detail_kind == .files のときのみ意味を持つ（.diff では行数が変動するため未使用）。
pub const DetailRow = struct { storage_index: ?usize };

/// log ペインの表示行を列挙する純粋関数（見出し無し・全行がコミット行）。
/// 描画とマウス当たり判定の双方が共有しズレを防ぐ（changesRowLayout と同契約）。
/// row 配列を `out` に詰め、詰めた行数を返す（`out.len` で上限クランプ）。
pub fn logRowLayout(model: *const Model, out: []LogRow) usize {
    const n = @min(out.len, model.log_commits.items.len);
    for (0..n) |i| out[i] = .{ .storage_index = i };
    return n;
}

/// detail ファイル一覧の表示行を列挙する純粋関数。
/// detail_kind != .files のときは 0（diff ビューでは行レイアウトを使わない）。
pub fn detailRowLayout(model: *const Model, out: []DetailRow) usize {
    if (model.detail_kind != .files) return 0;
    const n = @min(out.len, model.detail_files.items.len);
    for (0..n) |i| out[i] = .{ .storage_index = i };
    return n;
}

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
/// focus==.diff のとき選択ハンクの @@ ヘッダ行を反転＋マーカー強調し、選択ハンクが画面
/// 掛かるよう model.diff_scroll を調整する（diff_scroll の writer は2箇所:
/// update.scroll_diff_down/up の行数クランプと、focus==.diff 時の renderDiff の ensureVisible）。
fn renderDiff(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.diff_text.len == 0) return "(no diff)";

    const add_style = zz.Style{ .foreground = zz.Color.green };
    const del_style = zz.Style{ .foreground = zz.Color.red };
    const sel_style = zz.Style{ .reverse_attr = true, .bold_attr = true };

    const limit: usize = if (height == 0) 1 else height;

    // 総行数。
    var total_lines: usize = 0;
    {
        var cit = std.mem.splitScalar(u8, model.diff_text, '\n');
        while (cit.next()) |_| total_lines += 1;
    }

    // focus==.diff のときカーソル行を可視範囲に収める（diff_scroll writer のうち renderDiff 側。
    // もう一方は update.scroll_diff_down/up の行数クランプ。ensureVisible はカーソルが窓の外なら
    // scroll を最小限ずらす（マウス当たり判定と一致）。
    if (model.focus == .diff) {
        model.diff_scroll = ensureVisible(model.diff_scroll, model.diff_cursor, limit);
    }
    const scroll_off = clampScroll(model.diff_scroll, total_lines);

    // 選択レンジ（reducer の stage 対象と同一式 → 見えている選択 == stage 対象）。
    // ハイライトは anchor 非 null のときだけ（anchor==null は単一行 = カーソルマーカーのみ）。
    const sel = @import("model.zig").selectionRange(model.diff_cursor, model.diff_anchor);

    var lines: std.ArrayList([]const u8) = .empty;

    // タスク B: rename+modify の部分 stage 状態（2 RM）で diff が new file mode になる誤認防止。
    // model.diff_text に触れず、描画時のみ先頭行へメタ行を差し込む（diffLineCount 不整合回避）。
    if (@import("model.zig").isRenamePartialState(model)) {
        const cur = model.files.items[model.selected];
        const orig = cur.orig_path orelse "";
        const meta = std.fmt.allocPrint(a, "[rename staged: {s} → {s} · content partial]", .{ orig, cur.path }) catch "[rename staged · content partial]";
        lines.append(a, meta) catch {};
    }

    var it = std.mem.splitScalar(u8, model.diff_text, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx < scroll_off) continue;
        if (lines.items.len >= limit) break;
        const is_cursor = (model.focus == .diff and idx == model.diff_cursor);
        const in_sel = (model.focus == .diff and model.diff_anchor != null and idx >= sel.lo and idx <= sel.hi);
        if (is_cursor) {
            const marked = std.fmt.allocPrint(a, "\u{258C}{s}", .{line}) catch line;
            lines.append(a, sel_style.render(a, marked) catch marked) catch break;
            continue;
        }
        if (in_sel) {
            // タスク A: anchor 非 null のとき範囲全体に `>` prefix + reverse（テキストダンプでも選択判別可能）。
            const prefixed = std.fmt.allocPrint(a, ">{s}", .{line}) catch line;
            lines.append(a, sel_style.render(a, prefixed) catch prefixed) catch break;
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

/// Status バー: branch / busy スピナ / error_text / フィルタインジケータ / キーヒント。
/// スピナは `model.working`（変更系操作の実行中のみ）で出す。`model.busy`（全 in-flight ゲート）では
/// 出さない＝自動リフレッシュ/ナビゲーションの読み取りでステータスバーが点滅しない。
/// タスク A: diff フォーカス + anchor 非 null のとき `[SELECT]` を先頭に表示（テキストダンプでも判別）。
/// phase 3a §8.2: log モードでフィルタ適用中は `[Filter: author="..."]` を表示。
/// phase 3a §8.3/B4: log モードで `log_load_error` が非空なら `(error) <text>` を表示。
fn renderStatus(model: *const Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    const branch = if (model.branch.len == 0) "(detached)" else model.branch;
    const spin = if (model.working) " [busy]" else "";
    const select_indicator: []const u8 = if (model.focus == .diff and model.diff_anchor != null)
        "[SELECT]  "
    else
        "";
    // phase 3a §8.2: log モードでフィルタ適用中はインジケータを表示。
    const filter_indicator: []const u8 = if (model.view_mode == .log and !model.filter_state.isEmpty()) blk: {
        const reason = filterReasonText(a, model.filter_state);
        const indicator = std.fmt.allocPrint(a, "[{s}]  ", .{reason}) catch "[Filter]  ";
        break :blk indicator;
    } else "";
    const hint_base = if (model.view_mode == .log)
        "j/k move  f filter  F clear  r refresh  L changes  q quit"
    else if (model.focus == .diff)
        "j/k line  v select  # hunk  H stage-hunk  s stage/unstage  ]/[ hunk  tab pane  r refresh  q quit"
    else
        "j/k move  space stage  c commit  r refresh  q quit";
    const hint = std.fmt.allocPrint(a, "{s}{s}{s}", .{ select_indicator, filter_indicator, hint_base }) catch hint_base;
    const base = std.fmt.allocPrint(a, " {s}{s}", .{ branch, spin }) catch " ?";
    // phase 3a §8.3/B4: log モードで log_load_error が非空なら優先表示。
    if (model.view_mode == .log and model.log_load_error.len > 0) {
        const err_style = zz.Style{ .foreground = zz.Color.red, .bold_attr = true };
        const err_text = std.fmt.allocPrint(a, "(error) {s}", .{model.log_load_error}) catch model.log_load_error;
        const err = err_style.render(a, err_text) catch err_text;
        return std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ base, err, hint }) catch base;
    }
    if (model.error_text.len > 0) {
        const err_style = zz.Style{ .foreground = zz.Color.red, .bold_attr = true };
        const err = err_style.render(a, model.error_text) catch model.error_text;
        return std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ base, err, hint }) catch base;
    }
    return std.fmt.allocPrint(a, "{s}  {s}", .{ base, hint }) catch base;
}

// --- TODO 2 phase 1: log/detail ペインの描画（spec §3.6） ---
//
// log モードは読み取り専用。stage/選択ハイライトは持たない（commit 行だけ reverse で選択表示）。
// detail は files/diff の 2 状態。files は `<status> <path>`（rename は `R old → new`）。
// diff は `+`/`-` 色分けのみ（選択ハイライト・カーソルマーカー無し・changes の renderDiff とは別物）。
// いずれも std.mem.join(a, "\n", ...) でプレーン改行結合し（★M9: zz.joinVertical は使わない）、
// 最後に fitPane でペイン幅/高さへクランプする（changes と同一の fitPane gotcha 適用）。

/// `epoch_sec`（1970-01-01 00:00:00 UTC からの秒）を `YYYY-MM-DD`（UTC）へ整形する純粋関数。
/// `std.time.epoch` API で年月日を計算（ローカルタイムゾーン非依存・UTC 固定）。
/// 失敗時はフォールバック文字列を返す（呼び出し側で deinit 不要・arena 想定）。
fn formatAuthorDateUTC(a: std.mem.Allocator, epoch_sec: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_sec) };
    const day = es.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, day.year),
        @as(u32, month_day.month.numeric()),
        @as(u32, month_day.day_index + 1),
    }) catch "????-??-??";
}

/// グラフレーンの 6 色ローテーション（Task 9）。レーン番号を色へ巡回割当てする。
const LANE_COLORS = [_]zz.Color{
    zz.Color.red, zz.Color.green, zz.Color.yellow,
    zz.Color.blue, zz.Color.magenta, zz.Color.cyan,
};

/// レーン番号 → 色（6 色で巡回）。`lane % LANE_COLORS.len` で飽和なく割当て。
fn laneColor(lane: u16) zz.Color {
    return LANE_COLORS[lane % LANE_COLORS.len];
}

/// 1 コミット分のグラフセルを ANSI 色付き文字列へ組み立てる（Task 9）。
/// 各セルは接続情報（up/down/left/right/is_node）から box-drawing 文字を選び、
/// レーン色（`laneColor`）で着色する。ノードは太字。`max_width` で列数をクランプ。
/// Phase 0 perf-tuning 計測用に pub 化（renderGraphCells の per-row alloc 負荷を bench から計測）。
/// Task 7（M7）で cache handle 化される際に再整理。
pub fn renderGraphCells(a: std.mem.Allocator, row: graph_mod.GraphRow, max_width: u16) []const u8 {
    if (max_width == 0) return "";
    var parts: std.ArrayList([]const u8) = .empty;
    const w: usize = @min(@as(usize, max_width), row.cells.len);
    for (row.cells[0..w], 0..) |cell, i| {
        const lane: u16 = @intCast(i);
        const ch: []const u8 = if (cell.is_node)
            "●"
        else if (cell.up and cell.down)
            "│"
        else if (cell.up and !cell.down)
            "╵"
        else if (!cell.up and cell.down)
            "╷"
        else if (cell.left and cell.right)
            "─"
        else if (cell.left and !cell.right)
            "╴"
        else if (cell.right and !cell.left)
            "╶"
        else
            " ";
        const style = zz.Style{ .foreground = laneColor(lane), .bold_attr = cell.is_node };
        const styled = style.render(a, ch) catch ch;
        parts.append(a, styled) catch {};
    }
    return std.mem.join(a, "", parts.items) catch "";
}

/// phase 3a §8.3/MINOR1/m-N1: 空結果の表示メッセージ種別を純粋に決定する。
/// log_load_error > filter 非空 > (no commits) の順で切り分け。
/// テスト可能な純粋関数として抽出（renderLog が zz.Context 依存のため決定ロジックだけ分離）。
pub const LogEmptyKind = enum { error_text, no_matching, no_commits };

pub fn logEmptyKind(model: *const Model) LogEmptyKind {
    if (model.log_load_error.len > 0) return .error_text;
    if (!model.filter_state.isEmpty()) return .no_matching;
    return .no_commits;
}

/// log ペインの描画（Task 9）。グラフセル + refs + short-hash + subject + author + UTC date を
/// ペイン幅に応じて段階的に表示する（M-13: responsive column omission）。選択行は reverse。
/// `log_scroll` からのウィンドウを描画し、選択が可視範囲に入るよう `log_scroll` を調整する
/// （changes の changes_scroll と同型・唯一の writer）。`pane_w` で列の出し入れを決める。
/// phase 3a §1.3/B2: `graph_render_policy==.suppressed` で graph 列を表示せず、代わりにメタ行を先頭へ。
/// phase 3a §8.3/MINOR1/m-N1: 空結果の表示を error/no matching/no commits で切り分け。
fn renderLog(model: *Model, ctx: *const zz.Context, height: u16, pane_w: u16) []const u8 {
    const a = ctx.allocator;
    if (model.log_commits.items.len == 0) {
        return switch (logEmptyKind(model)) {
            .error_text => std.fmt.allocPrint(a, "(error) {s}", .{model.log_load_error}) catch "(error)",
            .no_matching => "(no matching commits)",
            .no_commits => "(no commits)",
        };
    }

    const limit: usize = if (height == 0) 1 else height;
    const total = model.log_commits.items.len;

    // 選択（格納 index == visual row・見出し無し）が可視範囲に入るよう log_scroll を更新（唯一の writer）。
    model.log_scroll = ensureVisible(model.log_scroll, model.log_selected, limit);
    // log_scroll が末尾超過にならないようクランプ（行数が減ったケース）。
    if (model.log_scroll >= total) model.log_scroll = if (total == 0) 0 else total - 1;

    // M-13: ペイン幅に応じたレスポンシブな列省略。狭いペインではグラフ/author/date を順に省く。
    // phase 3a §1.3/B2: graph_render_policy==.suppressed なら graph 列を表示しない。
    const show_graph = pane_w >= 30 and model.log_graph_state == .valid and model.graph_render_policy == .auto;
    const show_date = pane_w >= 60;
    const show_author = pane_w >= 45;

    const graph_rows: ?[]const graph_mod.GraphRow = if (model.log_graph_state == .valid)
        model.log_graph_state.valid.rows.items
    else
        null;

    var lines: std.ArrayList([]const u8) = .empty; // arena なので deinit 不要

    // phase 3a §8.2/n-N3: フィルタ中で graph が非表示のとき、理由を行先頭へ表示。
    if (model.graph_render_policy == .suppressed and !model.filter_state.isEmpty()) {
        const reason = filterReasonText(a, model.filter_state);
        const meta = std.fmt.allocPrint(a, "{s} (graph hidden)", .{reason}) catch "Filter: (graph hidden)";
        lines.append(a, meta) catch {};
    }

    const start = model.log_scroll;
    const end = @min(total, start + limit);
    for (model.log_commits.items[start..end], start..) |c, i| {
        const selected = (i == model.log_selected);
        const short_hash = if (c.hash.len >= 7) c.hash[0..7] else c.hash;

        var parts: std.ArrayList([]const u8) = .empty;
        // グラフセル（グラフが有効かつペイン幅 >= 30 のとき先頭に描く）
        if (show_graph and graph_rows != null and i < graph_rows.?.len) {
            const graph_str = renderGraphCells(a, graph_rows.?[i], 20);
            parts.append(a, graph_str) catch {};
            parts.append(a, " ") catch {};
        }
        // refs（branch/tag 等の装飾）を hash の前に緑で描く
        if (c.refs.len > 0) {
            const refs_style = zz.Style{ .foreground = zz.Color.green };
            const refs_styled = refs_style.render(a, c.refs) catch c.refs;
            parts.append(a, refs_styled) catch {};
            parts.append(a, " ") catch {};
        }
        // short-hash
        parts.append(a, short_hash) catch {};
        parts.append(a, " ") catch {};
        // subject
        parts.append(a, c.subject) catch {};
        // author（ペイン幅 >= 45 のとき）
        if (show_author) {
            parts.append(a, " ") catch {};
            parts.append(a, c.author) catch {};
        }
        // UTC date（ペイン幅 >= 60 のとき）
        if (show_date) {
            parts.append(a, " ") catch {};
            const date_str = formatAuthorDateUTC(a, c.epoch_sec);
            parts.append(a, date_str) catch {};
        }

        const line = std.mem.join(a, "", parts.items) catch short_hash;
        if (selected) {
            const style = zz.Style{ .reverse_attr = true };
            const styled = style.render(a, line) catch line;
            lines.append(a, styled) catch {};
        } else {
            lines.append(a, line) catch {};
        }
    }
    if (lines.items.len == 0) return "(no commits)";
    // プレーン改行で結合（★M9: zz.joinVertical はパディングで短い行に "..." が付くため使わない）。
    return std.mem.join(a, "\n", lines.items) catch "(log render error)";
}

/// detail ペインの描画。`detail_kind` で files/diff を切替（spec §3.6 / §4）。
fn renderDetail(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    return switch (model.detail_kind) {
        .files => renderDetailFiles(model, ctx, height),
        .diff => renderDetailDiff(model, ctx, height),
    };
}

/// detail ファイル一覧の描画。`<status> <path>`（rename は `R old → new`、copy は `C old => new`）。
/// 選択行（`detail_selected`）は reverse で強調。`detail_scroll` からのウィンドウを描画し、
/// 選択が可視範囲に入るよう `detail_scroll` を調整する（changes/log と同型・唯一の writer）。
fn renderDetailFiles(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.detail_files.items.len == 0) return "(no files)";

    const limit: usize = if (height == 0) 1 else height;
    const total = model.detail_files.items.len;

    model.detail_scroll = ensureVisible(model.detail_scroll, model.detail_selected, limit);
    if (model.detail_scroll >= total) model.detail_scroll = if (total == 0) 0 else total - 1;

    var lines: std.ArrayList([]const u8) = .empty;
    const start = model.detail_scroll;
    const end = @min(total, start + limit);
    for (model.detail_files.items[start..end], start..) |e, i| {
        const selected = (i == model.detail_selected);
        const line: []const u8 = switch (e.status) {
            'R' => (std.fmt.allocPrint(a, "R {s} -> {s}", .{ e.orig_path orelse "?", e.path }) catch e.path),
            'C' => (std.fmt.allocPrint(a, "C {s} => {s}", .{ e.orig_path orelse "?", e.path }) catch e.path),
            else => (std.fmt.allocPrint(a, "{c} {s}", .{ e.status, e.path }) catch e.path),
        };
        if (selected) {
            const style = zz.Style{ .reverse_attr = true };
            const styled = style.render(a, line) catch line;
            lines.append(a, styled) catch {};
        } else {
            lines.append(a, line) catch {};
        }
    }
    if (lines.items.len == 0) return "(no files)";
    return std.mem.join(a, "\n", lines.items) catch "(detail render error)";
}

/// detail diff の描画。`+`/`-` 色分けのみ（選択ハイライト・カーソルマーカー無し・読み取り専用）。
/// `detail_diff_scroll` からのウィンドウを描画する。diff は changes の renderDiff とは別物
///（log は読み取り専用で stage 対象ではないため selection/anchor/cursor を持たない）。
fn renderDetailDiff(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.detail_diff.len == 0) return "(no diff)";

    const add_style = zz.Style{ .foreground = zz.Color.green };
    const del_style = zz.Style{ .foreground = zz.Color.red };

    const limit: usize = if (height == 0) 1 else height;

    // 総行数（changes renderDiff と同じ計算・trailing newline で空トークンが増える点も同一）。
    var total_lines: usize = 0;
    {
        var cit = std.mem.splitScalar(u8, model.detail_diff, '\n');
        while (cit.next()) |_| total_lines += 1;
    }
    const scroll_off = clampScroll(model.detail_diff_scroll, total_lines);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, model.detail_diff, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx < scroll_off) continue;
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
    return std.mem.join(a, "\n", lines.items) catch "(detail diff render error)";
}

/// 各ペインの内容を矩形 `r` のセル数に合わせて整形する。
/// - 高さ: `r.h` 行を超える行は捨てる（行単位なので ANSI を壊さない）。
/// - 幅: 各行を `r.w` 桁に**切り詰めてから** `zz.place.place` で `r.w` 桁に右パディングする。
///   切り詰めは `zz.measure.truncate`（ANSI エスケープを割らず、全角は 2 桁として計測）を使う。
///   ⚠️ これは表示崩れの根本対処: 切り詰めないと長い diff 行/パスがペイン幅を超え、
///   `joinHorizontal` 連結後に端末幅を超えてターミナルが行を折り返す。折り返しで各行が複数
///   物理行を占有し、フレーム全体が端末高を超えて上段がスクロールアウトする（実機で確認した
///   「上段が空白」の原因）。各行を幅に収めれば 1 論理行 = 1 物理行となり崩れない。
/// Phase 0 perf-tuning 計渜用に pub 化（fitPane の East Asian Width/truncate 負荷を bench から計測）。
pub fn fitPane(a: std.mem.Allocator, content: []const u8, r: Rect) []const u8 {
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
/// `view_mode` で分岐（spec §3.6）:
/// - `.changes`: 既存 4 矩形（changes / diff / commit / status）。`renderChangesMode` へ抽出。
/// - `.log`: log（左 40%）| detail（右 60%）の上段 + status（下 1 行）。`renderLogMode`。
/// いずれも `fitPane` で各ペインをセル数に整形してから結合する（separator 無し・幅超過折り返し防止）。
/// `model` は **`*Model`**（renderChanges/renderLog/renderDetailFiles が ensure-visible で
/// 各 scroll フィールドを更新する唯一の writer たちのため）。
pub fn render(model: *Model, ctx: *const zz.Context) []const u8 {
    return switch (model.view_mode) {
        .changes => renderChangesMode(model, ctx),
        .log => renderLogMode(model, ctx),
    };
}

/// changes モードの描画（既存の `render` 本体から抽出・spec §5 のレイアウト）。
/// `computeLayout` の 4 矩形（changes / diff / commit / status）を `fitPane` で整形して結合する。
fn renderChangesMode(model: *Model, ctx: *const zz.Context) []const u8 {
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

/// log モードの描画（spec §3.6）。log（左 40%）| detail（右 60%）の上段 + status（下 1 行）。
/// `computeLogLayout` の 3 矩形（log / detail / status）を `fitPane` で整形して結合する。
/// commit ペインは持たない（log モードは読み取り専用・コミット編集は changes モードのみ）。
/// phase 3a §8.1/MINOR5/m-N5: `filter_modal_open==true` のとき base view を返さず
/// `modal.viewWithBackdrop` を返す（全面 canvas・背景は見えない・overlay compositor は将来課題）。
fn renderLogMode(model: *Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;

    // phase 3a §8.1/MINOR5/m-N5: modal 表示中は base view を返さず viewWithBackdrop で全面置換。
    // 背景は見えない（backdrop が solid）。g_view_modal は main が render 呼出前に設定。
    if (model.filter_modal_open) {
        if (g_view_modal) |modal| {
            return modal.viewWithBackdrop(a, ctx.width, ctx.height) catch "(modal render error)";
        }
    }

    const layout = computeLogLayout(ctx.width, ctx.height);

    const log = fitPane(a, renderLog(model, ctx, layout.log.h, layout.log.w), layout.log);
    const detail = fitPane(a, renderDetail(model, ctx, layout.detail.h), layout.detail);
    const status = fitPane(a, renderStatus(model, ctx), layout.status);

    // 上段（Log | Detail）を横結合し、その下に Status を縦結合する（changes と同様に separator 無し）。
    const top = zz.joinHorizontal(a, &.{ log, detail }) catch log;
    return zz.joinVertical(a, &.{ top, status }) catch top;
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

// ====================== TODO 2 phase 1: log モードの純粋関数テスト ======================

test "computeTopAndStatus reserves 1 status row and keeps top >= 1" {
    // 通常サイズ: top_h = h - 1, status_h = 1。
    const ts1 = computeTopAndStatus(100, 30);
    try std.testing.expectEqual(@as(u16, 29), ts1.top_h);
    try std.testing.expectEqual(@as(u16, 1), ts1.status_h);
    // 極小 (h=1): min_h=2 へクランプ → top_h=1, status_h=1（top 最低 1 行を確保）。
    const ts2 = computeTopAndStatus(10, 1);
    try std.testing.expectEqual(@as(u16, 1), ts2.top_h);
    try std.testing.expectEqual(@as(u16, 1), ts2.status_h);
    // h=0: 同様に min_h=2 へ。
    const ts3 = computeTopAndStatus(10, 0);
    try std.testing.expectEqual(@as(u16, 1), ts3.top_h);
    try std.testing.expectEqual(@as(u16, 1), ts3.status_h);
}

test "computeLayout still produces same rectangles after computeTopAndStatus refactor (regression)" {
    // リファクタ前の既存テストと同一の期待値（回帰保護）。
    const l = computeLayout(100, 30, 5);
    try std.testing.expectEqual(@as(u16, 40), l.changes.w);
    try std.testing.expectEqual(@as(u16, 60), l.diff.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
    try std.testing.expectEqual(@as(u16, 5), l.commit.h);
    try std.testing.expectEqual(@as(u16, 24), l.changes.h); // top_h(29-5=24)
    // status は最下行: y = top_h + commit_h = 24 + 5 = 29。
    try std.testing.expectEqual(@as(u16, 29), l.status.y);
    // changes と diff の合計幅 == w。
    try std.testing.expectEqual(@as(u16, 100), @as(u16, l.changes.w + l.diff.w));
    // 高さの合計 == hh（ここでは h=30）。
    try std.testing.expectEqual(@as(u16, 30), @as(u16, l.changes.h + l.commit.h + l.status.h));
}

test "computeLayout clamps on tiny terminals without underflow (regression after refactor)" {
    // h=1 でも top/commit/status がそれぞれ最低 1 行を確保（min_h=2 → hh=2 → top と status で配分）。
    const l = computeLayout(10, 1, 5);
    try std.testing.expect(l.changes.h >= 1);
    try std.testing.expect(l.commit.h >= 1);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
}

test "computeLogLayout splits width 40/60 with status row at bottom" {
    const l = computeLogLayout(100, 30);
    try std.testing.expectEqual(@as(u16, 40), l.log.w);
    try std.testing.expectEqual(@as(u16, 60), l.detail.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
    // top_h = 29（status 1 行を引く）。
    try std.testing.expectEqual(@as(u16, 29), l.log.h);
    try std.testing.expectEqual(@as(u16, 29), l.detail.h);
    // status は最下行。
    try std.testing.expectEqual(@as(u16, 29), l.status.y);
    // log と detail の合計幅 == w。
    try std.testing.expectEqual(@as(u16, 100), @as(u16, l.log.w + l.detail.w));
    // 高さの合計 == h。
    try std.testing.expectEqual(@as(u16, 30), @as(u16, l.log.h + l.status.h));
}

test "computeLogLayout clamps on tiny terminals without underflow" {
    // h=1: min_h=2 へクランプ → top_h=1, status_h=1。
    const l = computeLogLayout(10, 1);
    try std.testing.expect(l.log.h >= 1);
    try std.testing.expect(l.detail.h >= 1);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
    try std.testing.expectEqual(@as(u16, 1), l.log.h); // top_h=1
}

test "computeLogLayout zero width yields zero pane widths" {
    const l = computeLogLayout(0, 30);
    try std.testing.expectEqual(@as(u16, 0), l.log.w);
    // detail は w - left_w = 0 - 0 = 0。
    try std.testing.expectEqual(@as(u16, 0), l.detail.w);
}

test "logRowLayout enumerates all commits as storage indices" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const log = @import("git/log.zig");
    // 3 コミットを一度に組み立てて replaceLogCommits（deep-copy）へ渡す。
    var commits: [3]log.Commit = undefined;
    inline for ([_][]const u8{ "h1", "h2", "h3" }, 0..) |h, i| {
        commits[i] = .{
            .hash = try a.dupe(u8, h),
            .parents = try a.alloc([]u8, 0),
            .author = try a.dupe(u8, "a"),
            .epoch_sec = 1,
            .subject = try a.dupe(u8, "s"),
            .refs = try a.dupe(u8, ""),
        };
    }
    defer for (&commits) |*c| c.deinit(a);
    try m.replaceLogCommits(&commits);

    var buf: [16]LogRow = undefined;
    const n = logRowLayout(&m, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(?usize, 0), buf[0].storage_index);
    try std.testing.expectEqual(@as(?usize, 1), buf[1].storage_index);
    try std.testing.expectEqual(@as(?usize, 2), buf[2].storage_index);
}

test "logRowLayout clamps to the provided output slice" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const log = @import("git/log.zig");
    var commits: [5]log.Commit = undefined;
    inline for ([_][]const u8{ "a", "b", "c", "d", "e" }, 0..) |h, i| {
        commits[i] = .{
            .hash = try a.dupe(u8, h),
            .parents = try a.alloc([]u8, 0),
            .author = try a.dupe(u8, "x"),
            .epoch_sec = 1,
            .subject = try a.dupe(u8, "s"),
            .refs = try a.dupe(u8, ""),
        };
    }
    defer for (&commits) |*c| c.deinit(a);
    try m.replaceLogCommits(&commits);

    var buf: [3]LogRow = undefined; // 3 件で打ち切り
    const n = logRowLayout(&m, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(?usize, 0), buf[0].storage_index);
    try std.testing.expectEqual(@as(?usize, 2), buf[2].storage_index);
}

test "logRowLayout on empty log returns 0" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var buf: [4]LogRow = undefined;
    try std.testing.expectEqual(@as(usize, 0), logRowLayout(&m, &buf));
}

test "detailRowLayout enumerates files when detail_kind is files" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.detail_kind = .files;
    const show = @import("git/show.zig");
    var entries: [3]show.NameStatus = undefined;
    entries[0] = .{ .status = 'M', .path = try a.dupe(u8, "f.txt"), .orig_path = null };
    entries[1] = .{ .status = 'A', .path = try a.dupe(u8, "g.txt"), .orig_path = null };
    entries[2] = .{ .status = 'D', .path = try a.dupe(u8, "h.txt"), .orig_path = null };
    defer for (&entries) |*e| e.deinit(a);
    try m.replaceDetailFiles(&entries);

    var buf: [16]DetailRow = undefined;
    const n = detailRowLayout(&m, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(?usize, 0), buf[0].storage_index);
    try std.testing.expectEqual(@as(?usize, 1), buf[1].storage_index);
    try std.testing.expectEqual(@as(?usize, 2), buf[2].storage_index);
}

test "detailRowLayout returns 0 when detail_kind is diff" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.detail_kind = .diff;
    // files があっても .diff では 0 を返す（行レイアウトを使わない）。
    const show = @import("git/show.zig");
    var entries: [1]show.NameStatus = undefined;
    entries[0] = .{ .status = 'M', .path = try a.dupe(u8, "f.txt"), .orig_path = null };
    defer entries[0].deinit(a);
    try m.replaceDetailFiles(&entries);

    var buf: [4]DetailRow = undefined;
    try std.testing.expectEqual(@as(usize, 0), detailRowLayout(&m, &buf));
}

test "detailRowLayout clamps to the provided output slice" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.detail_kind = .files;
    const show = @import("git/show.zig");
    var entries: [3]show.NameStatus = undefined;
    entries[0] = .{ .status = 'M', .path = try a.dupe(u8, "a"), .orig_path = null };
    entries[1] = .{ .status = 'M', .path = try a.dupe(u8, "b"), .orig_path = null };
    entries[2] = .{ .status = 'M', .path = try a.dupe(u8, "c"), .orig_path = null };
    defer for (&entries) |*e| e.deinit(a);
    try m.replaceDetailFiles(&entries);

    var buf: [2]DetailRow = undefined; // 2 件で打ち切り
    const n = detailRowLayout(&m, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "formatAuthorDateUTC: formats epoch to YYYY-MM-DD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2023-11-14 22:13:20 UTC = 1700000000
    const date = formatAuthorDateUTC(a, 1700000000);
    try std.testing.expectEqualStrings("2023-11-14", date);
}

// ====================== TODO 2 phase 3a: logEmptyKind / filter state tests ======================

test "logEmptyKind: no commits when no error and no filter" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expectEqual(LogEmptyKind.no_commits, logEmptyKind(&m));
}

test "logEmptyKind: no matching commits when filter active" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var spec = @import("filter.zig").FilterSpec.init();
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    m.setFilterState(spec);
    try std.testing.expectEqual(LogEmptyKind.no_matching, logEmptyKind(&m));
}

test "logEmptyKind: error_text takes priority over filter" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var spec = @import("filter.zig").FilterSpec.init();
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    m.setFilterState(spec);
    try m.setLogLoadError("HEAD 解決失敗");
    // error_text が最優先（フィルタ適用中でもエラー表示が上書き）
    try std.testing.expectEqual(LogEmptyKind.error_text, logEmptyKind(&m));
}

test "logEmptyKind: no_commits when filter empty even with error cleared" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setLogLoadError("");
    try std.testing.expectEqual(LogEmptyKind.no_commits, logEmptyKind(&m));
}

test "filterReasonText: branch only (phase 3b #1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = FilterSpec.init();
    defer spec.deinit(std.testing.allocator);
    try spec.addCondition(std.testing.allocator, .{ .branch = try std.testing.allocator.dupe(u8, "dev") });
    const out = filterReasonText(a, spec);
    try std.testing.expectEqualStrings("Filter: branch=\"dev\"", out);
}

test "filterReasonText: author only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = FilterSpec.init();
    defer spec.deinit(std.testing.allocator);
    try spec.addCondition(std.testing.allocator, .{ .author = try std.testing.allocator.dupe(u8, "foo") });
    const out = filterReasonText(a, spec);
    try std.testing.expectEqualStrings("Filter: author=\"foo\"", out);
}

test "filterReasonText: empty returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = FilterSpec.init();
    defer spec.deinit(std.testing.allocator);
    const out = filterReasonText(a, spec);
    try std.testing.expectEqualStrings("", out);
}

test "filterReasonText: all variants (phase 3b #1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = FilterSpec.init();
    defer spec.deinit(std.testing.allocator);
    try spec.addCondition(std.testing.allocator, .{ .branch = try std.testing.allocator.dupe(u8, "dev") });
    try spec.addCondition(std.testing.allocator, .{ .author = try std.testing.allocator.dupe(u8, "foo") });
    try spec.addCondition(std.testing.allocator, .{ .since = try std.testing.allocator.dupe(u8, "2026-06-01") });
    try spec.addCondition(std.testing.allocator, .{ .until = try std.testing.allocator.dupe(u8, "2026-06-30") });
    const paths = try std.testing.allocator.alloc([]u8, 1);
    paths[0] = try std.testing.allocator.dupe(u8, "src/");
    try spec.addCondition(std.testing.allocator, .{ .paths = paths });
    const out = filterReasonText(a, spec);
    try std.testing.expectEqualStrings("Filter: branch=\"dev\" author=\"foo\" since=2026-06-01 until=2026-06-30 paths=src/", out);
}

test {
    std.testing.refAllDecls(@This());
}
