//! 入力正規化（Task 9）。zigzag の入力イベントを `Msg` に正規化する。
//!
//! 設計（spec §6: フォーカス時のキー捕捉）:
//! - **マッピング判断は純粋関数**（`keyToMsg` / `mouseToMsg` と幾何ヘルパ）にして単体テストする。
//! - zigzag イベント型からの取り出しだけ薄く zigzag 依存のアダプタ（`fromZigzagKey` /
//!   `fromZigzagMouse`）にする。`fromZigzagKey` は zigzag 依存・自動 test なし（`test { refAllDecls }`
//!   で型検査だけ強制、実イベント確認は Task 11 のヘッドレス/手動検証）。
//! - ⚠️ `fromZigzagMouse` は tty も Io も不要な純粋関数（`now_ms` は注入、`zz.MouseEvent` は素の struct）
//!   なので **behavioral test を持つ**（press/release/drag/move/右クリック/ホイールの分岐を検証）。
//!   mode 1003 で全マウスイベントが届く前提下で release/drag/move を `select_index`/`set_focus` に
//!   誤爆させないことを構造的に守るため、ここは refAllDecls だけに頼らない。
//!
//! ⚠️ 検証ゲートは `zig build test`（root_test.zig が本ファイルを import し、`test { refAllDecls }`
//!   で zigzag 依存アダプタも型検査される）。`zig build` は main.zig が Task 11 スタブで本ファイルを
//!   参照しないため、本ファイルの内容に関わらず green になり得る点に注意（view.zig と同じ前提）。

const std = @import("std");
const zz = @import("zigzag");
const Model = @import("model.zig").Model;
const Focus = @import("model.zig").Focus;
const ViewMode = @import("model.zig").ViewMode;
const DetailKind = @import("model.zig").DetailKind;
const Msg = @import("messages.zig").Msg;
const view = @import("view.zig");

/// 抽象化したキー（zigzag のキー型は `fromZigzagKey` でここに変換してから `keyToMsg` に渡す）。
pub const Key = union(enum) {
    char: u21, // 通常文字（コードポイント）
    enter,
    backspace,
    tab,
    shift_tab,
    escape,
    ctrl_s,
    ctrl_d,
    ctrl_u,
    down,
    up,
};

/// フォーカスを考慮してキー→Msg を決める純粋関数。
/// commit フォーカス時は編集キー以外のグローバルキーを無効化する（spec §6）。
pub fn keyToMsg(focus: Focus, key: Key) ?Msg {
    if (focus == .commit) {
        // 文字・改行・Backspace・カーソル移動は TextArea が処理する（null を返す＝グローバル命令ではない）。
        // これにより日本語入力中の `q` 等の誤爆を防ぐ（spec §6）。
        return switch (key) {
            .ctrl_s => .request_commit,
            .escape, .tab => .focus_next,
            else => null,
        };
    }
    if (focus == .diff) {
        return switch (key) {
            .char => |c| switch (c) {
                'j' => .diff_cursor_down,
                'k' => .diff_cursor_up,
                'v' => .toggle_line_selection,
                '#' => .select_hunk,
                'H' => .stage_hunk,
                ']' => .diff_hunk_next,
                '[' => .diff_hunk_prev,
                's', ' ' => .stage_lines,
                'c' => .focus_commit,
                'r' => .request_refresh,
                'q' => .quit,
                'L' => .toggle_view_mode,
                else => null,
            },
            .down => .diff_cursor_down,
            .up => .diff_cursor_up,
            .enter => .stage_lines,
            .tab => .focus_next,
            .ctrl_d => .scroll_diff_down,
            .ctrl_u => .scroll_diff_up,
            else => null,
        };
    }
    return switch (key) {
        .char => |c| switch (c) {
            'j' => .key_down,
            'k' => .key_up,
            's', ' ' => .toggle_stage,
            'c' => .focus_commit,
            'r' => .request_refresh,
            'q' => .quit,
            'L' => .toggle_view_mode,
            else => null,
        },
        .down => .key_down,
        .up => .key_up,
        .tab => .focus_next,
        .ctrl_d => .scroll_diff_down,
        .ctrl_u => .scroll_diff_up,
        else => null,
    };
}

pub const MouseEvent = struct {
    /// `ignore` = アクション無し（reducer に渡さない）。zigzag は mouse mode 1003 で
    /// press/release/drag/move を全部報告するため（zig-pkg .../terminal.zig:336 が
    /// "\x1b[?1003h\x1b[?1006h" を書く）、左クリックの release や bare motion を
    /// `left_click` に潰すと select_index/set_focus が誤爆する。これらは `ignore` にする。
    /// デフォルト .ignore 必須（制約5: base リテラルが kind 省略で組めるようにするため）。
    kind: enum { left_click, left_double, wheel_up, wheel_down, ignore } = .ignore,
    /// クリックされたペイン（フォーカス変更に使う。null=どのペイン外でもない）
    pane: ?Focus = null,
    /// ファイル一覧ペイン内で計算済みの**格納インデックス**（`Model.files.items` の添字）。
    /// 見出し行・ペイン外は null。`mouseToMsg` はこれを `select_index` にそのまま使う。
    file_row: ?usize = null,
    /// diff ペイン上のイベントか（ホイール対象判定）
    on_diff: bool = false,
    /// diff ペインクリック時の **絶対 diff 行番号**（diff_scroll + ペイン相対行）。null=diff 外。
    diff_line: ?usize = null,
    // --- TODO 2 phase 1: log/detail ビューのマウスヒットテスト結果 ---
    /// log ペイン内の格納インデックス（`Model.log_commits.items` の添字）。null=log 外/見出し。
    log_row: ?usize = null,
    /// detail ファイル一覧内の格納インデックス（`Model.detail_files.items` の添字）。
    detail_row: ?usize = null,
    /// log ペイン上のイベントか（ホイール対象判定）。
    on_log: bool = false,
    /// detail ペイン上のイベントか（ホイール対象判定）。
    on_detail: bool = false,
    /// detail diff ペイン上のイベントか（ホイール対象判定・将来拡張用）。
    on_detail_diff: bool = false,
};

pub fn mouseToMsg(ev: MouseEvent) ?Msg {
    return switch (ev.kind) {
        // ファイル行クリック→選択（reducer 側で focus も changes に移る）。
        // ファイル行以外のペインクリック→そのペインへフォーカス。
        .left_click => if (ev.file_row) |r|
            .{ .select_index = r }
        else if (ev.diff_line) |dl|
            .{ .select_line_at = dl }
        else if (ev.pane) |p|
            .{ .set_focus = p }
        else
            null,
        .left_double => if (ev.file_row != null) .toggle_stage else null,
        .wheel_down => if (ev.on_diff) .scroll_diff_down else null,
        .wheel_up => if (ev.on_diff) .scroll_diff_up else null,
        // press 以外のマウスイベント（release/drag/move）と非左/非ホイールボタンは無視。
        .ignore => null,
    };
}

// ====================== TODO 2 phase 1: ViewMode 別入力ルーティング ======================
//
// 既存 `keyToMsg`/`mouseToMsg` は changes ビュー専用（regression 安全）。本節は **ViewMode 別**
// の新エントリポイントを追加し、mode==.changes は既存関数へ delegating、mode==.log は log 専用
// のキーマップ/マウスルーティングを返す。`fromZigzagMouseForMode`（log レイアウトでヒットテスト
// する wrapper）は view.LogLayout が存在しないため Task 9/10 で追加する（本タスクの対象外）。

/// `ViewMode` 別にキー→Msg を決めるエントリポイント。
/// ★H7: 既存 `keyToMsg` は変更せず、mode==.changes のときは delegating する（回帰安全）。
/// ★R25: detail_kind 引数追加。focus==.diff（detail 右ペイン）の detail が files/diff で
///   キー割当を変えるため。focus==.changes（log 左ペイン）では detail_kind を無視。
pub fn keyToMsgForMode(mode: ViewMode, focus: Focus, detail_kind: DetailKind, key: Key) ?Msg {
    return switch (mode) {
        .changes => keyToMsg(focus, key), // 既存へ delegating（detail_kind は無視）
        .log => keyToMsgForLog(focus, detail_kind, key),
    };
}

/// phase 3a §7.1/M6: modal visible を前判定するエントリポイント。
/// `filter_modal_open==true` のとき、Escape → `.close_filter_modal`・それ以外（Enter 含む）→ null。
/// Enter の場合は main が TextInput.getValue を dupe して `Msg.apply_filter` payload を構築する
/// （input 関数は tag のみ返す設計だと Zig の tagged union で payload 無しの apply_filter が作れないため、
/// null で main へ委譲・M-N7 解決）。q/r/L/tab 等 global mapping も抑制（null を返す）。
pub fn keyToMsgForModeWithModal(
    mode: ViewMode,
    focus: Focus,
    detail_kind: DetailKind,
    key: Key,
    filter_modal_open: bool,
) ?Msg {
    if (filter_modal_open) {
        return switch (key) {
            .escape => .close_filter_modal,
            .tab => .filter_focus_next,
            .shift_tab => .filter_focus_prev,
            else => null,
        };
    }
    return keyToMsgForMode(mode, focus, detail_kind, key);
}

