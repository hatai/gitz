//! 入力正規化（Task 9）。zigzag の入力イベントを `Msg` に正規化する。
//!
//! 設計（spec §6: フォーカス時のキー捕捉）:
//! - **マッピング判断は純粋関数**（`keyToMsg` / `mouseToMsg` と幾何ヘルパ）にして単体テストする。
//! - zigzag イベント型からの取り出しだけ薄く zigzag 依存のアダプタ（`fromZigzagKey` /
//!   `fromZigzagMouse`）にする。これらは zigzag 依存・自動 test なし。`test { refAllDecls }` で
//!   型検査だけ強制し、実イベントの確認は Task 11 のヘッドレス/手動検証でカバーする（非 tty では unverified）。
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
    kind: enum { left_click, left_double, wheel_up, wheel_down },
    /// クリックされたペイン（フォーカス変更に使う。null=どのペイン外でもない）
    pane: ?Focus = null,
    /// ファイル一覧ペイン内で計算済みの**格納インデックス**（`Model.files.items` の添字）。
    /// 見出し行・ペイン外は null。`mouseToMsg` はこれを `select_index` にそのまま使う。
    file_row: ?usize = null,
    /// diff ペイン上のイベントか（ホイール対象判定）
    on_diff: bool = false,
};

pub fn mouseToMsg(ev: MouseEvent) ?Msg {
    return switch (ev.kind) {
        // ファイル行クリック→選択（reducer 側で focus も changes に移る）。
        // ファイル行以外のペインクリック→そのペインへフォーカス。
        .left_click => if (ev.file_row) |r| .{ .select_index = r } else if (ev.pane) |p| .{ .set_focus = p } else null,
        .left_double => if (ev.file_row != null) .toggle_stage else null,
        .wheel_down => if (ev.on_diff) .scroll_diff_down else null,
        .wheel_up => if (ev.on_diff) .scroll_diff_up else null,
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
    const file_row: ?usize = if (pane == .changes)
        (if (changesVisualRow(ev.y, layout.changes)) |vr| fileRowFromVisual(model, vr, scratch) else null)
    else
        null;

    return switch (ev.button) {
        .wheel_up => .{ .kind = .wheel_up, .pane = pane, .file_row = file_row, .on_diff = on_diff },
        .wheel_down => .{ .kind = .wheel_down, .pane = pane, .file_row = file_row, .on_diff = on_diff },
        .left => blk: {
            // press のみダブルクリック判定（drag/move/release は単発クリック扱いにしない）。
            if (ev.event_type != .press) break :blk .{ .kind = .left_click, .pane = pane, .file_row = file_row, .on_diff = on_diff };
            const kind: @FieldType(MouseEvent, "kind") = switch (classifyClick(cs, now_ms, file_row)) {
                .double => .left_double,
                .single => .left_click,
            };
            break :blk .{ .kind = kind, .pane = pane, .file_row = file_row, .on_diff = on_diff };
        },
        else => .{ .kind = .left_click, .pane = pane, .file_row = file_row, .on_diff = on_diff },
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

// zigzag 依存の pub 関数（fromZigzagKey/fromZigzagMouse）も型検査されるよう refAllDecls する。
test {
    std.testing.refAllDecls(@This());
}
