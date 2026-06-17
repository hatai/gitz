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
const Msg = @import("messages.zig").Msg;
const view = @import("view.zig");

/// 抽象化したキー（zigzag のキー型は `fromZigzagKey` でここに変換してから `keyToMsg` に渡す）。
pub const Key = union(enum) {
    char: u21, // 通常文字（コードポイント）
    enter,
    backspace,
    tab,
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
                ']' => .diff_hunk_next,
                '[' => .diff_hunk_prev,
                's', ' ' => .stage_lines,
                'c' => .focus_commit,
                'r' => .request_refresh,
                'q' => .quit,
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
        .tab => .tab,
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

// zigzag 依存の pub 関数（fromZigzagKey/fromZigzagMouse）も型検査されるよう refAllDecls する。
test {
    std.testing.refAllDecls(@This());
}