/// log ビューのキーマップ（spec §3.4）。
/// - L/q/r/tab は focus/detail_kind に関わらずグローバル。
/// - focus==.changes（左: log ペイン）: j/k/↓/↑ で log_cursor、Enter/Space で log_open_detail、
///   Ctrl+d/u で log_scroll。
/// - focus==.diff（右: detail ペイン）: detail_kind で files/diff を切替。
///   files: j/k で detail_cursor、Enter で select、Ctrl+d/u で files_scroll。
///   diff: j/k/Ctrl+d/u で diff_scroll、Esc/Backspace/u で back_to_files、Enter は no-op。
/// changes 系キー（s/space で stage、c commit、v/#/H 選択）は log mode では未割当（null）。
fn keyToMsgForLog(focus: Focus, detail_kind: DetailKind, key: Key) ?Msg {
    // L/q/r はグローバル（focus/detail_kind に依存しない）。tab も focus_next でグローバル。
    switch (key) {
        .char => |c| {
            if (c == 'L') return .toggle_view_mode;
            if (c == 'q') return .quit;
            if (c == 'r') return .request_refresh;
        },
        .tab => return .focus_next,
        else => {},
    }

    if (focus == .changes) {
        // 左: log ペイン
        return switch (key) {
            .char => |c| switch (c) {
                'j' => .log_cursor_down,
                'k' => .log_cursor_up,
                ' ' => .log_open_detail, // space は fromZigzagKey で char=' ' に正規化済み
                'f' => .open_filter_modal, // phase 3a: 作者フィルタモーダルを開く
                'F' => .clear_filter, // phase 3a: フィルタ解除（shift-f）
                else => null,
            },
            .down => .log_cursor_down,
            .up => .log_cursor_up,
            .enter => .log_open_detail,
            .ctrl_d => .log_scroll_down,
            .ctrl_u => .log_scroll_up,
            else => null,
        };
    }

    // focus == .diff: 右: detail ペイン。detail_kind で files/diff を切替。
    return switch (detail_kind) {
        .files => switch (key) {
            .char => |c| switch (c) {
                'j' => .detail_cursor_down,
                'k' => .detail_cursor_up,
                else => null,
            },
            .down => .detail_cursor_down,
            .up => .detail_cursor_up,
            .enter => .detail_select_file,
            .ctrl_d => .detail_files_scroll_down,
            .ctrl_u => .detail_files_scroll_up,
            // Esc/Backspace/u in .files は no-op（既に files ビューにいる）
            else => null,
        },
        .diff => switch (key) {
            .char => |c| switch (c) {
                'j' => .detail_diff_scroll_down,
                'k' => .detail_diff_scroll_up,
                'u' => .detail_back_to_files,
                else => null,
            },
            .down => .detail_diff_scroll_down,
            .up => .detail_diff_scroll_up,
            .enter => null, // diff ビューでは no-op
            .escape, .backspace => .detail_back_to_files,
            .ctrl_d => .detail_diff_scroll_down,
            .ctrl_u => .detail_diff_scroll_up,
            else => null,
        },
    };
}

/// `ViewMode` 別にマウスイベント→Msg を決めるエントリポイント。
/// ★H7: 既存 `mouseToMsg` は変更せず、mode==.changes のときは delegating する（回帰安全）。
/// ★R24: ホイールは scroll 系のみ（cursor 移動はしない・1 Msg 制約）。
/// ★R25: detail_kind 引数で files/diff の scroll 先を切り替え。
pub fn mouseToMsgForMode(mode: ViewMode, ev: MouseEvent, detail_kind: DetailKind) ?Msg {
    return switch (mode) {
        .changes => mouseToMsg(ev), // 既存へ delegating
        .log => mouseToMsgForLog(ev, detail_kind),
    };
}

/// log ビューのマウスルーティング（spec §3.5）。
/// - left_click: log_row → log_select_index、detail_row → detail_select_index、
///   それ以外は pane → set_focus。
/// - wheel_down/up: on_log → log_scroll、on_detail → detail_kind で files/diff の scroll。
/// - left_double は phase 1 では stage 無しのため no-op。
fn mouseToMsgForLog(ev: MouseEvent, detail_kind: DetailKind) ?Msg {
    return switch (ev.kind) {
        .left_click => blk: {
            if (ev.log_row) |r| break :blk .{ .log_select_index = r };
            if (ev.detail_row) |r| break :blk .{ .detail_select_index = r };
            if (ev.pane) |p| break :blk .{ .set_focus = p };
            break :blk null;
        },
        .left_double => null, // phase 1: stage 無し・単クリック相当だが no-op
        .wheel_down => blk: {
            if (ev.on_log) break :blk .log_scroll_down;
            if (ev.on_detail) {
                break :blk switch (detail_kind) {
                    .files => .detail_files_scroll_down,
                    .diff => .detail_diff_scroll_down,
                };
            }
            break :blk null;
        },
        .wheel_up => blk: {
            if (ev.on_log) break :blk .log_scroll_up;
            if (ev.on_detail) {
                break :blk switch (detail_kind) {
                    .files => .detail_files_scroll_up,
                    .diff => .detail_diff_scroll_up,
                };
            }
            break :blk null;
        },
        .ignore => null,
    };
}

// ====================== TODO 2 phase 1: fromZigzagMouseForMode wrapper ======================
//
// 既存 `fromZigzagMouse` は changes モード専用（回帰安全・H7）。本節は ViewMode 別の新エントリ
// ポイントを追加し、mode==.changes は既存関数へ delegating、mode==.log は log レイアウト
// （view.LogLayout）で log/detail ペインのヒットテストを行い MouseEvent の log_row/detail_row/
// on_log/on_detail を詰める。★R24: ホイールは scroll 系のみ（cursor 移動はしない・1 Msg 制約）。

/// ViewMode 別マウスアダプタのエントリポイント。
/// - `.changes`: 既存 `fromZigzagMouse` へ delegating（`changes_layout`/`changes_scratch` を使用）。
/// - `.log`: `fromZigzagMouseForLog` へ delegating（`log_layout`/`log_scratch`/`detail_scratch` を使用）。
/// 使わない側のレイアウト/scratch は呼び出し側でダミーを渡してよい（参照しないため）。
pub fn fromZigzagMouseForMode(
    mode: ViewMode,
    ev: zz.MouseEvent,
    model: *const Model,
    changes_layout: view.Layout,
    log_layout: view.LogLayout,
    cs: *ClickState,
    now_ms: i64,
    changes_scratch: []view.ChangesRow,
    log_scratch: []view.LogRow,
    detail_scratch: []view.DetailRow,
) MouseEvent {
    return switch (mode) {
        .changes => fromZigzagMouse(ev, model, changes_layout, cs, now_ms, changes_scratch),
        .log => fromZigzagMouseForLog(ev, model, log_layout, cs, now_ms, log_scratch, detail_scratch),
    };
}

/// log ビューのマウスヒットテスト（spec §3.5）。
/// - ペイン判定: クリック座標と `log_layout` の各 Rect（log/detail）を照合し pane と on_log/on_detail を決める。
///   log 左ペイン→ pane=.changes（Focus 値を流用・log ペインは .changes で表現）・on_log=true。
///   detail 右ペイン→ pane=.diff（Focus 値を流用）・on_detail=true。
/// - log ペイン内クリックなら表示行→`log_commits.items` の格納インデックスを `log_row` に入れる
///   （`logRowLayout` が見出し無し・i 行目=格納 i なので `log_scroll + vr` で解決）。
/// - detail ペイン（detail_kind==.files）内クリックなら表示行→`detail_files.items` の格納インデックスを
///   `detail_row` に入れる（`detailRowLayout` で解決・`detail_scroll` を加算）。
///   detail_kind==.diff では detail_row を設定しない（diff は読み取り専用・cursor 移動しない）。
/// - ダブルクリック判定は `classifyClick`（changes と同型）。phase 1 では stage 無しで no-op になるが
///   `left_double` を返す点は changes と同じ（`mouseToMsgForLog` が null を返す）。
pub fn fromZigzagMouseForLog(
    ev: zz.MouseEvent,
    model: *const Model,
    layout: view.LogLayout,
    cs: *ClickState,
    now_ms: i64,
    log_scratch: []view.LogRow,
    detail_scratch: []view.DetailRow,
) MouseEvent {
    const on_log = pointInRect(ev.x, ev.y, layout.log);
    const on_detail = pointInRect(ev.x, ev.y, layout.detail);
    // pane は Focus 値を流用（log 左 = .changes、detail 右 = .diff）。両ペイン外なら null。
    const pane: ?Focus = if (on_log) .changes else if (on_detail) .diff else null;

    // log ペイン内クリック: 表示行 vr に log_scroll を足して絶対 visual row（== 格納 index）を引く。
    // logRowLayout は見出し無し・i 行目 = 格納 i なので、単純に `log_scroll + vr` が格納 index。
    // 範囲外（vr が log_commits.items.len を超える）は null。
    const log_row: ?usize = if (on_log) blk: {
        if (ev.y < layout.log.y or ev.y >= layout.log.y + layout.log.h) break :blk null;
        const vr = @as(usize, ev.y - layout.log.y);
        const abs = model.log_scroll + vr;
        if (abs >= model.log_commits.items.len) break :blk null;
        _ = log_scratch; // logRowLayout は見出し無し・自明なので scratch を使わず直接 index 計算で十分
        break :blk abs;
    } else null;

    // detail ペイン内クリック: detail_kind==.files のときだけ detail_row を解決。
    // detailRowLayout を scratch 経由で呼び、表示行→格納 index を引く（detail_scroll を加算）。
    const detail_row: ?usize = if (on_detail and model.detail_kind == .files) blk: {
        if (ev.y < layout.detail.y or ev.y >= layout.detail.y + layout.detail.h) break :blk null;
        const vr = @as(usize, ev.y - layout.detail.y);
        const abs = model.detail_scroll + vr;
        if (abs >= model.detail_files.items.len) break :blk null;
        // detailRowLayout で有効性を再確認（i 行目 = 格納 i なので abs そのままでもよいが、
        // 将来の見出し追加に備えて scratch 経由で解決する・範囲外は null）。
        const n = view.detailRowLayout(model, detail_scratch);
        if (abs >= n) break :blk null;
        break :blk detail_scratch[abs].storage_index;
    } else null;

    // 共通ベースを一度組く。kind は全分岐で上書きされるためデフォルト .ignore は漏れない（制約5）。
    const base = MouseEvent{
        .pane = pane,
        .log_row = log_row,
        .detail_row = detail_row,
        .on_log = on_log,
        .on_detail = on_detail,
        // .kind は MouseEvent.kind のデフォルト .ignore を使う（各分岐で必ず上書き）
    };
    return switch (ev.button) {
        // ホイールは event_type に関係なく honor する（SGR では wheel も press 扱いで来る）。
        // ★R24: scroll 系のみ。cursor 移動はしない（on_log/on_detail でどの scroll 系かは mouseToMsgForLog が決める）。
        .wheel_up => blk: {
            var m = base;
            m.kind = .wheel_up;
            break :blk m;
        },
        .wheel_down => blk: {
            var m = base;
            m.kind = .wheel_down;
            break :blk m;
        },
        .left => blk: {
            // press のみ click/double として扱う。release/drag/move は `ignore`（log_select_index/
            // detail_select_index/set_focus を誤爆させない・changes と同型）。
            if (ev.event_type != .press) {
                var m = base;
                m.kind = .ignore;
                break :blk m;
            }
            // ダブルクリック判定は log_row（log ペイン）か detail_row（detail ペイン）で行う。
            // phase 1 では stage 無しのため left_double は mouseToMsgForLog で null になるが、
            // 分岐自体は changes と同型で残す（将来の stage 拡張の伏線）。
            const click_row: ?usize = log_row orelse detail_row;
            const kind: @FieldType(MouseEvent, "kind") = switch (classifyClick(cs, now_ms, click_row)) {
                .double => .left_double,
                .single => .left_click,
            };
            var m = base;
            m.kind = kind;
            break :blk m;
        },
        // 中/右/wheel_left/wheel_right/button_8..11/none と bare motion は何もしない。
        else => blk: {
            var m = base;
            m.kind = .ignore;
            break :blk m;
        },
    };
}

// --- 純粋な幾何ヘルパ（マウス当たり判定。TDD 対象） ---

/// 点 (x,y) が矩形 `r` の内側か。右端・下端は排他（x in [r.x, r.x+r.w)）。
pub fn pointInRect(x: u16, y: u16, r: view.Rect) bool {
    if (r.w == 0 or r.h == 0) return false;
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// changes ペイン内の絶対 y 座標から、ペイン先頭からの **表示行インデックス**（0 始まり）を返す。
/// 純粋。`y` がペインの縦範囲外なら null。
pub fn changesVisualRow(y: u16, r: view.Rect) ?usize {
    if (r.h == 0 or y < r.y or y >= r.y + r.h) return null;
    return @as(usize, y - r.y);
}

/// 表示行 `visual_row`（changes ペイン内、0 始まり）を `Model.files.items` の格納インデックスに解決する。
/// 見出し行・範囲外は null（クリック不可）。view.changesRowLayout（描画と同一の純粋列挙）を共有し、
/// 描画とのズレを構造的に防ぐ（view.zig の seam 注記参照）。
/// `scratch` は行レイアウトの一時バッファ（呼び出し側が確保。見出し3 + ファイル数を満たすこと）。
pub fn fileRowFromVisual(model: *const Model, visual_row: usize, scratch: []view.ChangesRow) ?usize {
    const n = view.changesRowLayout(model, scratch);
    if (visual_row >= n) return null;
    return scratch[visual_row].storage_index;
}

// --- zigzag イベント → Key / MouseEvent の薄いアダプタ（zigzag 依存・自動 test なし） ---

/// zigzag の `KeyEvent` を抽象 `Key` に変換する。`keyToMsg` が解釈しないキーは null。
/// Ctrl 修飾の s/d/u を先に判定してから通常文字を扱う（誤って通常 's' 等に落とさない）。
/// commit フォーカス時の文字/改行/Backspace/カーソル編集キーは TextArea が正本なので、ここでは
/// `Key` に変換しても `keyToMsg(.commit, ...)` が null を返す（編集は呼び出し側が TextArea へ委譲する）。
pub fn fromZigzagKey(ev: zz.KeyEvent) ?Key {
    if (ev.modifiers.ctrl) {
        switch (ev.key) {
            .char => |c| switch (c) {
                's', 'S' => return .ctrl_s,
                'd', 'D' => return .ctrl_d,
                'u', 'U' => return .ctrl_u,
                else => {},
            },
            else => {},
        }
    }
    return switch (ev.key) {
        .char => |c| Key{ .char = c },
        .space => Key{ .char = ' ' }, // zz は space を独立バリアントにするため char へ正規化
        .enter => .enter,
        .backspace => .backspace,
        .tab => if (ev.modifiers.shift) .shift_tab else .tab,
        .escape => .escape,
        .down => .down,
        .up => .up,
        else => null, // keyToMsg が扱わないキー（矢印左右/ファンクション/paste 等）
    };
}

/// ダブルクリック判定のための直近クリック状態（アダプタ層が保持。reducer は時刻を持てない＝純粋）。
pub const ClickState = struct {
    last_ms: i64 = 0,
    last_row: ?usize = null,
    /// しきい値（ms）。同一格納行をこの時間内に再クリックでダブルクリック。
    pub const double_click_ms: i64 = 300;
};

pub const ClickKind = enum { single, double };

/// 直近クリック状態 `cs` を `now_ms` と今回の格納行 `file_row` で更新し、single/double を判定する純粋関数。
/// 同一格納行（非 null）をしきい値内に再クリックしたら double、それ以外は single。
/// 時刻は呼び出し側（Io を持つ Task 11 ランタイム）が注入する（0.16 では wall-clock 取得に Io が要るため）。
pub fn classifyClick(cs: *ClickState, now_ms: i64, file_row: ?usize) ClickKind {
    const is_double = file_row != null and
        cs.last_row != null and
        cs.last_row.? == file_row.? and
        (now_ms - cs.last_ms) <= ClickState.double_click_ms;
    cs.last_ms = now_ms;
    cs.last_row = file_row;
    return if (is_double) .double else .single;
}

/// zigzag の `MouseEvent` を抽象 `MouseEvent` に変換する。
/// - ペイン判定: クリック座標と `layout` の各 `Rect` を照合し pane（changes/diff/commit）を決める。
/// - changes ペインなら表示行→格納インデックス（`fileRowFromVisual`）を `file_row` に入れる。
/// - ホイールは diff ペイン上のときだけ scroll に効くよう `on_diff` を立てる。
/// - ダブルクリック: 直近クリックの「時刻＋格納行」を `cs` に保持し、しきい値内かつ同一行なら
///   `left_double`、そうでなければ `left_click`（判定は純粋な `classifyClick` に委譲）。
///   zz.MouseEvent にタイムスタンプが無く、Zig 0.16 では wall-clock 取得に Io が要るため、
///   時刻 `now_ms` は呼び出し側（Io を持つ Task 11 ランタイム）が注入する。
/// `scratch` は `fileRowFromVisual` 用の一時バッファ（見出し3 + ファイル数を満たすこと）。
pub fn fromZigzagMouse(
    ev: zz.MouseEvent,
    model: *const Model,
    layout: view.Layout,
    cs: *ClickState,
    now_ms: i64,
    scratch: []view.ChangesRow,
) MouseEvent {
    const on_diff = pointInRect(ev.x, ev.y, layout.diff);
    const pane: ?Focus =
        if (pointInRect(ev.x, ev.y, layout.changes)) .changes else if (on_diff) .diff else if (pointInRect(ev.x, ev.y, layout.commit)) .commit else null;

    // changes ペイン内クリックなら表示行→格納インデックスを解決（見出し行/範囲外は null）。
    // Item 5: ペインは model.changes_scroll からのウィンドウを描くため、クリックのペイン相対行 vr に
    // changes_scroll を足して **絶対 visual row** に直してから格納 index を引く（描画 writer と read を一致）。
    const file_row: ?usize = if (pane == .changes)
        (if (changesVisualRow(ev.y, layout.changes)) |vr| fileRowFromVisual(model, model.changes_scroll + vr, scratch) else null)
    else
        null;

    // diff ペイン内クリックなら、ペイン相対行に diff_scroll を足した絶対 diff 行を作る。
    // focus==.diff のフレームでは renderDiff が選択ハンクを画面内に保つよう diff_scroll を調整する
    // ため diff_scroll はハンク範囲内に収まり、表示先頭行 == diff_scroll でクリックが描画と一致する。
    // focus!=.diff でも update.scroll_diff_down が diffLineCount でクランプするため（制約4解消）、
    // diff_scroll は diff_text 行数を超えず、クリックの diff_line は常に範囲内。
    const diff_line: ?usize = if (on_diff)
        model.diff_scroll + @as(usize, ev.y - layout.diff.y)
    else
        null;

    // 共通ベースを一度組む。kind は全分岐で上書きされるためデフォルト .ignore は漏れない（制約5）。
    const base = MouseEvent{
        .pane = pane,
        .file_row = file_row,
        .on_diff = on_diff,
        .diff_line = diff_line,
        // .kind は MouseEvent.kind のデフォルト .ignore を使う（各分岐で必ず上書き）
    };
    return switch (ev.button) {
        // ホイールは event_type に関係なく honor する（SGR では wheel も press 扱いで来る）。
        .wheel_up => blk: {
            var m = base;
            m.kind = .wheel_up;
            break :blk m;
        },
        .wheel_down => blk: {
            var m = base;
            m.kind = .wheel_down;
            break :blk m;
        },
        .left => blk: {
            // press のみ click/double として扱う。release/drag/move は `ignore`（select_index/set_focus を誤爆させない）。
            // mode 1003 では単一の物理クリックでも press と release が来るため、両方を click にすると 2 回選択される。
            if (ev.event_type != .press) {
                var m = base;
                m.kind = .ignore;
                break :blk m;
            }
            const kind: @FieldType(MouseEvent, "kind") = switch (classifyClick(cs, now_ms, file_row)) {
                .double => .left_double,
                .single => .left_click,
            };
            var m = base;
            m.kind = kind;
            break :blk m;
        },
        // 中/右/wheel_left/wheel_right/button_8..11/none と bare motion は何もしない。
        else => blk: {
            var m = base;
            m.kind = .ignore;
            break :blk m;
        },
    };
}

// ====================== Tests（純粋関数のみ） ======================

test "in commit focus, q is passed to TextArea (no global command)" {
    // commit フォーカス時、文字キーはグローバル命令にならない（null = TextArea が処理）。
    try std.testing.expect(keyToMsg(.commit, .{ .char = 'q' }) == null);
}
test "in changes focus, q quits" {
    const m = keyToMsg(.changes, .{ .char = 'q' });
    try std.testing.expect(m.? == .quit);
}
test "ctrl_s in commit requests commit" {
    try std.testing.expect(keyToMsg(.commit, .ctrl_s).? == .request_commit);
}
test "escape/tab in commit focus moves focus_next" {
    try std.testing.expect(keyToMsg(.commit, .escape).? == .focus_next);
    try std.testing.expect(keyToMsg(.commit, .tab).? == .focus_next);
}
test "changes focus: navigation and command keys map" {
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'j' }).? == .key_down);
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'k' }).? == .key_up);
    try std.testing.expect(keyToMsg(.changes, .down).? == .key_down);
    try std.testing.expect(keyToMsg(.changes, .up).? == .key_up);
    try std.testing.expect(keyToMsg(.changes, .{ .char = ' ' }).? == .toggle_stage);
    try std.testing.expect(keyToMsg(.changes, .{ .char = 's' }).? == .toggle_stage);
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'c' }).? == .focus_commit);
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'r' }).? == .request_refresh);
    try std.testing.expect(keyToMsg(.changes, .tab).? == .focus_next);
    try std.testing.expect(keyToMsg(.changes, .ctrl_d).? == .scroll_diff_down);
    try std.testing.expect(keyToMsg(.changes, .ctrl_u).? == .scroll_diff_up);
}
test "changes focus: unmapped char returns null" {
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'z' }) == null);
}

test "diff focus: line cursor / selection / hunk-jump / stage keys map" {
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'j' }).? == .diff_cursor_down);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'k' }).? == .diff_cursor_up);
    try std.testing.expect(keyToMsg(.diff, .down).? == .diff_cursor_down);
    try std.testing.expect(keyToMsg(.diff, .up).? == .diff_cursor_up);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'v' }).? == .toggle_line_selection);
    try std.testing.expect(keyToMsg(.diff, .{ .char = ']' }).? == .diff_hunk_next);
    try std.testing.expect(keyToMsg(.diff, .{ .char = '[' }).? == .diff_hunk_prev);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 's' }).? == .stage_lines);
    try std.testing.expect(keyToMsg(.diff, .{ .char = ' ' }).? == .stage_lines);
    try std.testing.expect(keyToMsg(.diff, .enter).? == .stage_lines);
}

test "keyToMsg diff focus: '#' maps to select_hunk" {
    try std.testing.expectEqual(@as(?Msg, .select_hunk), keyToMsg(.diff, .{ .char = '#' }));
}

test "keyToMsg diff focus: 'H' maps to stage_hunk" {
    try std.testing.expectEqual(@as(?Msg, .stage_hunk), keyToMsg(.diff, .{ .char = 'H' }));
}

test "keyToMsg diff focus: lowercase 'h' is unmapped (stays null)" {
    // 大文字 H のみ。小文字 h は未割当（将来 vim 系 left 等と衝突回避）。
    try std.testing.expectEqual(@as(?Msg, null), keyToMsg(.diff, .{ .char = 'h' }));
}

test "changes focus mapping is unchanged (regression)" {
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'j' }).? == .key_down);
    try std.testing.expect(keyToMsg(.changes, .{ .char = 's' }).? == .toggle_stage);
    try std.testing.expect(keyToMsg(.changes, .{ .char = ' ' }).? == .toggle_stage);
    try std.testing.expect(keyToMsg(.changes, .enter) == null); // enter は changes では無命令
}

test "double click on file row toggles stage" {
    try std.testing.expect(mouseToMsg(.{ .kind = .left_double, .file_row = 2 }).? == .toggle_stage);
}
test "wheel over diff pane scrolls diff" {
    try std.testing.expect(mouseToMsg(.{ .kind = .wheel_down, .on_diff = true }).? == .scroll_diff_down);
}
test "wheel over diff pane scrolls up" {
    try std.testing.expect(mouseToMsg(.{ .kind = .wheel_up, .on_diff = true }).? == .scroll_diff_up);
}
test "wheel off diff pane is ignored" {
    try std.testing.expect(mouseToMsg(.{ .kind = .wheel_down, .on_diff = false }) == null);
}
test "click on diff pane (no file row) focuses diff" {
    const m = mouseToMsg(.{ .kind = .left_click, .pane = .diff });
    try std.testing.expect(m.? == .set_focus);
    try std.testing.expectEqual(Focus.diff, m.?.set_focus);
}
test "click on file row selects that storage index" {
    const m = mouseToMsg(.{ .kind = .left_click, .pane = .changes, .file_row = 3 });
    try std.testing.expect(m.? == .select_index);
    try std.testing.expectEqual(@as(usize, 3), m.?.select_index);
}
test "double click off file row is ignored" {
    try std.testing.expect(mouseToMsg(.{ .kind = .left_double, .file_row = null }) == null);
}

test "classifyClick: first click is single, fast same-row repeat is double" {
    var cs = ClickState{};
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1000, 2));
    try std.testing.expectEqual(ClickKind.double, classifyClick(&cs, 1100, 2)); // 100ms 以内・同一行
}
test "classifyClick: slow same-row repeat is single" {
    var cs = ClickState{};
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1000, 2));
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 2000, 2)); // しきい値超過
}
test "classifyClick: fast different-row repeat is single" {
    var cs = ClickState{};
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1000, 2));
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1100, 3)); // 行が違う
}
test "classifyClick: header/outside row (null) never doubles even when repeated fast" {
    var cs = ClickState{};
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1000, null));
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1050, null));
}
test "classifyClick: boundary exactly at threshold is double" {
    var cs = ClickState{};
    try std.testing.expectEqual(ClickKind.single, classifyClick(&cs, 1000, 0));
    try std.testing.expectEqual(ClickKind.double, classifyClick(&cs, 1000 + ClickState.double_click_ms, 0));
}

test "pointInRect respects exclusive right/bottom edges" {
    const r = view.Rect{ .x = 2, .y = 3, .w = 4, .h = 5 }; // x in [2,6), y in [3,8)
    try std.testing.expect(pointInRect(2, 3, r));
    try std.testing.expect(pointInRect(5, 7, r));
    try std.testing.expect(!pointInRect(6, 3, r)); // x == x+w は外
    try std.testing.expect(!pointInRect(2, 8, r)); // y == y+h は外
    try std.testing.expect(!pointInRect(1, 3, r)); // x < x は外
    try std.testing.expect(!pointInRect(2, 2, r)); // y < y は外
}
test "pointInRect with zero size is always outside" {
    try std.testing.expect(!pointInRect(0, 0, .{ .x = 0, .y = 0, .w = 0, .h = 1 }));
    try std.testing.expect(!pointInRect(0, 0, .{ .x = 0, .y = 0, .w = 1, .h = 0 }));
}
test "changesVisualRow maps absolute y to pane-relative row" {
    const r = view.Rect{ .x = 0, .y = 0, .w = 40, .h = 10 };
    try std.testing.expectEqual(@as(?usize, 0), changesVisualRow(0, r));
    try std.testing.expectEqual(@as(?usize, 9), changesVisualRow(9, r));
    try std.testing.expectEqual(@as(?usize, null), changesVisualRow(10, r)); // 範囲外
    // y オフセットありの矩形でも相対行になる。
    const r2 = view.Rect{ .x = 0, .y = 5, .w = 40, .h = 3 };
    try std.testing.expectEqual(@as(?usize, 0), changesVisualRow(5, r2));
    try std.testing.expectEqual(@as(?usize, 2), changesVisualRow(7, r2));
    try std.testing.expectEqual(@as(?usize, null), changesVisualRow(4, r2));
    try std.testing.expectEqual(@as(?usize, null), changesVisualRow(8, r2));
}
test "fileRowFromVisual resolves visual rows to storage indices (header rows -> null)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 格納順 = porcelain v2 の path 順（section interleave）: A(unstaged) B(staged) C(unstaged)。
    try m.files.append(a, .{ .path = try a.dupe(u8, "A"), .orig_path = null, .section = .unstaged });
    try m.files.append(a, .{ .path = try a.dupe(u8, "B"), .orig_path = null, .section = .staged });
    try m.files.append(a, .{ .path = try a.dupe(u8, "C"), .orig_path = null, .section = .unstaged });
    var scratch: [16]view.ChangesRow = undefined;
    // 表示行: [0 Staged head][1 B][2 Unstaged head][3 A][4 C][5 Untracked head]
    try std.testing.expectEqual(@as(?usize, null), fileRowFromVisual(&m, 0, &scratch)); // 見出し
    try std.testing.expectEqual(@as(?usize, 1), fileRowFromVisual(&m, 1, &scratch)); // B
    try std.testing.expectEqual(@as(?usize, null), fileRowFromVisual(&m, 2, &scratch)); // 見出し
    try std.testing.expectEqual(@as(?usize, 0), fileRowFromVisual(&m, 3, &scratch)); // A
    try std.testing.expectEqual(@as(?usize, 2), fileRowFromVisual(&m, 4, &scratch)); // C
    try std.testing.expectEqual(@as(?usize, null), fileRowFromVisual(&m, 5, &scratch)); // 見出し
    try std.testing.expectEqual(@as(?usize, null), fileRowFromVisual(&m, 6, &scratch)); // 範囲外
}

// --- fromZigzagMouse の behavioral test（純粋: tty/Io 不要。zz.MouseEvent を直接組む） ---
//
// mode 1003 では単一クリックでも press+release が、ドラッグ/ホバーで drag/move が届く。
// これらを select_index/set_focus に潰さないことを検証する（レビュー指摘 #1/#2 の回帰防止）。

/// 表示行 [0 Staged head][1 B][2 Unstaged head][3 A][4 C][5 Untracked head] になる Model を組む。
/// 呼び出し側が deinit する。
fn buildMouseTestModel(a: std.mem.Allocator) !Model {
    var m = try Model.init(a, "/r");
    errdefer m.deinit();
    try m.files.append(a, .{ .path = try a.dupe(u8, "A"), .orig_path = null, .section = .unstaged });
    try m.files.append(a, .{ .path = try a.dupe(u8, "B"), .orig_path = null, .section = .staged });
    try m.files.append(a, .{ .path = try a.dupe(u8, "C"), .orig_path = null, .section = .unstaged });
    return m;
}

/// changes ペインは y in [0,6)（上記6表示行を覆う）、diff は右側、commit は下。x は重ならない。
const mouse_test_layout = view.Layout{
    .changes = .{ .x = 0, .y = 0, .w = 40, .h = 6 },
    .diff = .{ .x = 40, .y = 0, .w = 40, .h = 6 },
    .commit = .{ .x = 0, .y = 6, .w = 80, .h = 2 },
    .status = .{ .x = 0, .y = 8, .w = 80, .h = 1 },
};

test "fromZigzagMouse: left press on file row B yields left_click -> select_index" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    // 表示行 1 = B（格納 index 1）。changes ペイン内 (x=5, y=1)。
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    const msg = mouseToMsg(me);
    try std.testing.expect(msg.? == .select_index);
    try std.testing.expectEqual(@as(usize, 1), msg.?.select_index);
}

test "fromZigzagMouse: click on diff pane yields select_line_at with scroll offset" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    m.diff_scroll = 3; // 表示オフセットを合算する検証
    // diff ペイン (x=50, y=2)。ペイン相対行 = 2 - layout.diff.y(=0) = 2 → 絶対 diff 行 = 3 + 2 = 5。
    const ev = zz.MouseEvent{ .x = 50, .y = 2, .button = .left, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    const msg = mouseToMsg(me);
    try std.testing.expect(msg.? == .select_line_at);
    try std.testing.expectEqual(@as(usize, 5), msg.?.select_line_at);
}

test "fromZigzagMouse: release/drag on diff pane is ignored (no hunk select)" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    m.diff_scroll = 3;
    // diff ペイン座標 (x=50, y=2)。release と drag はどちらも ignore（select_line_at を出さない）。
    const rel = zz.MouseEvent{ .x = 50, .y = 2, .button = .left, .event_type = .release };
    const me_rel = fromZigzagMouse(rel, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me_rel.kind);
    try std.testing.expect(mouseToMsg(me_rel) == null);
    const drg = zz.MouseEvent{ .x = 50, .y = 2, .button = .left, .event_type = .drag };
    const me_drg = fromZigzagMouse(drg, &m, mouse_test_layout, &cs, 1100, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me_drg.kind);
    try std.testing.expect(mouseToMsg(me_drg) == null);
}

test "fromZigzagMouse: left RELEASE on file row is ignored (no double select)" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .release };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expect(mouseToMsg(me) == null);
}

test "fromZigzagMouse: left DRAG on file row is ignored" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 5, .y = 4, .button = .left, .event_type = .drag };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expect(mouseToMsg(me) == null);
}

test "fromZigzagMouse: bare MOTION over changes pane is ignored (no hover churn)" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    // bare motion: button=.none, event_type=.move（parseSgr の bare motion 表現）。
    const ev = zz.MouseEvent{ .x = 5, .y = 3, .button = .none, .event_type = .move };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expect(mouseToMsg(me) == null);
}

test "fromZigzagMouse: RIGHT press on file row is ignored" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .right, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expect(mouseToMsg(me) == null);
}

test "fromZigzagMouse: MIDDLE press on file row is ignored" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .middle, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expect(mouseToMsg(me) == null);
}

test "fromZigzagMouse: wheel_up over diff pane scrolls regardless of event_type" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    // diff ペイン (x=50, y=2)。SGR では wheel は press 扱いで来るが、event_type に依らず honor する。
    const ev = zz.MouseEvent{ .x = 50, .y = 2, .button = .wheel_up, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .wheel_up), me.kind);
    try std.testing.expect(me.on_diff);
    try std.testing.expect(mouseToMsg(me).? == .scroll_diff_up);
}

test "fromZigzagMouse: wheel_down over diff pane scrolls down" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 50, .y = 2, .button = .wheel_down, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .wheel_down), me.kind);
    try std.testing.expect(mouseToMsg(me).? == .scroll_diff_down);
}

test "fromZigzagMouse: left press then release on same row -> exactly one select" {
    // 物理クリック1回 = press + release。press だけが select_index を出し、release は無視。
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    const press = zz.MouseEvent{ .x = 5, .y = 3, .button = .left, .event_type = .press }; // 表示行3 = A(0)
    const release = zz.MouseEvent{ .x = 5, .y = 3, .button = .left, .event_type = .release };
    const m1 = fromZigzagMouse(press, &m, mouse_test_layout, &cs, 1000, &scratch);
    const m2 = fromZigzagMouse(release, &m, mouse_test_layout, &cs, 1005, &scratch);
    try std.testing.expect(mouseToMsg(m1).? == .select_index);
    try std.testing.expectEqual(@as(usize, 0), mouseToMsg(m1).?.select_index);
    try std.testing.expect(mouseToMsg(m2) == null);
}

test "fromZigzagMouse: click resolves against changes_scroll offset (windowed pane)" {
    // Item 5: ペインが changes_scroll=2 からのウィンドウを描いているとき、
    // ペイン相対行 0 のクリックは絶対 visual row 2（= Unstaged 見出し）に解決される。
    // 絶対 visual row: [0 Staged head][1 B][2 Unstaged head][3 A][4 C][5 Untracked head]
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    m.changes_scroll = 2;
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    // ペイン相対行 0（y=0） → 絶対 2（Unstaged 見出し = file_row null）。set_focus になる。
    const head_ev = zz.MouseEvent{ .x = 5, .y = 0, .button = .left, .event_type = .press };
    const head_me = fromZigzagMouse(head_ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(?usize, null), head_me.file_row);
    try std.testing.expect(mouseToMsg(head_me).? == .set_focus);
    // ペイン相対行 1（y=1） → 絶対 3 = A（格納 index 0）。select_index 0。
    const file_ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .press };
    const file_me = fromZigzagMouse(file_ev, &m, mouse_test_layout, &cs, 2000, &scratch);
    try std.testing.expectEqual(@as(?usize, 0), file_me.file_row);
    try std.testing.expect(mouseToMsg(file_me).? == .select_index);
    try std.testing.expectEqual(@as(usize, 0), mouseToMsg(file_me).?.select_index);
}

test "fromZigzagMouse: left press on header row focuses changes pane (no select)" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    // 表示行 0 = Staged 見出し → file_row null だが pane=.changes。
    const ev = zz.MouseEvent{ .x = 5, .y = 0, .button = .left, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    const msg = mouseToMsg(me);
    try std.testing.expect(msg.? == .set_focus);
    try std.testing.expectEqual(Focus.changes, msg.?.set_focus);
}

test "fromZigzagMouse: base fields propagate to all branches (factoring invariant)" {
    // 制約5の factoring 不変条件: ignore 系分岐（右クリック等）でも base フィールドが伝播することを検証。
    // これが壊れると将来のフィールド追加で特定分岐だけ取り残される（本制約の再発）。
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    m.diff_scroll = 2; // diff_line 計算に影響するようオフセットを設定
    // diff ペイン上で右クリック（else 分岐 = ignore）。kind は ignore だが、
    // pane/on_diff/diff_line は base から伝播しているはず。
    const ev = zz.MouseEvent{ .x = 50, .y = 2, .button = .right, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expectEqual(Focus.diff, me.pane.?); // base から伝播
    try std.testing.expect(me.on_diff); // base から伝播
    try std.testing.expectEqual(@as(usize, 4), me.diff_line.?); // 2 + 2 = 4（base から伝播）
}

// ====================== TODO 2 phase 1: ViewMode 別入力ルーティングのテスト ======================

test "keyToMsgForMode: changes mode delegates to keyToMsg" {
    // 回帰安全: changes mode は既存 keyToMsg と同一結果。
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .files, .{ .char = 'j' }).? == .key_down);
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .files, .{ .char = 'q' }).? == .quit);
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .files, .{ .char = 's' }).? == .toggle_stage);
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .files, .tab).? == .focus_next);
    // detail_kind は changes mode では無視される（files を渡しても diff を渡しても同じ）。
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .diff, .{ .char = 'j' }).? == .key_down);
}

test "keyToMsgForMode: log mode L toggles view mode (global)" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'L' }).? == .toggle_view_mode);
    // focus/detail_kind に依存しない
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'L' }).? == .toggle_view_mode);
}

test "keyToMsgForMode: log mode q quits (global)" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'q' }).? == .quit);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'q' }).? == .quit);
}

test "keyToMsgForMode: log mode r requests refresh (global)" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'r' }).? == .request_refresh);
}

test "keyToMsgForMode: log mode tab is focus_next (global)" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .tab).? == .focus_next);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .tab).? == .focus_next);
}

test "keyToMsgForMode: log mode j in left pane is log_cursor_down" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'j' }).? == .log_cursor_down);
}

test "keyToMsgForMode: log mode k in left pane is log_cursor_up" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'k' }).? == .log_cursor_up);
}

test "keyToMsgForMode: log mode arrow down/up in left pane map to log cursor" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .down).? == .log_cursor_down);
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .up).? == .log_cursor_up);
}

test "keyToMsgForMode: log mode j in right pane (files) is detail_cursor_down" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .{ .char = 'j' }).? == .detail_cursor_down);
}

test "keyToMsgForMode: log mode j in right pane (diff) is detail_diff_scroll_down" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'j' }).? == .detail_diff_scroll_down);
}

test "keyToMsgForMode: log mode k in right pane (files) is detail_cursor_up" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .{ .char = 'k' }).? == .detail_cursor_up);
}

test "keyToMsgForMode: log mode k in right pane (diff) is detail_diff_scroll_up" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'k' }).? == .detail_diff_scroll_up);
}

test "keyToMsgForMode: log mode Enter in left pane is log_open_detail" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .enter).? == .log_open_detail);
}

test "keyToMsgForMode: log mode Space in left pane is log_open_detail" {
    // space は fromZigzagKey で char=' ' に正規化されるため char arm で処理。
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = ' ' }).? == .log_open_detail);
}

test "keyToMsgForMode: log mode Enter in right pane (files) is detail_select_file" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .enter).? == .detail_select_file);
}

test "keyToMsgForMode: log mode Enter in right pane (diff) is no-op" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .enter) == null);
}

test "keyToMsgForMode: log mode Esc in right pane (diff) is detail_back_to_files" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .escape).? == .detail_back_to_files);
}

test "keyToMsgForMode: log mode Backspace in right pane (diff) is detail_back_to_files" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .backspace).? == .detail_back_to_files);
}

test "keyToMsgForMode: log mode 'u' in right pane (diff) is detail_back_to_files" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'u' }).? == .detail_back_to_files);
}

test "keyToMsgForMode: log mode Esc in right pane (files) is no-op (already files)" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .escape) == null);
}

test "keyToMsgForMode: log mode s is unmapped (no stage)" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 's' }) == null);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .{ .char = 's' }) == null);
}

test "keyToMsgForMode: log mode c is unmapped (no commit focus)" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'c' }) == null);
}

test "keyToMsgForMode: log mode v/#/H are unmapped (no line selection)" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'v' }) == null);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = '#' }) == null);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .{ .char = 'H' }) == null);
}

test "keyToMsgForMode: log mode Ctrl+d in left pane is log_scroll_down" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .ctrl_d).? == .log_scroll_down);
}

test "keyToMsgForMode: log mode Ctrl+u in left pane is log_scroll_up" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .ctrl_u).? == .log_scroll_up);
}

test "keyToMsgForMode: log mode Ctrl+d in right pane (files) is detail_files_scroll_down" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .ctrl_d).? == .detail_files_scroll_down);
}

test "keyToMsgForMode: log mode Ctrl+d in right pane (diff) is detail_diff_scroll_down" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .ctrl_d).? == .detail_diff_scroll_down);
}

test "keyToMsgForMode: log mode Ctrl+u in right pane (diff) is detail_diff_scroll_up" {
    try std.testing.expect(keyToMsgForMode(.log, .diff, .diff, .ctrl_u).? == .detail_diff_scroll_up);
}

test "keyToMsgForMode: log mode unmapped char returns null" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'z' }) == null);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .{ .char = 'z' }) == null);
}

test "mouseToMsgForMode: changes mode delegates to mouseToMsg" {
    const ev = MouseEvent{ .kind = .left_click, .file_row = 1 };
    const msg = mouseToMsgForMode(.changes, ev, .files).?;
    try std.testing.expect(msg == .select_index);
    try std.testing.expectEqual(@as(usize, 1), msg.select_index);
    // detail_kind は changes mode では無視
    const msg2 = mouseToMsgForMode(.changes, ev, .diff).?;
    try std.testing.expect(msg2 == .select_index);
}

test "mouseToMsgForMode: log mode click on log row yields log_select_index" {
    const ev = MouseEvent{ .kind = .left_click, .log_row = 3 };
    const msg = mouseToMsgForMode(.log, ev, .files).?;
    try std.testing.expect(msg == .log_select_index);
    try std.testing.expectEqual(@as(usize, 3), msg.log_select_index);
}

test "mouseToMsgForMode: log mode click on detail row yields detail_select_index" {
    const ev = MouseEvent{ .kind = .left_click, .detail_row = 2 };
    const msg = mouseToMsgForMode(.log, ev, .files).?;
    try std.testing.expect(msg == .detail_select_index);
    try std.testing.expectEqual(@as(usize, 2), msg.detail_select_index);
}

test "mouseToMsgForMode: log mode click on pane (no row) yields set_focus" {
    const ev = MouseEvent{ .kind = .left_click, .pane = .changes };
    const msg = mouseToMsgForMode(.log, ev, .files).?;
    try std.testing.expect(msg == .set_focus);
    try std.testing.expectEqual(Focus.changes, msg.set_focus);
}

test "mouseToMsgForMode: log mode click with no target is null" {
    const ev = MouseEvent{ .kind = .left_click };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files) == null);
}

test "mouseToMsgForMode: log mode left_double is no-op (phase 1 no stage)" {
    const ev = MouseEvent{ .kind = .left_double, .log_row = 1 };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files) == null);
}

test "mouseToMsgForMode: log mode wheel_down on log pane scrolls log" {
    const ev = MouseEvent{ .kind = .wheel_down, .on_log = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files).? == .log_scroll_down);
}

test "mouseToMsgForMode: log mode wheel_up on log pane scrolls log" {
    const ev = MouseEvent{ .kind = .wheel_up, .on_log = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files).? == .log_scroll_up);
}

test "mouseToMsgForMode: log mode wheel_down on detail pane (files) scrolls detail_files" {
    const ev = MouseEvent{ .kind = .wheel_down, .on_detail = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files).? == .detail_files_scroll_down);
}

test "mouseToMsgForMode: log mode wheel_down on detail pane (diff) scrolls detail_diff" {
    const ev = MouseEvent{ .kind = .wheel_down, .on_detail = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .diff).? == .detail_diff_scroll_down);
}

test "mouseToMsgForMode: log mode wheel_up on detail pane (files) scrolls detail_files up" {
    const ev = MouseEvent{ .kind = .wheel_up, .on_detail = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files).? == .detail_files_scroll_up);
}

test "mouseToMsgForMode: log mode wheel_up on detail pane (diff) scrolls detail_diff up" {
    const ev = MouseEvent{ .kind = .wheel_up, .on_detail = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .diff).? == .detail_diff_scroll_up);
}

test "mouseToMsgForMode: log mode wheel with no pane flag is null" {
    const ev_down = MouseEvent{ .kind = .wheel_down };
    const ev_up = MouseEvent{ .kind = .wheel_up };
    try std.testing.expect(mouseToMsgForMode(.log, ev_down, .files) == null);
    try std.testing.expect(mouseToMsgForMode(.log, ev_up, .files) == null);
}

test "mouseToMsgForMode: log mode ignore event is null" {
    const ev = MouseEvent{ .kind = .ignore, .on_log = true };
    try std.testing.expect(mouseToMsgForMode(.log, ev, .files) == null);
}

test "MouseEvent: new log/detail fields default to null/false" {
    const ev = MouseEvent{};
    try std.testing.expectEqual(@as(?usize, null), ev.log_row);
    try std.testing.expectEqual(@as(?usize, null), ev.detail_row);
    try std.testing.expect(!ev.on_log);
    try std.testing.expect(!ev.on_detail);
    try std.testing.expect(!ev.on_detail_diff);
}

test "MouseEvent: new fields can be set explicitly" {
    const ev = MouseEvent{
        .kind = .left_click,
        .log_row = 5,
        .detail_row = 7,
        .on_log = true,
        .on_detail = true,
        .on_detail_diff = true,
    };
    try std.testing.expectEqual(@as(?usize, 5), ev.log_row);
    try std.testing.expectEqual(@as(?usize, 7), ev.detail_row);
    try std.testing.expect(ev.on_log);
    try std.testing.expect(ev.on_detail);
    try std.testing.expect(ev.on_detail_diff);
}

// ====================== TODO 2 phase 1: fromZigzagMouseForLog behavioral test ======================
//
// fromZigzagMouseForLog は tty/Io 不要な純粋関数（zz.MouseEvent は素の struct・now_ms は注入）。
// log/detail ペインの当たり判定・log_row/detail_row 解析・スクロールオフセット考慮・
// release/drag/move の ignore・ホイールの on_log/on_detail を検証する。

/// log 用テスト Model を組む。log_commits に 3 件・detail_files に 2 件。呼び出し側が deinit する。
fn buildLogMouseTestModel(a: std.mem.Allocator) !Model {
    var m = try Model.init(a, "/r");
    errdefer m.deinit();
    const log = @import("git/log.zig");
    var commits: [3]log.Commit = undefined;
    inline for ([_][]const u8{ "h1hash", "h2hash", "h3hash" }, 0..) |h, i| {
        commits[i] = .{
            .hash = try a.dupe(u8, h),
            .parents = try a.alloc([]u8, 0),
            .author = try a.dupe(u8, "a"),
            .epoch_sec = @as(i64, @intCast(i)),
            .subject = try a.dupe(u8, "subj"),
            .refs = try a.dupe(u8, ""),
        };
    }
    defer for (&commits) |*c| c.deinit(a);
    try m.replaceLogCommits(&commits);

    const show = @import("git/show.zig");
    var entries: [2]show.NameStatus = undefined;
    entries[0] = .{ .status = 'M', .path = try a.dupe(u8, "f.txt"), .orig_path = null };
    entries[1] = .{ .status = 'A', .path = try a.dupe(u8, "g.txt"), .orig_path = null };
    defer for (&entries) |*e| e.deinit(a);
    try m.replaceDetailFiles(&entries);
    m.detail_kind = .files;
    return m;
}

/// log レイアウト: 左 40% log（y in [0,6)）、右 60% detail（y in [0,6)）、status は下。
/// log_scratch/detail_scratch のテストで使う固定レイアウト。
const log_mouse_test_layout = view.LogLayout{
    .log = .{ .x = 0, .y = 0, .w = 40, .h = 6 },
    .detail = .{ .x = 40, .y = 0, .w = 40, .h = 6 },
    .status = .{ .x = 0, .y = 6, .w = 80, .h = 1 },
};

test "fromZigzagMouseForLog: left press on log row 1 yields left_click -> log_select_index" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // log ペイン内 (x=5, y=1) → log_row = log_scroll(0) + 1 = 1。
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    try std.testing.expectEqual(@as(?usize, 1), me.log_row);
    try std.testing.expect(me.on_log);
    try std.testing.expect(!me.on_detail);
    try std.testing.expectEqual(Focus.changes, me.pane.?);
    const msg = mouseToMsgForMode(.log, me, .files).?;
    try std.testing.expect(msg == .log_select_index);
    try std.testing.expectEqual(@as(usize, 1), msg.log_select_index);
}

test "fromZigzagMouseForLog: left press on detail file row yields detail_select_index" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // detail ペイン内 (x=50, y=1) → detail_row = detail_scroll(0) + 1 = 1。
    const ev = zz.MouseEvent{ .x = 50, .y = 1, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    try std.testing.expectEqual(@as(?usize, 1), me.detail_row);
    try std.testing.expect(me.on_detail);
    try std.testing.expect(!me.on_log);
    try std.testing.expectEqual(Focus.diff, me.pane.?);
    const msg = mouseToMsgForMode(.log, me, .files).?;
    try std.testing.expect(msg == .detail_select_index);
    try std.testing.expectEqual(@as(usize, 1), msg.detail_select_index);
}

test "fromZigzagMouseForLog: left press on detail pane when detail_kind=diff yields set_focus (no row)" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    m.detail_kind = .diff; // diff ビューでは detail_row を解決しない
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 50, .y = 1, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    try std.testing.expectEqual(@as(?usize, null), me.detail_row); // diff では null
    try std.testing.expect(me.on_detail);
    // detail_row 無し → set_focus へ（mouseToMsgForLog の left_click 分岐）。
    const msg = mouseToMsgForMode(.log, me, .diff).?;
    try std.testing.expect(msg == .set_focus);
    try std.testing.expectEqual(Focus.diff, msg.set_focus);
}

test "fromZigzagMouseForLog: left press below rows yields set_focus (no row)" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // log ペイン内だが行数(3)を超える y=5 → log_row = null（範囲外）→ set_focus。
    const ev = zz.MouseEvent{ .x = 5, .y = 5, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    try std.testing.expectEqual(@as(?usize, null), me.log_row);
    const msg = mouseToMsgForMode(.log, me, .files).?;
    try std.testing.expect(msg == .set_focus);
}

test "fromZigzagMouseForLog: release/drag on log pane is ignored" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // release は ignore（changes と同型・二重 select 防止）。
    const rel = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .release };
    const me_rel = fromZigzagMouseForLog(rel, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me_rel.kind);
    try std.testing.expect(mouseToMsgForMode(.log, me_rel, .files) == null);
    const drg = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .drag };
    const me_drg = fromZigzagMouseForLog(drg, &m, log_mouse_test_layout, &cs, 1100, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me_drg.kind);
    try std.testing.expect(mouseToMsgForMode(.log, me_drg, .files) == null);
}

test "fromZigzagMouseForLog: bare MOTION over log pane is ignored" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .none, .event_type = .move };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expect(mouseToMsgForMode(.log, me, .files) == null);
}

test "fromZigzagMouseForLog: right/middle press on log pane is ignored" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    const right = zz.MouseEvent{ .x = 5, .y = 1, .button = .right, .event_type = .press };
    const me_right = fromZigzagMouseForLog(right, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me_right.kind);
    const middle = zz.MouseEvent{ .x = 5, .y = 1, .button = .middle, .event_type = .press };
    const me_middle = fromZigzagMouseForLog(middle, &m, log_mouse_test_layout, &cs, 1100, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me_middle.kind);
}

test "fromZigzagMouseForLog: wheel_down/up on log pane scrolls log" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // log ペイン上の wheel_down → on_log=true → mouseToMsgForLog が log_scroll_down を返す（R24）。
    const ev_down = zz.MouseEvent{ .x = 5, .y = 1, .button = .wheel_down, .event_type = .press };
    const me_down = fromZigzagMouseForLog(ev_down, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .wheel_down), me_down.kind);
    try std.testing.expect(me_down.on_log);
    try std.testing.expect(mouseToMsgForMode(.log, me_down, .files).? == .log_scroll_down);
    const ev_up = zz.MouseEvent{ .x = 5, .y = 1, .button = .wheel_up, .event_type = .press };
    const me_up = fromZigzagMouseForLog(ev_up, &m, log_mouse_test_layout, &cs, 1100, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .wheel_up), me_up.kind);
    try std.testing.expect(mouseToMsgForMode(.log, me_up, .files).? == .log_scroll_up);
}

test "fromZigzagMouseForLog: wheel_down on detail pane (files) scrolls detail_files" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // detail ペイン上の wheel_down → on_detail=true → detail_kind=files で detail_files_scroll_down。
    const ev = zz.MouseEvent{ .x = 50, .y = 1, .button = .wheel_down, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .wheel_down), me.kind);
    try std.testing.expect(me.on_detail);
    try std.testing.expect(mouseToMsgForMode(.log, me, .files).? == .detail_files_scroll_down);
}

test "fromZigzagMouseForLog: wheel_down on detail pane (diff) scrolls detail_diff" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    m.detail_kind = .diff;
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 50, .y = 1, .button = .wheel_down, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .wheel_down), me.kind);
    try std.testing.expect(me.on_detail);
    try std.testing.expect(mouseToMsgForMode(.log, me, .diff).? == .detail_diff_scroll_down);
}

test "fromZigzagMouseForLog: click resolves against log_scroll offset (windowed pane)" {
    // log_scroll=1 のウィンドウで、ペイン相対行 0 のクリックは絶対 visual row 1（=格納 1）に解決される。
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    m.log_scroll = 1;
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    const ev = zz.MouseEvent{ .x = 5, .y = 0, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(?usize, 1), me.log_row); // 1 + 0 = 1
    try std.testing.expect(mouseToMsgForMode(.log, me, .files).? == .log_select_index);
    try std.testing.expectEqual(@as(usize, 1), mouseToMsgForMode(.log, me, .files).?.log_select_index);
}

test "fromZigzagMouseForLog: base fields propagate to all branches (factoring invariant)" {
    // 制約5の回帰保護: ignore 系分岐（右クリック等）でも base フィールド（pane/on_log/on_detail/log_row）
    // が伝播することを検証。将来のフィールド追加で特定分岐だけ取り残されるのを防ぐ。
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // log ペイン上で右クリック（else 分岐 = ignore）。kind は ignore だが、
    // pane/on_log/log_row は base から伝播しているはず。
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .right, .event_type = .press };
    const me = fromZigzagMouseForLog(ev, &m, log_mouse_test_layout, &cs, 1000, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expectEqual(Focus.changes, me.pane.?); // base から伝播
    try std.testing.expect(me.on_log); // base から伝播
    try std.testing.expectEqual(@as(?usize, 1), me.log_row.?); // base から伝播
}

test "fromZigzagMouseForMode: changes mode delegates to fromZigzagMouse (regression)" {
    // 回帰保護: mode==.changes のとき fromZigzagMouse と同一結果（log_layout/scratch は無視）。
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var changes_scratch: [16]view.ChangesRow = undefined;
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // 表示行 1 = B（格納 index 1）。changes ペイン内 (x=5, y=1)。
    const ev = zz.MouseEvent{ .x = 5, .y = 1, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForMode(.changes, ev, &m, mouse_test_layout, log_mouse_test_layout, &cs, 1000, &changes_scratch, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    try std.testing.expectEqual(@as(?usize, 1), me.file_row);
    try std.testing.expect(!me.on_log); // changes モードでは log 系フィールドは触らない
    try std.testing.expect(!me.on_detail);
}

test "fromZigzagMouseForMode: log mode delegates to fromZigzagMouseForLog" {
    var m = try buildLogMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var changes_scratch: [16]view.ChangesRow = undefined;
    var log_scratch: [16]view.LogRow = undefined;
    var detail_scratch: [16]view.DetailRow = undefined;
    var cs = ClickState{};
    // log ペイン内 (x=5, y=2) → log_row = 2。
    const ev = zz.MouseEvent{ .x = 5, .y = 2, .button = .left, .event_type = .press };
    const me = fromZigzagMouseForMode(.log, ev, &m, mouse_test_layout, log_mouse_test_layout, &cs, 1000, &changes_scratch, &log_scratch, &detail_scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .left_click), me.kind);
    try std.testing.expectEqual(@as(?usize, 2), me.log_row);
    try std.testing.expect(me.on_log);
}

// ====================== TODO 2 phase 3a: filter modal key routing tests ======================

test "keyToMsgForLog: f in left pane opens filter modal" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'f' }).? == .open_filter_modal);
}

test "keyToMsgForLog: F in left pane clears filter" {
    try std.testing.expect(keyToMsgForMode(.log, .changes, .files, .{ .char = 'F' }).? == .clear_filter);
}

test "keyToMsgForLog: f/F only in changes focus (not diff)" {
    // f/F are only in left pane (focus==.changes), not in right pane (focus==.diff)
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .{ .char = 'f' }) == null);
    try std.testing.expect(keyToMsgForMode(.log, .diff, .files, .{ .char = 'F' }) == null);
}

test "keyToMsgForLog: f/F not available in changes mode" {
    // changes モードでは f/F は未割当（log モード専用）
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .files, .{ .char = 'f' }) == null);
    try std.testing.expect(keyToMsgForMode(.changes, .changes, .files, .{ .char = 'F' }) == null);
}

test "keyToMsgForModeWithModal: modal open Escape closes" {
    try std.testing.expect(
        keyToMsgForModeWithModal(.log, .changes, .files, .escape, true).? == .close_filter_modal,
    );
}

test "keyToMsgForModeWithModal: modal open Enter returns null (main constructs payload)" {
    // M-N7: apply_filter payload は main が TextInput.getValue を dupe して構築するため
    // input は null を返す（Zig の tagged union で payload 無し .apply_filter は作れない）
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .enter, true) == null);
}

test "keyToMsgForModeWithModal: modal open suppresses global keys (M6)" {
    // q/r/L 等 global mapping は modal open 時は全て null（main が TextInput.handleKey へ委譲）
    // ※ tab/shift_tab は phase 3b で filter_focus_next/prev へ割り当て（下記テスト）
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'q' }, true) == null);
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'r' }, true) == null);
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'L' }, true) == null);
}

test "keyToMsgForModeWithModal: modal open other chars return null" {
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'x' }, true) == null);
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'j' }, true) == null);
    try std.testing.expect(keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'k' }, true) == null);
}

test "keyToMsgForModeWithModal: modal open in diff focus also suppresses" {
    // diff focus でも modal open 時は全て suppress（focus に関わらず modal が最優先）
    try std.testing.expect(keyToMsgForModeWithModal(.log, .diff, .files, .{ .char = 'q' }, true) == null);
    try std.testing.expect(keyToMsgForModeWithModal(.log, .diff, .diff, .escape, true).? == .close_filter_modal);
}

test "keyToMsgForModeWithModal: modal closed delegates to keyToMsgForMode" {
    // filter_modal_open==false なら既存 keyToMsgForMode と同一
    try std.testing.expect(
        keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'j' }, false).? == .log_cursor_down,
    );
    try std.testing.expect(
        keyToMsgForModeWithModal(.log, .changes, .files, .{ .char = 'f' }, false).? == .open_filter_modal,
    );
    try std.testing.expect(
        keyToMsgForModeWithModal(.changes, .changes, .files, .{ .char = 'q' }, false).? == .quit,
    );
}

test "keyToMsgForModeWithModal: modal open tab → filter_focus_next (M1)" {
    try std.testing.expect(
        keyToMsgForModeWithModal(.log, .changes, .files, .tab, true).? == .filter_focus_next,
    );
}

test "keyToMsgForModeWithModal: modal open shift_tab → filter_focus_prev (M1)" {
    try std.testing.expect(
        keyToMsgForModeWithModal(.log, .changes, .files, .shift_tab, true).? == .filter_focus_prev,
    );
}

test "keyToMsg: shift_tab in non-modal modes is no-op (m1)" {
    // 既存の Key switch は else => null を持つため shift_tab は暗黙 no-op
    try std.testing.expect(keyToMsg(.changes, .shift_tab) == null);
    try std.testing.expect(keyToMsg(.diff, .shift_tab) == null);
    try std.testing.expect(keyToMsg(.commit, .shift_tab) == null);
}

// zigzag 依存の pub 関数（fromZigzagKey/fromZigzagMouse）も型検査されるよう refAllDecls する。
test {
    std.testing.refAllDecls(@This());
}
