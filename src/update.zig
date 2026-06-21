//! 純粋 reducer: `update(model, msg) -> AppCmd`。
//! Model を破壊的（in-place）に更新しつつ、副作用は AppCmd で表現する。
//! AppCmd ペイロードは Model から**複製**する（借用しない）。zigzag 非依存。
const std = @import("std");
const Model = @import("model.zig").Model;
const Focus = @import("model.zig").Focus;
const ViewMode = @import("model.zig").ViewMode;
const DetailKind = @import("model.zig").DetailKind;
const GraphRenderPolicy = @import("model.zig").GraphRenderPolicy;
const msgs = @import("messages.zig");
const Msg = msgs.Msg;
const AppCmd = msgs.AppCmd;
const FilterSpec = msgs.FilterSpec;
const status = @import("git/status.zig");
const hunk = @import("diff/hunk.zig");
const graph_mod = @import("git/graph.zig");

/// Model を破壊的に更新し、必要な副作用を AppCmd で返す。
/// 返した AppCmd は呼び出し側（解釈器/テスト）が deinit する。
pub fn update(model: *Model, msg: Msg) !AppCmd {
    switch (msg) {
        .key_down => {
            if (model.selected + 1 < model.files.items.len) model.selected += 1;
            model.diff_scroll = 0;
            model.diff_cursor = 0;
            model.diff_anchor = null;
            return loadDiffCmd(model);
        },
        .key_up => {
            if (model.selected > 0) model.selected -= 1;
            model.diff_scroll = 0;
            model.diff_cursor = 0;
            model.diff_anchor = null;
            return loadDiffCmd(model);
        },
        .select_index => |i| {
            if (i < model.files.items.len) model.selected = i;
            model.focus = .changes;
            model.diff_scroll = 0;
            model.diff_cursor = 0;
            model.diff_anchor = null;
            return loadDiffCmd(model);
        },
        .scroll_diff_down => {
            // ★制約4根治: diff_text 行数でクランプ。splitScalar は空でも1トークンを返すため
            //   total==0 は到達不能だが、diffLineCount が将来 trailing 空を除外すると total==0 に
            //   なり得る。前方防御的に残す（到達不能でも total-1 の underflow を防ぐ）。
            const total = diffLineCount(model.diff_text);
            if (total == 0) return .none;
            if (model.diff_scroll < total - 1) model.diff_scroll += 1;
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
        .request_refresh => {
            // log モード時は M11/R3/R4: generation 更新 + 状態クリア + log_restore_hash 退避 → load_log 発火。
            // changes モード時は従来どおり refresh_status。
            if (model.view_mode == .log) return try handleRequestRefreshLog(model);
            return .refresh_status;
        },
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
        .diff_cursor_down => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            // 選択中（anchor あり）はカーソルを anchor のハンク内に留める（spec: 選択は単一ハンク。
            // view のハイライト [lo,hi] と stage 対象が跨らないことを保証）。anchor 無しは
            // 最終ハンク末尾まで自由移動（本文行はそこより手前にしか無い＝走査上限）。
            const limit = navHunkEnd(parsed, model.diff_anchor);
            var n = model.diff_cursor + 1;
            while (n < limit) : (n += 1) {
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
            if (parsed.hunks.len == 0) return .none;
            // 選択中は anchor のハンク本文先頭より上へ出ない。anchor 無しは 0 まで。
            const floor = if (model.diff_anchor) |anc|
                hunkBodyTop(parsed.hunks[hunk.hunkIndexForLine(parsed, anc) orelse 0])
            else
                0;
            var n = model.diff_cursor;
            while (n > floor) {
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
            model.diff_cursor = hunkBodyTop(parsed.hunks[next]);
            model.diff_anchor = null;
            return .none;
        },
        .diff_hunk_prev => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const cur = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const prev = if (cur == 0) 0 else cur - 1;
            model.diff_cursor = hunkBodyTop(parsed.hunks[prev]);
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
            // ★マウスクリックは「明示的な選択解除」のセマンティクス。clampCursor が anchor を
            //   保持するようになった（Bug 1 層 2 修正）ため、ここで明示的に clear しないと
            //   クリックで選択が残る。ユーザー能動操作経路はここだけ clampCursor 経由で anchor を
            //   clear する必要がある（key_down/up/select_index/diff_hunk_next/prev は arm 内で
            //   直接 clear するため非依存）。
            model.diff_anchor = null;
            try clampCursor(model); // 本文外クリックはハンク本文へクランプ
            return .none;
        },
        .stage_lines => {
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            // untracked ガード削除（2026-06-17）: buildLinePatch(reverse=false) が --no-index diff の
            //   全行挿入を自然に処理する（未選択 + は削除、選択 + は保持 → @@ -0,0 +1,N @@ の部分挿入パッチ）。
            //   git apply --cached は index 未登録パスも新規作成として受理する（実証実験で確認）。
            //   部分 stage 後は status が 1 AM となり replaceFiles が staged+unstaged 2 エントリへ展開する。
            //   No-newline マーカーは直前の + 行の kept/dropped に追従し、文脈化は発生しないため null にはならない。
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse return .none;
            const sel = @import("model.zig").selectionRange(model.diff_cursor, model.diff_anchor);
            const cmd = try buildStagePatchFromSelection(model, parsed, idx, sel.lo, sel.hi);
            model.diff_anchor = null; // 成否に関わらず選択は消費（null パスでもハイライトを残さない）
            return cmd;
        },
        .select_hunk => {
            // 現在ハンクの本文全体を選択範囲へ。anchor=本文先頭, cursor=本文末尾。
            // 空 diff / ハンク無しは no-op（panic 回避）。
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const top = hunkBodyTop(parsed.hunks[idx]);
            const bot = hunk.hunkBodyBottom(parsed.hunks[idx]);
            model.focus = .diff;
            model.diff_anchor = top;
            model.diff_cursor = bot;
            return .none;
        },
        .stage_hunk => {
            // 現在ハンクの本文全体を即 stage（select_hunk + stage_lines と等価）。
            // 空 diff / busy / rename ガード付き。
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const top = hunkBodyTop(parsed.hunks[idx]);
            const bot = hunk.hunkBodyBottom(parsed.hunks[idx]);
            model.focus = .diff;
            model.diff_cursor = bot; // 視覚化: cursor は本文末尾（▌ マーカー）
            model.diff_anchor = top;
            const sel = @import("model.zig").selectionRange(bot, top); // [top, bot]
            const cmd = try buildStagePatchFromSelection(model, parsed, idx, sel.lo, sel.hi);
            model.diff_anchor = null; // 選択消費
            return cmd;
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
            // ★層 1: ファイル同一性ゲート（codex B1）。clampCursor は diff_text しか見えず
            //   「どのファイルの diff か」を知らないため、ここで selected ファイルが
            //   load_diff 発行時と同じか検証する。不一致なら stale anchor を消す。
            if (!isDiffOwnerCurrent(model)) {
                model.diff_anchor = null;
            }
            try clampCursor(model); // 層 2: validateAnchor（Task 5 で実装）
            return .none;
        },
        .git_error => |err_text| {
            model.busy = false;
            // phase 3a §4.8/M3: log 中の git_error は無条件 .none（busy を触らない・安全側）。
            //   bad revision recovery は LogPageFailed arm 側で処理。detail 系 stale 結果は
            //   detail_owner_hash 照合で別途弾かれる（M-N9 最小対処）。
            if (model.view_mode == .log) {
                try model.setStr(&model.error_text, err_text);
                return .none;
            }
            try model.setStr(&model.error_text, err_text);
            return .none;
        },
        .committed => {
            model.busy = false;
            try model.setStr(&model.commit_message, "");
            return .refresh_status;
        },
        // --- TODO 2 phase 1: log/detail の reducer arms（spec §1.6 権威） ---
        .toggle_view_mode => return try handleToggleViewMode(model),
        .log_cursor_down => return try handleLogCursorDown(model),
        .log_cursor_up => return try handleLogCursorUp(model),
        .log_open_detail => return try handleLogOpenDetail(model),
        .log_scroll_down => {
            // ★R13: scroll は page と無関係・R18 ゲート不要。len 以下へクランプ。
            if (model.log_scroll < model.log_commits.items.len) model.log_scroll += 1;
            return .none;
        },
        .log_scroll_up => {
            if (model.log_scroll > 0) model.log_scroll -= 1;
            return .none;
        },
        .detail_cursor_down => {
            // R2 空 guard。R18 ゲート不要（detail 内移動は log page と無関係）。
            if (model.detail_files.items.len == 0) return .none;
            if (model.detail_selected + 1 < model.detail_files.items.len) model.detail_selected += 1;
            return .none;
        },
        .detail_cursor_up => {
            if (model.detail_files.items.len == 0) return .none;
            if (model.detail_selected > 0) model.detail_selected -= 1;
            return .none;
        },
        .detail_select_file => return try handleDetailSelectFile(model),
        .detail_back_to_files => {
            // L4: 純粋な state 切替・R18 ゲート不要。
            model.detail_kind = .files;
            try model.setStr(&model.detail_diff, "");
            model.detail_diff_scroll = 0;
            model.clearDetailDiffOwner();
            return .none;
        },
        .detail_files_scroll_down => {
            if (model.detail_scroll < model.detail_files.items.len) model.detail_scroll += 1;
            return .none;
        },
        .detail_files_scroll_up => {
            if (model.detail_scroll > 0) model.detail_scroll -= 1;
            return .none;
        },
        .detail_diff_scroll_down => {
            // ★R13: detail_diff 行数未満へクランプ。空 diff は no-op（underflow 防止）。
            const total = diffLineCount(model.detail_diff);
            if (total == 0) return .none;
            if (model.detail_diff_scroll < total - 1) model.detail_diff_scroll += 1;
            return .none;
        },
        .detail_diff_scroll_up => {
            if (model.detail_diff_scroll > 0) model.detail_diff_scroll -= 1;
            return .none;
        },
        .log_select_index => |i| return try handleLogSelectIndex(model, i),
        .detail_select_index => |i| return try handleDetailSelectIndex(model, i),

        // --- 結果系 arms（R3 view_mode 検証 + H1 stale reject）---
        .log_loaded => |ll| return try handleLogLoaded(model, ll),
        .log_page_loaded => |ll| return try handleLogPageLoaded(model, ll),
        .log_page_failed => |lpf| return try handleLogPageFailed(model, lpf.request_generation, lpf.request_skip, lpf.error_text),
        .log_page_failed_silent => |lpfs| return try handleLogPageFailedSilent(model, lpfs.request_generation, lpfs.request_skip),
        .commit_detail_loaded => |cdl| return try handleCommitDetailLoaded(model, cdl),
        .detail_diff_loaded => |ddl| return try handleDetailDiffLoaded(model, ddl),

        // --- TODO 2 phase 3a: filter arms（spec §4.3/§4.4/§4.6/§4.7/§4.9）---
        .open_filter_modal => return try handleOpenFilterModal(model),
        .close_filter_modal => return try handleCloseFilterModal(model),
        .apply_filter => |text| return try handleApplyFilter(model, text),
        .clear_filter => return try handleClearFilter(model),
        .log_load_failed => |llf| return try handleLogLoadFailed(model, llf),
        .log_load_failed_silent => |llfs| return try handleLogLoadFailedSilent(model, llfs.request_generation),
    }
}

// =============================================================================
// TODO 2 phase 1: log/detail reducer arms（spec §1.6 権威・純粋・allocator 不要なら除く）
// =============================================================================

/// R2 空 guard: log_commits が空のとき detail 系状態を消去して `.none` を返す。
/// log_cursor_*/log_open_detail/log_select_index の先頭で使う（items[0]/len-1 panic 回避）。
/// 純粋。戻り値: 空なら true（呼び出し元は return .none すること）。
fn logEmptyGuard(model: *Model) !bool {
    if (model.log_commits.items.len == 0) {
        model.clearDetailOwner();
        try model.replaceDetailFiles(&.{});
        try model.setStr(&model.detail_diff, "");
        return true;
    }
    return false;
}

/// phase 3a M5: 全 load_log 発火 site の共通 builder。filter_state を clone して
/// 伝播漏れを防ぐ（apply_filter だけは payload-first で既に clone 済みのため直接構築）。
fn buildLoadLogCmd(model: *Model) !AppCmd {
    const filter = try model.filter_state.clone(model.allocator);
    return .{ .load_log = .{
        .skip = 0,
        .max_count = 100,
        .generation = model.log_request_generation,
        .filter = filter,
    } };
}

/// M5/R3: `toggle_view_mode` arm。changes→log で generation 更新＋log 初期化＋load_log 発火。
/// log→changes で generation 更新（遅延結果の無効化）＋refresh_status。
fn handleToggleViewMode(model: *Model) !AppCmd {
    switch (model.view_mode) {
        .changes => {
            model.view_mode = .log;
            model.focus = .changes; // ★M5 正規化（.commit から入っても .changes へ）
            model.log_request_generation += 1; // ★R3: 以前の遅延結果を無効化
            model.log_page_requested = null;
            model.log_has_more = false;
            // phase 2: 以前のグラフ状態・snapshot tip を破棄（新 log セッションへ）。
            model.invalidateLogGraph();
            model.clearLogSnapshotTip();
            model.clearDetailOwner();
            model.clearDetailDiffOwner();
            try model.replaceDetailFiles(&.{});
            try model.setStr(&model.detail_diff, "");
            return try buildLoadLogCmd(model);
        },
        .log => {
            model.view_mode = .changes;
            model.focus = .changes; // ★M5: 復元しない・固定
            model.log_request_generation += 1; // ★R3: 遅延 log 系結果を全て stale 化
            model.log_page_requested = null;
            // phase 2: log 系状態を破棄（changes へ戻るため）。
            model.invalidateLogGraph();
            model.clearLogSnapshotTip();
            return .refresh_status;
        },
    }
}

/// M1/R2/R17/R18: `log_cursor_down` arm。
/// - R2 空 guard → no-op。
/// - log_selected を末尾まで動かす。
/// - R17 paging trigger（has_more & 無要求 & len>=5 & selected>=len-5）→ load_log_page。
/// - R18 pending ゲート（page in-flight）→ .none（page 完了で log_page_loaded arm が detail 再発火）。
/// - それ以外 → setDetailOwnerHash + load_commit_detail（★R16 payload-first）。
fn handleLogCursorDown(model: *Model) !AppCmd {
    if (try logEmptyGuard(model)) return .none;
    const len = model.log_commits.items.len;
    if (model.log_selected + 1 < len) model.log_selected += 1;
    // ★R17 underflow 対策: len >= 5 を条件へ含めて len-5 の underflow を防ぐ。
    if (model.log_has_more and model.log_page_requested == null and len >= 5 and model.log_selected >= len - 5) {
        model.log_page_requested = len; // ★R11: 期待 skip を保持
        // phase 3a: tip_hash を log_snapshot_tip から dupe（未設定時は先頭 commit hash）。
        // filter_state も clone して LoadLogPage へ伝播（M5）。
        const tip_dup = try model.allocator.dupe(u8, model.log_snapshot_tip orelse model.log_commits.items[0].hash);
        errdefer model.allocator.free(tip_dup);
        const filter = try model.filter_state.clone(model.allocator);
        return .{ .load_log_page = .{
            .skip = len,
            .max_count = 100,
            .generation = model.log_request_generation,
            .tip_hash = tip_dup,
            .filter = filter,
        } };
    }
    // ★R18: page in-flight 中は load_commit_detail を発火しない（page 完了で自動発火）。
    if (model.log_page_requested != null) return .none;
    return try loadCommitDetailForSelection(model);
}

/// R2/R18: `log_cursor_up` arm。selected を減らし setDetailOwnerHash + load_commit_detail。
fn handleLogCursorUp(model: *Model) !AppCmd {
    if (try logEmptyGuard(model)) return .none;
    // ★R18: page in-flight 中は .none（page 完了で log_page_loaded arm が発火）。
    if (model.log_page_requested != null) return .none;
    if (model.log_selected > 0) model.log_selected -= 1;
    return try loadCommitDetailForSelection(model);
}

/// R2/R18: `log_open_detail` arm。現在選択 hash で明示的 detail 再取得。
fn handleLogOpenDetail(model: *Model) !AppCmd {
    if (try logEmptyGuard(model)) return .none;
    if (model.log_page_requested != null) return .none; // ★R18
    return try loadCommitDetailForSelection(model);
}

/// 現在の log_selected の hash を使って setDetailOwnerHash + load_commit_detail を発行する共通ヘルパ。
/// ★R16 payload-first: dupe 成功後に setDetailOwnerHash（OOM で owner が更新されるが cmd が返らない
///   「意味論不一致」を避ける）。呼び出し側で log_commits 非空・page 非in-flight を保証すること。
fn loadCommitDetailForSelection(model: *Model) !AppCmd {
    const hash = model.log_commits.items[model.log_selected].hash;
    const hash_dup = try model.allocator.dupe(u8, hash);
    errdefer model.allocator.free(hash_dup);
    try model.setDetailOwnerHash(hash); // ★R16: payload 構築成功後に owner 記録
    return .{ .load_commit_detail = hash_dup };
}

/// R2/R16/R18: `detail_select_file` arm。.files → .diff へ移行し load_detail_diff を発火。
/// ★R16 payload-first: hash/path の dupe を先に（errdefer）、成功後に setDetailDiffOwner。
fn handleDetailSelectFile(model: *Model) !AppCmd {
    if (model.detail_files.items.len == 0) return .none; // R2
    if (model.log_page_requested != null) return .none; // ★R18: page 中は diff 表示を遅延
    // ★R16: payload を先に構築（hash と path を dupe・errdefer でリークガード）。
    const hash_dup = try model.allocator.dupe(u8, model.log_commits.items[model.log_selected].hash);
    errdefer model.allocator.free(hash_dup);
    const path_dup = try model.allocator.dupe(u8, model.detail_files.items[model.detail_selected].path);
    errdefer model.allocator.free(path_dup);
    // 成功後: state 更新 + cmd 発行（所有権移譲）。
    model.detail_kind = .diff;
    try model.setDetailDiffOwner(hash_dup, path_dup); // 内部で dup するので hash_dup/path_dup を消費しない
    model.detail_diff_scroll = 0;
    // hash_dup/path_dup は load_detail_diff の所有へ。setDetailDiffOwner は別に dup 済み。
    return .{ .load_detail_diff = .{ .hash = hash_dup, .path = path_dup } };
}

/// R2/R14/R18: `log_select_index: |i|` arm。マウスクリックで選択移動＋focus=.changes。
/// 範囲内なら log_selected=i へ。その後 detail 再ロード経路へ（page 中は focus のみ更新）。
fn handleLogSelectIndex(model: *Model, i: usize) !AppCmd {
    if (try logEmptyGuard(model)) return .none;
    // ★R18: page in-flight 中は選択と focus だけ更新し detail ロードは page 完了後へ遅延。
    if (model.log_page_requested != null) {
        if (i < model.log_commits.items.len) model.log_selected = i;
        model.focus = .changes; // ★R14: クリックで left ペインへフォーカス
        return .none;
    }
    if (i < model.log_commits.items.len) model.log_selected = i;
    model.focus = .changes; // ★R14
    return try loadCommitDetailForSelection(model);
}

/// R14: `detail_select_index: |i|` arm。.files 中ならファイル選択＋focus=.diff。.diff 中は無視。
fn handleDetailSelectIndex(model: *Model, i: usize) !AppCmd {
    if (model.detail_kind == .files and i < model.detail_files.items.len) {
        model.detail_selected = i;
        model.focus = .diff; // ★R14: クリックで right ペインへフォーカス
    }
    // detail_kind == .diff のときは無視（diff 中はマウスクリックでファイル移動しない）。
    return .none;
}

/// M11/R3/R4: `request_refresh` arm（log モード時）。generation 更新＋状態クリア＋restore hash 退避。
fn handleRequestRefreshLog(model: *Model) !AppCmd {
    model.log_request_generation += 1; // ★R3
    model.log_page_requested = null;
    model.log_has_more = false;
    // phase 2: グラフ状態・paging tip を破棄（refresh 後に log_loaded で再構築）。
    model.invalidateLogGraph();
    model.clearLogSnapshotTip();
    // ★R4: 選択 hash を refresh 前に退避（空なら clear）。
    if (model.log_commits.items.len > 0) {
        try model.setLogRestoreHash(model.log_commits.items[model.log_selected].hash);
    } else {
        model.clearLogRestoreHash();
    }
    try model.replaceLogCommits(&.{}); // 一旦空へ
    model.clearDetailOwner();
    try model.replaceDetailFiles(&.{});
    try model.setStr(&model.detail_diff, "");
    model.detail_kind = .files;
    return try buildLoadLogCmd(model);
}

// =============================================================================
// 結果系 arms（H1 stale reject + R3 view_mode 検証）
// =============================================================================

/// R3: log モード外の結果は stale（mode 切替前の遅延）→ `.none`。
/// 全 log/detail 結果 arm の先頭で呼ぶ。
fn inLogMode(model: *const Model) bool {
    return model.view_mode == .log;
}

/// H1: optional string 同士の一致判定（detail_owner_hash vs request_hash 等）。
/// どちらかが null、または slice 内容不一致で false。
fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    const aa = a orelse return b == null;
    const bb = b orelse return false;
    return std.mem.eql(u8, aa, bb);
}

/// H1/H3/M3/R4: `log_loaded` arm（初回ロード結果）。
/// - stale reject: view_mode / generation / skip==0 のいずれか不一致で破棄。
/// - 適用: replaceLogCommits → R4 restore hash で選択復元 → log_has_more 設定 → R2 空 guard →
///   setDetailOwnerHash + load_commit_detail。
fn handleLogLoaded(model: *Model, ll: msgs.Msg.LogLoaded) !AppCmd {
    // ★R3/H1: stale reject。
    if (!inLogMode(model)) return .none;
    if (ll.request_generation != model.log_request_generation) return .none;
    if (ll.request_skip != 0) return .none;
    try model.replaceLogCommits(ll.entries);
    // ★B1: snapshot_tip を appcmd が解決した request_tip から dupe 保存。
    //   OOM は安全側へ clearLogSnapshotTip して継続（次回 LoadLog で再解決）。
    model.setLogSnapshotTip(ll.request_tip) catch {
        model.clearLogSnapshotTip();
    };
    // ★R4: 退避 hash があれば選択を hash 一致で復元（無ければ 0）。
    if (model.log_restore_hash) |h| {
        var found: ?usize = null;
        for (model.log_commits.items, 0..) |c, idx| {
            if (std.mem.eql(u8, c.hash, h)) {
                found = idx;
                break;
            }
        }
        model.log_selected = found orelse 0;
        model.clearLogRestoreHash();
    } else {
        model.log_selected = 0;
    }
    // M3: log_has_more = (entries.len >= request_max_count)
    model.log_has_more = ll.entries.len >= ll.request_max_count;
    model.log_page_requested = null;
    model.detail_kind = .files;
    // ★M-N8: 成功時は前回の log_load_error をクリア（commits 更新と同一トランザクション）。
    model.setLogLoadError("") catch {};
    // R2 空 guard。
    if (model.log_commits.items.len == 0) {
        model.clearDetailOwner();
        try model.replaceDetailFiles(&.{});
        return .none;
    }
    // ★B2: graph_render_policy==.suppressed なら graph 計算をスキップ（log_graph_state は触らない）。
    if (model.graph_render_policy != .suppressed) {
        const tip_const: ?[]const u8 = if (model.log_snapshot_tip) |t| t else null;
        const gs = graph_mod.computeAll(model.allocator, model.log_commits.items, model.log_request_generation, tip_const) catch {
            model.invalidateLogGraph();
            return try loadCommitDetailForSelection(model);
        };
        model.setLogGraphState(gs);
    }
    return try loadCommitDetailForSelection(model);
}

/// H1/H3/M3/R10/R11/R22/H-07/M-11: `log_page_loaded` arm（追加ページ結果）。
/// - stale reject: view_mode / generation / skip==log_page_requested / request_tip==log_snapshot_tip のいずれか不一致で破棄。
/// - ★R22: log_page_requested を appendLogCommits の**前に** null 化（OOM でも paging 再試行可能）。
/// - phase 2 M-11: グラフ計算（.valid→incremental / .invalid→computeAll）。OOM で .invalid へ。
/// - R10: 非空なら load_commit_detail で選択/detail 整合性を回復。
fn handleLogPageLoaded(model: *Model, lpl: msgs.Msg.LogPageLoaded) !AppCmd {
    // ★R3/H1/R11: stale reject（期待 skip は model.log_page_requested と照合）。
    if (!inLogMode(model)) return .none;
    if (lpl.request_generation != model.log_request_generation) return .none;
    const expected_skip = model.log_page_requested orelse return .none; // 既に別経路で消化済み
    if (lpl.request_skip != expected_skip) return .none;
    // H-07: request_tip 照合。log_snapshot_tip と一致しなければ（tip が移動した等）破棄。
    if (model.log_snapshot_tip) |tip| {
        if (!std.mem.eql(u8, tip, lpl.request_tip)) return .none;
    } else {
        // log_snapshot_tip 未設定は初回 log_loaded 未到達か clear 済み → 破棄。
        return .none;
    }
    // ★R22: appendLogCommits の前に page_requested を null 化（OOM で reducer が error return
    //   しても page_requested は既に null・次回 down で再試行可能）。
    model.log_page_requested = null;
    try model.appendLogCommits(lpl.entries);
    model.log_has_more = lpl.entries.len >= lpl.request_max_count;
    // ★R10: 選択が存在すれば load_commit_detail で選択/detail 整合性を回復。
    if (model.log_commits.items.len == 0) return .none;
    // ★B2: graph_render_policy==.suppressed なら graph 計算をスキップ。
    if (model.graph_render_policy == .suppressed) {
        return try loadCommitDetailForSelection(model);
    }
    // phase 2 M-11: graph computation（.valid→incremental / .invalid→computeAll）。
    //   computeIncremental は *GraphState を消費して .invalid へ遷移させる（所有権移行）。
    //   失敗時は強例外保証で入力 state を触らないため、catch で invalidateLogGraph へ。
    switch (model.log_graph_state) {
        .valid => {
            const new_state = graph_mod.computeIncremental(model.allocator, &model.log_graph_state, lpl.entries) catch {
                model.invalidateLogGraph();
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(new_state);
        },
        .invalid => {
            const tip_const: ?[]const u8 = if (model.log_snapshot_tip) |t| t else null;
            const gs = graph_mod.computeAll(model.allocator, model.log_commits.items, model.log_request_generation, tip_const) catch {
                // OOM でも .invalid のまま継続（commits は append 済み・表示は継続）。
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(gs);
        },
    }
    return try loadCommitDetailForSelection(model);
}

/// H2/R7/R11: `log_page_failed` arm。page_requested を下ろし error_text を設定。
fn handleLogPageFailed(model: *Model, request_generation: u64, request_skip: usize, error_text: []const u8) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (request_generation != model.log_request_generation) return .none;
    // ★R11: page_requested が既に別 skip に切り替わっていれば破棄（一致時のみ処理）。
    if (model.log_page_requested) |rp| {
        if (request_skip != rp) return .none;
    } else {
        // page_requested が null のときは既に消化済みかキャンセル済み → 破棄。
        return .none;
    }
    model.log_page_requested = null;
    // phase 3a MINOR2/M3: bad revision recovery。次回 LoadLog で snapshot_tip を再解決させる。
    model.clearLogSnapshotTip();
    try model.setStr(&model.error_text, error_text);
    return .none;
}

/// R21: `log_page_failed_silent` arm。log_page_failed と同じだが error_text 設定なし。
fn handleLogPageFailedSilent(model: *Model, request_generation: u64, request_skip: usize) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (request_generation != model.log_request_generation) return .none;
    if (model.log_page_requested) |rp| {
        if (request_skip != rp) return .none;
    } else {
        return .none;
    }
    model.log_page_requested = null;
    return .none;
}

// =============================================================================
// TODO 2 phase 3a: filter / log_load_failed arms（spec §4.3/§4.4/§4.6/§4.7/§4.9）
// =============================================================================

/// §4.4: `apply_filter` arm（payload-first トランザクショナル・M4/M-N7）。
/// payload から FilterSpec を 1 つ構築 → Model へ swap → AppCmd 用は swap 後から clone。
/// 強例外保証: clone OOM で clearFilterState へ戻す（旧 filter_state は swap 時に失われているため復元不可）。
fn handleApplyFilter(model: *Model, payload: []u8) !AppCmd {
    const a = model.allocator;
    var new_spec = FilterSpec.init();
    errdefer new_spec.deinit(a);
    new_spec.setAuthor(a, payload) catch |err| switch (err) {
        error.AuthorTooLong => {
            try model.setLogLoadError("作者名が長すぎます（256 Unicode scalar まで）");
            return .none;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    // swap: new_spec の所有権を Model へ移譲（setFilterState 内で旧を deinit）。以降 new_spec は触らない。
    model.setFilterState(new_spec);
    // AppCmd 用は swap 後の model.filter_state から clone（Model と AppCmd が常に一致）。
    var cmd_spec = model.filter_state.clone(a) catch {
        // 強例外保証: clone 失敗時は空 filter へ戻す。
        model.clearFilterState();
        try model.setLogLoadError("フィルタ適用に失敗（メモリ不足）");
        return .none;
    };
    errdefer cmd_spec.deinit(a);
    // commit phase（全て非失敗操作）。
    model.filter_modal_open = false;
    model.log_request_generation += 1; // ★R3/M3: 旧結果を stale 化
    model.log_page_requested = null;
    model.log_has_more = false;
    model.clearLogSnapshotTip(); // ★B1: 次 LoadLog で再解決
    model.graph_render_policy = .suppressed; // ★B2
    model.invalidateLogGraph();
    model.clearDetailOwner();
    try model.replaceDetailFiles(&.{});
    try model.setStr(&model.detail_diff, "");
    model.setLogLoadError("") catch {};
    try model.replaceLogCommits(&.{});
    return .{ .load_log = .{
        .skip = 0,
        .max_count = 100,
        .generation = model.log_request_generation,
        .filter = cmd_spec,
    } };
}

/// §4.6: `clear_filter` arm。filter 解除・graph 復活・全件再取得。
fn handleClearFilter(model: *Model) !AppCmd {
    model.clearFilterState();
    model.filter_modal_open = false;
    model.log_request_generation += 1;
    model.log_page_requested = null;
    model.log_has_more = false;
    model.clearLogSnapshotTip();
    model.graph_render_policy = .auto; // ★B2: graph 復活
    model.invalidateLogGraph();
    model.clearDetailOwner();
    try model.replaceDetailFiles(&.{});
    try model.setStr(&model.detail_diff, "");
    model.setLogLoadError("") catch {};
    try model.replaceLogCommits(&.{});
    return try buildLoadLogCmd(model);
}

/// §4.7: `open_filter_modal` arm。flag を立てるのみ（TextInput へは reducer 非到達・main が同期）。
fn handleOpenFilterModal(model: *Model) !AppCmd {
    model.filter_modal_open = true;
    return .none;
}

/// §4.7: `close_filter_modal` arm。flag を下ろすのみ。
fn handleCloseFilterModal(model: *Model) !AppCmd {
    model.filter_modal_open = false;
    return .none;
}

/// §4.3: `log_load_failed` arm（B4/M3）。初回 LoadLog 失敗の typed Msg。
/// generation 照合で受理 → log_load_error へ保存・commits 空化。
fn handleLogLoadFailed(model: *Model, llf: msgs.Msg.LogLoadFailed) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (llf.request_generation != model.log_request_generation) return .none;
    try model.setLogLoadError(llf.error_text);
    model.log_page_requested = null;
    try model.replaceLogCommits(&.{});
    model.clearDetailOwner();
    try model.replaceDetailFiles(&.{});
    try model.setStr(&model.detail_diff, "");
    // ★B1: snapshot_tip は request_tip があれば保存（次回 page で使える可能性）・無ければクリア。
    if (llf.request_tip) |tip| {
        model.setLogSnapshotTip(tip) catch model.clearLogSnapshotTip();
    } else {
        model.clearLogSnapshotTip();
    }
    return .none;
}

/// §4.3: `log_load_failed_silent` arm。OOM 極限・generation 照合のみ。
fn handleLogLoadFailedSilent(model: *Model, request_generation: u64) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (request_generation != model.log_request_generation) return .none;
    return .none;
}

/// H1/R3: `commit_detail_loaded` arm。detail_owner_hash 一致判定で stale reject。
fn handleCommitDetailLoaded(model: *Model, cdl: msgs.Msg.CommitDetailLoaded) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (!optEql(model.detail_owner_hash, cdl.request_hash)) return .none;
    try model.replaceDetailFiles(cdl.entries);
    model.detail_selected = 0;
    model.detail_kind = .files;
    return .none;
}

/// H1/R3: `detail_diff_loaded` arm。detail_diff_owner hash/path 二重一致で stale reject。
fn handleDetailDiffLoaded(model: *Model, ddl: msgs.Msg.DetailDiffLoaded) !AppCmd {
    if (!inLogMode(model)) return .none;
    if (!optEql(model.detail_diff_owner_hash, ddl.request_hash)) return .none;
    if (!optEql(model.detail_diff_owner_path, ddl.request_path)) return .none;
    try model.setStr(&model.detail_diff, ddl.text);
    model.detail_diff_scroll = 0;
    return .none;
}


/// 一致しない（ファイル切替・外部プロセスで selected が別へクランプ・初回ロード前）は false。
/// 純粋・allocator 不要。層 1（codex B1 対策）。
fn isDiffOwnerCurrent(model: *const Model) bool {
    const owner = model.diff_owner orelse return false;
    if (model.files.items.len == 0) return false;
    if (model.selected >= model.files.items.len) return false;
    const f = model.files.items[model.selected];
    return f.section == owner.section and std.mem.eql(u8, f.path, owner.path);
}

/// 選択レンジから apply_patch AppCmd を構築する共通ヘルパ（stage_lines / stage_hunk 共用）。
/// 純粋（Model を read-only で参照・error_text のみ setStr で変更）。
/// - rename ガードは呼び出し側で済ませること（本関数は f.orig_path を見ない）。
/// - 戻り値: `.apply_patch`（成功）または `.none`（null パッチ時は error_text をセット）。
/// ★本関数は model.diff_anchor を clear しない。呼び出し側が消費後に clear する（責務分離）。
/// 注: sel 引数に匿名 struct を使うと model.selectionRange の戻り値型と型不一致になるため、
///   lo/hi を個別パラメータで受ける（Zig の構造体同一性は宣言位置依存）。
fn buildStagePatchFromSelection(
    model: *Model,
    parsed: hunk.ParsedDiff,
    idx: usize,
    lo: usize,
    hi: usize,
) !AppCmd {
    const f = model.files.items[model.selected];
    const maybe = try hunk.buildLinePatch(model.allocator, parsed, idx, lo, hi, f.section == .staged);
    if (maybe) |patch| {
        errdefer model.allocator.free(patch);
        const gd: ?[]u8 = if (model.git_dir) |g| try model.allocator.dupe(u8, g) else null;
        errdefer if (gd) |x| model.allocator.free(x);
        return .{ .apply_patch = .{
            .patch = patch,
            .reverse = (f.section == .staged),
            .git_dir = gd,
        } };
    }
    try model.setStr(&model.error_text, "選択範囲を stage できません（変更行なし、または末尾改行境界）");
    return .none;
}

/// diff 再読込/カーソル移動後にカーソルを本文行へ正規化し、anchor を**検証**する（純粋）。
/// - ハンク 0 個: cursor=0, anchor=null。
/// - カーソルが本文行でない（file_header / @@ ヘッダ行 / 範囲外）: 先頭ハンク本文先頭へ。
/// - 既にいずれかのハンク本文内: そのまま維持（リフレッシュ時のジャンプ防止）。
/// anchor は「(a) 本文行、(b) cursor と同じハンク」を両方満たすときだけ保持。それ以外は null。
/// ★層 2（Bug 1 修正）: 無条件 clear すると v → j → s の間に auto-refresh が走っただけで
///   選択が消える（TODO 1 ブロッカー）。ユーザー能動的なファイル切替（key_down/up/select_index/
///   diff_hunk_next/prev）は各 arm が明示的に anchor を clear するため、ここでの clear は
///   それら経路では冗長だった。層 1（isDiffOwnerCurrent）でファイル同一性を確認した上で呼ばれる。
fn clampCursor(model: *Model) !void {
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    if (parsed.hunks.len == 0) {
        model.diff_cursor = 0;
        model.diff_anchor = null; // ハンク無しでは選択は無意味
        return;
    }
    // カーソルが本文行でない（@@ ヘッダ/file_header/範囲外）なら先頭ハンク本文先頭へ再配置。
    // 本文内ならジャンプ防止で維持。
    if (!isBodyLine(parsed, model.diff_cursor)) {
        model.diff_cursor = hunkBodyTop(parsed.hunks[0]);
    }
    // 層 2: anchor 検証。cursor 再配置後に検証するので、新しい cursor ハンクと anchor ハンクが
    // 一致すれば保持（ユーザが v で作った選択を cursor ズレだけで消さない）。
    model.diff_anchor = validateAnchor(parsed, model.diff_cursor, model.diff_anchor);
}

/// anchor が「(a) 本文行」「(b) cursor と同じハンク」を両方満たすかを検証し、満たすならそのまま
/// 返し、満たさない（または anchor==null）なら null を返す。純粋・allocator 不要。層 2。
///
/// cond-a の 2 段チェックは非冗長: `isBodyLine` は @@ ヘッダ行（start_line に等しい行）を拒否するが、
/// `hunkIndexForLine` は @@ ヘッダ行に対して non-null（[start_line, start_line+line_count) に含まれる）
/// を返す。よって isBodyLine=true を通過した anchor は必ずハンク内本文行であり、後続の
/// hunkIndexForLine は non-null になることが保証される。2 つめの orelse return null は到達不能だが、
/// isBodyLine と hunkIndexForLine の契約が独立しているため防御的に残す（subagent N1 訂正）。
fn validateAnchor(parsed: hunk.ParsedDiff, cursor: usize, anchor: ?usize) ?usize {
    const a = anchor orelse return null;
    if (!isBodyLine(parsed, a)) return null; // (a) 本文行でない（@@ ヘッダ/file_header/範囲外）
    const a_hunk = hunk.hunkIndexForLine(parsed, a) orelse return null; // isBodyLine=true なら必ず non-null（到達不能ガード）
    const c_hunk = hunk.hunkIndexForLine(parsed, cursor) orelse return null; // cursor が本文でない（clampCursor で本文へ正規化済みだが念のため）
    if (a_hunk != c_hunk) return null; // (b) 異ハンク
    return a;
}

/// 絶対行 `abs` が「本文行」（いずれかのハンク内 かつ @@ ヘッダ行でない）かを返す。
fn isBodyLine(parsed: hunk.ParsedDiff, abs: usize) bool {
    if (hunk.hunkIndexForLine(parsed, abs)) |i| return abs != parsed.hunks[i].start_line;
    return false;
}

/// ハンク `h` の本文先頭行（@@ の次の行）。本文が無い（line_count==1）なら @@ 行自身。
/// カーソル配置の唯一の基準（diff_hunk_next/prev・clampCursor が共有）。
/// 注: 実 git diff はヘッダのみのハンク（line_count==1）を出さない（本文 >=1 行）ため、
/// 通常この else 枝には入らない。退化入力でも下流は kept_changes==0 で安全 no-op。
fn hunkBodyTop(h: hunk.Hunk) usize {
    return if (h.line_count > 1) h.start_line + 1 else h.start_line;
}

/// 下方向カーソル移動の排他的上限（絶対行）。選択中（anchor あり）は anchor のハンク末尾、
/// 非選択時は最終ハンク末尾。これによりカーソルは選択中に anchor のハンクを越えない。
/// 呼び出し側で parsed.hunks.len > 0 を保証すること。
fn navHunkEnd(parsed: hunk.ParsedDiff, anchor: ?usize) usize {
    if (anchor) |anc| {
        const h = parsed.hunks[hunk.hunkIndexForLine(parsed, anc) orelse 0];
        return h.start_line + h.line_count;
    }
    const last = parsed.hunks[parsed.hunks.len - 1];
    return last.start_line + last.line_count;
}

/// diff_text の行数を数える純粋関数。
/// ★MUST match view.zig renderDiff total_lines counting: 両サイトの同期が崩れると
///   表示とスクロール上限がズレて制約4と同種のバグが再発する。変更時は両方直すこと。
/// splitScalar は trailing newline があれば空トークンを1つ追加するため、
/// 例えば "a\nb\nc\n" は4トークン（"a","b","c",""）を返す。view.zig も同じ計算なので一致する。
fn diffLineCount(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| n += 1;
    return n;
}

/// 現在選択中のファイルの diff を読み込む AppCmd を返す。
/// ファイルが無ければ diff_text を空にして .none。
fn loadDiffCmd(model: *Model) !AppCmd {
    if (model.files.items.len == 0) {
        try model.setStr(&model.diff_text, "");
        model.clearDiffOwner(); // ファイル無し → diff_owner も無し（層 1）
        return .none;
    }
    const f = model.files.items[model.selected];
    // ★codex レビュー B1 対策: payload の dupe を先に行い、errdefer でリークガード。
    //   path の dupe 成功後に orig_path の dupe が OOM になると path が漏れるため。
    //   また setDiffOwner（副作用）は payload 構築成功後に呼ぶ（OOM で diff_owner が更新
    //   されるが load_diff が返らない「意味論不一致」を避けるため）。
    const path_dup = try model.allocator.dupe(u8, f.path);
    errdefer model.allocator.free(path_dup);
    const orig_dup: ?[]u8 = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null;
    errdefer if (orig_dup) |o| model.allocator.free(o);
    try model.setDiffOwner(f.path, f.section); // ★層 1: payload 構築成功後にオーナーを記録
    return .{ .load_diff = .{
        .path = path_dup,
        .orig_path = orig_dup,
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
    try m.setStr(&m.diff_text, "a\nb\nc\n"); // 4トークン（trailing 含む）→ cap 3。+=1 が従来どおり起きる。
    var c1 = try update(&m, .scroll_diff_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.diff_scroll);
    var c2 = try update(&m, .scroll_diff_up);
    c2.deinit(a);
    var c3 = try update(&m, .scroll_diff_up);
    c3.deinit(a); // 0 で止まる
    try std.testing.expectEqual(@as(usize, 0), m.diff_scroll);
}

test "scroll_diff_down stops at diffLineCount(text) - 1 (constraint 4 root fix)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 4トークン（a,b,c,""）→ cap 3。5回叩いても 3 で止まる。
    try m.setStr(&m.diff_text, "a\nb\nc\n");
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var c = try update(&m, .scroll_diff_down);
        c.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), m.diff_scroll);
}

test "scroll_diff_down on empty diff_text is no-op (no underflow)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // diff_text 未設定（空文字列=1トークン）→ cap 0。+=1 は起きない。
    var c = try update(&m, .scroll_diff_down);
    c.deinit(a);
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

test "diffLineCount counts splitScalar tokens (trailing newline yields extra empty)" {
    // 空文字列: splitScalar は空トークン1つを返す。Task10 の no-op テストが依存する挙動。
    try std.testing.expectEqual(@as(usize, 1), diffLineCount(""));
    // "a\nb\nc\n": splitScalar は a, b, c, "" の4トークン。
    try std.testing.expectEqual(@as(usize, 4), diffLineCount("a\nb\nc\n"));
    // "a\nb\nc": 末尾改行無し → 3 トークン。
    try std.testing.expectEqual(@as(usize, 3), diffLineCount("a\nb\nc"));
    // 単一行: 1 トークン。
    try std.testing.expectEqual(@as(usize, 1), diffLineCount("(no diff)"));
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

test "cursor stays within anchor's hunk while selecting (no cross-hunk selection)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 本文 4-6, h1 本文 8-10
    // 選択中（anchor=h0 内）はカーソルが h1 へ越えない。
    m.diff_cursor = 6; // h0 末尾本文 '+B'
    m.diff_anchor = 5; // h0 内
    var c1 = try update(&m, .diff_cursor_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // h1(8) へ移らず据え置き
    // anchor を外すと次ハンクへ自由移動。
    m.diff_anchor = null;
    var c2 = try update(&m, .diff_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor); // h1 本文先頭
    // 上方向も anchor のハンク本文先頭で止まり h0 へ越えない。
    m.diff_cursor = 9; // h1 '+Y'
    m.diff_anchor = 9; // h1
    var c3 = try update(&m, .diff_cursor_up);
    c3.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor); // h1 本文先頭 ' x'
    var c4 = try update(&m, .diff_cursor_up); // これ以上 h0 へ越えない
    c4.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor);
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
    m.diff_anchor = 4; // 選択あり → null パスでも消費されること
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択ハイライトを残さない
    try std.testing.expect(m.error_text.len > 0);
}

test "stage_lines on untracked builds apply_patch (reverse=false) for partial stage" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "new.txt", .untracked);
    // untracked の diff（--no-index 形式・全行挿入）を直接セット。
    try m.setStr(&m.diff_text,
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n");
    m.diff_cursor = 7; // +L2 の絶対行（file_header 5 行 + @@ が行5, +L1=6, +L2=7, +L3=8）
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse); // untracked は reverse=false
    // 選択行 L2 のみパッチへ含まれ、L1/L3 は含まれない。
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L3\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -0,0 +1,1 @@") != null);
}

test "stage_lines on 2 RM unstaged entry (orig_path=null) builds apply_patch (reverse=false)" {
    // spec 2026-06-17-rename-hunk-stage-design.md §3.4: 2 RM の unstaged 側は
    // orig_path == null なので現行ガードを通過し、buildLinePatch(reverse=false) へ進む。
    // これが本タスクの核心「2 RM の部分 stage は現状で動く」の回帰保護。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 RM 展開後の unstaged エントリ: path=new.txt, orig_path=null, section=.unstaged
    // （addFile ヘルパは orig_path=null 固定なのでそのまま使える）
    try addFile(&m, "new.txt", .unstaged);
    // git mv 済み状態の unstaged 側 diff（rename ヘッダ無し・content-only）
    try m.setStr(&m.diff_text,
        "diff --git a/new.txt b/new.txt\n" ++
        "index 9405325..6fe8acc 100644\n" ++
        "--- a/new.txt\n" ++
        "+++ b/new.txt\n" ++
        "@@ -1,5 +1,5 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+X\n" ++
        " c\n" ++
        " d\n" ++
        " e\n");
    m.diff_cursor = 7; // +X の絶対行（file_header 4 行 + @@ が行4, ' a'=5, '-b'=6, '+X'=7）
    m.diff_anchor = 7;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse); // unstaged → forward
    // 選択行 +X のみ保持。未選択 -b は文脈化（' b'）され、元の -b としては残らない。
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+X\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "-b\n") == null);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択消費
    try std.testing.expect(m.error_text.len == 0); // ガードメッセージ無し
}

test "stage_lines on staged rename entry (orig_path!=null, section=staged) is guarded" {
    // spec 2026-06-17-rename-hunk-stage-design.md §3.4: staged rename 側はガード維持。
    // 2 R.（rename+内容変更が両方 staged）からの部分 unstage は git の apply --cached --reverse が
    // index を破綻させるため（spec §2 実験3）、ファイル単位 unstage を案内するガードを残す。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // staged rename エントリ: path=new.txt, orig_path=old.txt, section=.staged
    try m.files.append(m.allocator, .{
        .path = try m.allocator.dupe(u8, "new.txt"),
        .orig_path = try m.allocator.dupe(u8, "old.txt"),
        .section = .staged,
    });
    try m.setStr(&m.diff_text,
        "diff --git a/old.txt b/new.txt\n" ++
        "similarity index 80%\n" ++
        "rename from old.txt\n" ++
        "rename to new.txt\n" ++
        "index 92dfa21..e1da833 100644\n" ++
        "--- a/old.txt\n" ++
        "+++ b/new.txt\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+X\n" ++
        " c\n");
    m.diff_cursor = 9; // -b の絶対行（file_header 7 行 + @@ 行7, ' a'=8, '-b'=9）
    m.diff_anchor = 9;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none); // ガードでブロック
    try std.testing.expect(m.error_text.len > 0); // ガイドメッセージ
    try std.testing.expect(std.mem.indexOf(u8, m.error_text, "rename") != null);
}

test "stage_lines on 2 .R unstaged entry (orig_path!=null, section=unstaged) is guarded" {
    // spec 2026-06-17-rename-hunk-stage-design.md §3.4・§4 リスクA:
    // 2 .R（worktree rename・orig_path != null）の部分 stage は diff が rename ヘッダを含み
    // 部分パッチ生成が未検証のためガード維持。当初案の section==.staged 絞り込みを破棄したことで
    // このパスが開放されないことを固定化する。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 .R の unstaged エントリ: path=new.txt, orig_path=old.txt, section=.unstaged
    try m.files.append(m.allocator, .{
        .path = try m.allocator.dupe(u8, "new.txt"),
        .orig_path = try m.allocator.dupe(u8, "old.txt"),
        .section = .unstaged,
    });
    try m.setStr(&m.diff_text,
        "diff --git a/old.txt b/new.txt\n" ++
        "similarity index 80%\n" ++
        "rename from old.txt\n" ++
        "rename to new.txt\n" ++
        "index 92dfa21..e1da833 100644\n" ++
        "--- a/old.txt\n" ++
        "+++ b/new.txt\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+X\n" ++
        " c\n");
    m.diff_cursor = 9;
    m.diff_anchor = 9;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none); // ガードでブロック
    try std.testing.expect(m.error_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, m.error_text, "rename") != null);
}

test "stage_lines guards: busy" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.busy = true;
    var c = try update(&m, .stage_lines);
    defer c.deinit(a);
    try std.testing.expect(c == .none);
}

test "diff_loaded clamps cursor into a hunk body and validates anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.diff_cursor = 999;
    m.diff_anchor = 3; // @@ ヘッダ行 (start_line==3) → isBodyLine=false → cond-a fail → null 化
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

test "loadDiffCmd records diff_owner for selected file (Layer 1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    // toggle_stage ではなく直接 status_loaded 経由で loadDiffCmd を起動する。
    // 1件のファイル → selected=0 → loadDiffCmd が diff_owner を selected ファイルへ記録する。
    // Msg.status_loaded は []StatusEntry（所有・mutable）なので var 配列から coerse する。
    var e = [_]@import("git/status.zig").StatusEntry{
        .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e) |entry| a.free(entry.path);
    var cmd = try update(&m, .{ .status_loaded = &e });
    defer cmd.deinit(a); // load_diff を返す
    // status_loaded → replaceFiles → loadDiffCmd で diff_owner が selected ファイルへ記録される
    try std.testing.expect(m.diff_owner != null);
    try std.testing.expectEqualStrings("f.txt", m.diff_owner.?.path);
    try std.testing.expectEqual(@import("git/status.zig").Section.unstaged, m.diff_owner.?.section);
}

test "loadDiffCmd clears diff_owner when files empty (Layer 1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 手動で diff_owner を設定（ファイル無しの状態）
    try m.setDiffOwner("stale.txt", .unstaged);
    // status_loaded で空エントリ → replaceFiles で files 空 → loadDiffCmd で diff_owner クリア
    var cmd = try update(&m, .{ .status_loaded = &.{} });
    cmd.deinit(a); // .none を返す（ファイル無し）
    try std.testing.expect(m.diff_owner == null);
}

test "isDiffOwnerCurrent: null owner returns false (first load)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    // diff_owner 未設定
    try std.testing.expect(!isDiffOwnerCurrent(&m));
}

test "isDiffOwnerCurrent: matching section+path returns true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try m.setDiffOwner("f.txt", .unstaged);
    try std.testing.expect(isDiffOwnerCurrent(&m));
}

test "isDiffOwnerCurrent: section change (partial stage) returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .staged); // 部分 stage 後の staged エントリ
    try m.setDiffOwner("f.txt", .untracked); // 発行時は untracked だった
    try std.testing.expect(!isDiffOwnerCurrent(&m));
}

test "isDiffOwnerCurrent: path change returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "g.txt", .unstaged);
    try m.setDiffOwner("f.txt", .unstaged); // 別ファイル
    try std.testing.expect(!isDiffOwnerCurrent(&m));
}

test "Bug 1 Layer 1: diff_loaded clears anchor when selected file changed (codex B1)" {
    // f.txt 選択中に anchor=5 → 外部プロセスで f.txt が消え g.txt へ切替 →
    // owner は f.txt のまま（loadDiffCmd を経由せず直接 selected を変えたレース）。
    // この状態で diff_loaded が届くと層 1 が anchor を消す。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try addFile(&m, "g.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    m.diff_anchor = 5;
    // owner を f.txt のまま記録（loadDiffCmd 相当）
    try m.setDiffOwner("f.txt", .unstaged);
    // selected を g.txt(1) へ（外部プロセスで f.txt が消えた等）。owner は更新しない。
    m.selected = 1;
    // g.txt の diff_loaded が届いたとする（テストでは同じ diff_text を再利用）
    const diff_copy = try a.dupe(u8, m.diff_text);
    defer a.free(diff_copy);
    var cmd = try update(&m, .{ .diff_loaded = diff_copy });
    cmd.deinit(a);
    // ★層 1: owner(f.txt) != selected(g.txt) → anchor clear
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "validateAnchor: null anchor stays null" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4-6, h1 body 8-10
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, null));
}

test "validateAnchor: anchor on @@ header is cleared (cond-a fail)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // @@h0 = 行3
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, 3));
}

test "validateAnchor: anchor on file_header is cleared (cond-a fail)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // file_header = 行0-2
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, 1));
}

test "validateAnchor: anchor on different hunk from cursor is cleared (cond-b fail)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4-6, h1 body 8-10
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    // cursor=h0(行5), anchor=h1(行9) → 異ハンク → null
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, 9));
}

test "validateAnchor: anchor on body line in same hunk as cursor is kept (both pass)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4-6
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    // cursor=行5, anchor=行6 → 同 h0 本文 → 保持
    try std.testing.expectEqual(@as(?usize, 6), validateAnchor(parsed, 5, 6));
    // cursor=行6, anchor=行5 → 同 h0 本文 → 保持
    try std.testing.expectEqual(@as(?usize, 5), validateAnchor(parsed, 6, 5));
}

test "select_line_at still clears anchor after Bug 1 fix (regression)" {
    // マウスクリックは明示的選択解除。clampCursor が anchor を保持するようになっても
    // select_line_at 単独で anchor を clear する。同じハンク内へクリックしたケースで検証
    // （異ハンクなら cond-b が消すため、同一ハンクのときだけ explicit clear が必須）。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4,5,6
    m.diff_cursor = 4;
    m.diff_anchor = 5; // 選択あり（h0 内）
    // 同じ h0 内の行6 へクリック（cond-b は pass してしまう → explicit clear が必須）
    var cmd = try update(&m, .{ .select_line_at = 6 });
    cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
    try std.testing.expect(m.focus == .diff);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // ★explicit clear が無いと残る
}

test "Bug 1 e2e: range selection survives diff_loaded (auto-refresh simulation)" {
    // v → j → (auto-refresh が diff_loaded を発火) → s で範囲 stage されること。
    // ★層 1（diff_owner 一致）+ 層 2（validateAnchor 通過）の両方を検証。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6 (' a'/-b/+B)

    // 層 1 セットアップ: diff_owner を "f.txt"/.unstaged へ設定。
    // 実機では loadDiffCmd（status_loaded → load_diff）がこれを行う。テストでは直接 setup。
    try m.setDiffOwner("f.txt", .unstaged);

    // 1) v で選択開始 (cursor=5 → anchor=5)
    m.diff_cursor = 5;
    var c1 = try update(&m, .toggle_line_selection);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor);

    // 2) j で選択拡張 (cursor=5 → 6)
    var c2 = try update(&m, .diff_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor); // 選択維持

    // 3) auto-refresh シミュレーション: 同じ diff_text で diff_loaded を再送
    //    （main.zig の maybeAutoRefresh → status_loaded → load_diff → diff_loaded と同効果）
    //    ★層 1: diff_owner("f.txt"/.unstaged) == selected ファイル → 一致 → anchor 保持へ進む
    //    ★層 2: validateAnchor が anchor=5(h0 本文) と cursor=6(同 h0) を確認 → 保持
    const same_diff = try a.dupe(u8, m.diff_text);
    defer a.free(same_diff);
    var c3 = try update(&m, .{ .diff_loaded = same_diff });
    c3.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor); // ★Bug 1 の核心: 保持される
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);

    // 4) s で stage → 選択範囲 [5,6] がパッチへ含まれること（単一行ではなく 2 行分）
    //    ★Bug 1 無修正なら anchor が diff_loaded で null 化し、selectionRange(6,null)={6,6}
    //      なので '-b' は未選択→文脈化(' b')されてパッチから消え、'+B' のみ残る。
    //      修正後は anchor=5 保持で selectionRange(6,5)={5,6} となり、'-b' も選択→保持される。
    var c4 = try update(&m, .stage_lines);
    defer c4.deinit(a);
    try std.testing.expect(c4 == .apply_patch);
    try std.testing.expect(std.mem.indexOf(u8, c4.apply_patch.patch, "+B\n") != null); // 選択された追加行
    try std.testing.expect(std.mem.indexOf(u8, c4.apply_patch.patch, "-b\n") != null); // 選択された削除行（文脈化されず保持）
}

test "select_hunk sets anchor=body top, cursor=body bottom, focus=diff" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6, h1 本文 8-10
    m.diff_cursor = 5; // h0 本文
    m.focus = .changes; // diff フォーカスで無い状態から
    var cmd = try update(&m, .select_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(m.focus == .diff);
    try std.testing.expectEqual(@as(usize, 4), m.diff_anchor.?); // h0 本文先頭
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // h0 本文末尾
}

test "select_hunk on empty diff (no hunks) is no-op" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try m.setStr(&m.diff_text, ""); // ハンク無し
    m.diff_cursor = 0;
    var cmd = try update(&m, .select_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "select_hunk picks the hunk containing cursor even on @@ header" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // @@h0 = 行3
    m.diff_cursor = 3; // @@h0 ヘッダ行
    var cmd = try update(&m, .select_hunk);
    defer cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.diff_anchor.?); // h0 本文先頭
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // h0 本文末尾
}

test "stage_hunk builds apply_patch for whole hunk body" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6: ' a', '-b', '+B'
    m.diff_cursor = 5;
    m.focus = .diff;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse); // unstaged → forward
    // h0 全体がパッチへ含まれる: -b と +B 両方
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+B\n") != null);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択消費
}

test "stage_hunk on empty diff is no-op" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try m.setStr(&m.diff_text, "");
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "stage_hunk respects busy guard" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    m.busy = true;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "stage_hunk respects rename guard (orig_path != null)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 .R の unstaged エントリ（orig_path != null）
    try m.files.append(m.allocator, .{
        .path = try m.allocator.dupe(u8, "new.txt"),
        .orig_path = try m.allocator.dupe(u8, "old.txt"),
        .section = .unstaged,
    });
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, m.error_text, "rename") != null);
}

test "select_hunk followed by auto-refresh preserves anchor (Bug 1 e2e analog)" {
    // select_hunk 後に diff_loaded が来ても validateAnchor が保持する。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6
    try m.setDiffOwner("f.txt", .unstaged); // 層 1 セットアップ
    m.diff_cursor = 5;
    var c1 = try update(&m, .select_hunk);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 4), m.diff_anchor);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
    // auto-refresh シミュレーション: 同じ diff で diff_loaded 再送
    const same = try a.dupe(u8, m.diff_text);
    defer a.free(same);
    var c2 = try update(&m, .{ .diff_loaded = same });
    c2.deinit(a);
    // 層 1（owner 一致）+ 層 2（anchor=h0本文, cursor=同h0）で保持
    try std.testing.expectEqual(@as(?usize, 4), m.diff_anchor);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
}

// =============================================================================
// TODO 2 phase 1: log/detail reducer arm テスト（spec §1.6 権威）
// =============================================================================

const log_mod = @import("git/log.zig");
const show_mod = @import("git/show.zig");

/// テスト用 Commit を構築（全フィールド dup・呼び出し側が c.deinit(a) で解放）。
fn mkCommit(a: std.mem.Allocator, hash: []const u8, subject: []const u8) !log_mod.Commit {
    return .{
        .hash = try a.dupe(u8, hash),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "tester"),
        .epoch_sec = 1000,
        .subject = try a.dupe(u8, subject),
        .refs = try a.dupe(u8, ""),
    };
}

/// テスト用 NameStatus を構築（path のみ dup・呼び出し側が ns.deinit(a) で解放）。
fn mkNameStatus(a: std.mem.Allocator, code: u8, path: []const u8) !show_mod.NameStatus {
    return .{
        .status = code,
        .path = try a.dupe(u8, path),
        .orig_path = null,
    };
}

/// log ビュー前提の Model をセットアップ（view_mode=.log・log_commits を N 件・log_has_more=true）。
fn seedLogModel(a: std.mem.Allocator, n: usize) !Model {
    var m = try Model.init(a, "/r");
    m.view_mode = .log;
    m.log_request_generation = 1;
    m.log_has_more = true;
    const commits = try a.alloc(log_mod.Commit, n);
    for (commits, 0..) |*c, i| {
        const hash_buf = try std.fmt.allocPrint(a, "h{x:0>4}", .{i});
        defer a.free(hash_buf);
        c.* = try mkCommit(a, hash_buf, "subject");
    }
    try m.replaceLogCommits(commits);
    for (commits) |*c| c.deinit(a);
    a.free(commits);
    return m;
}

// ----------------------------- toggle_view_mode -----------------------------

test "toggle_view_mode: changes→log sets view_mode/focus/generation, clears log state, returns load_log" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expectEqual(ViewMode.changes, m.view_mode);
    var cmd = try update(&m, .toggle_view_mode);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    try std.testing.expectEqual(@as(usize, 0), cmd.load_log.skip);
    try std.testing.expectEqual(@as(usize, 100), cmd.load_log.max_count);
    try std.testing.expectEqual(@as(u64, 1), cmd.load_log.generation);
    try std.testing.expectEqual(ViewMode.log, m.view_mode);
    try std.testing.expectEqual(Focus.changes, m.focus); // M5: .commit からでも .changes へ正規化
    try std.testing.expectEqual(@as(u64, 1), m.log_request_generation); // R3: 初期 0 から +1
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
    try std.testing.expect(!m.log_has_more);
}

test "toggle_view_mode: log→changes increments generation, clears page, returns refresh_status" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 5; // 既に増分済みの前提
    m.log_page_requested = 100; // in-flight ページ要求あり
    var cmd = try update(&m, .toggle_view_mode);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .refresh_status);
    try std.testing.expectEqual(ViewMode.changes, m.view_mode);
    try std.testing.expectEqual(Focus.changes, m.focus);
    try std.testing.expectEqual(@as(u64, 6), m.log_request_generation); // R3: +1 で遅延結果無効化
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
}

// ----------------------------- log_cursor_down -----------------------------

test "log_cursor_down: empty log clears detail state and returns none (R2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    // 詳細状態を汚しておく（空 guard で消去されること）
    try m.setDetailOwnerHash("stale");
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f.txt"));
    try m.setStr(&m.detail_diff, "stale");
    var cmd = try update(&m, .log_cursor_down);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
    try std.testing.expectEqual(@as(usize, 0), m.detail_files.items.len);
    try std.testing.expectEqualStrings("", m.detail_diff);
}

test "log_cursor_down: moves selection and loads commit_detail" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    var cmd = try update(&m, .log_cursor_down);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 1), m.log_selected);
    try std.testing.expectEqualStrings("h0001", cmd.load_commit_detail);
    try std.testing.expectEqualStrings("h0001", m.detail_owner_hash.?); // owner も記録
}

test "log_cursor_down: clamps at last commit" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 2);
    defer m.deinit();
    m.log_selected = 1; // 末尾
    var cmd = try update(&m, .log_cursor_down);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 1), m.log_selected); // 末尾で停止
}

test "log_cursor_down: triggers paging when has_more and near end (R17 len>=5)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 5); // len == 5 (R17 境界値)
    defer m.deinit();
    m.log_selected = 0; // まだ境界外（selected < len-5 == 0）
    // 1 回目の down: selected=0→1。1 >= len-5(0) を満たすので page が発火する。
    var c1 = try update(&m, .log_cursor_down);
    defer c1.deinit(a);
    try std.testing.expect(c1 == .load_log_page);
    try std.testing.expectEqual(@as(usize, 1), m.log_selected);
    try std.testing.expectEqual(@as(usize, 5), c1.load_log_page.skip);
    try std.testing.expectEqual(@as(?usize, 5), m.log_page_requested); // R11
}

test "log_cursor_down: R17 prevents underflow when len < 5" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3); // len < 5 → len-5 underflow するはずの条件
    defer m.deinit();
    m.log_selected = 2; // 末尾
    var cmd = try update(&m, .log_cursor_down);
    defer cmd.deinit(a);
    // len >= 5 を満たさないので page 発火せず load_commit_detail
    try std.testing.expect(cmd == .load_commit_detail);
}

test "log_cursor_down: R18 gates load_commit_detail during in-flight page" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 100; // page in-flight
    var cmd = try update(&m, .log_cursor_down);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none); // R18: detail load を発火しない
    try std.testing.expectEqual(@as(usize, 1), m.log_selected); // 選択移動は起きる
}

// ----------------------------- log_cursor_up -----------------------------

test "log_cursor_up: empty log returns none (R2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    var cmd = try update(&m, .log_cursor_up);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_cursor_up: moves selection down and loads detail" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_selected = 2;
    var cmd = try update(&m, .log_cursor_up);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 1), m.log_selected);
    try std.testing.expectEqualStrings("h0001", cmd.load_commit_detail);
    try std.testing.expectEqualStrings("h0001", m.detail_owner_hash.?);
}

test "log_cursor_up: clamps at 0" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_selected = 0;
    var cmd = try update(&m, .log_cursor_up);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 0), m.log_selected);
}

test "log_cursor_up: R18 gates detail load during in-flight page" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 50;
    var cmd = try update(&m, .log_cursor_up);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

// ----------------------------- log_open_detail -----------------------------

test "log_open_detail: empty returns none (R2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    var cmd = try update(&m, .log_open_detail);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_open_detail: loads detail for current selection" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_selected = 2;
    var cmd = try update(&m, .log_open_detail);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqualStrings("h0002", cmd.load_commit_detail);
}

test "log_open_detail: R18 gates during in-flight page" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 50;
    var cmd = try update(&m, .log_open_detail);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

// ----------------------------- scroll arms -----------------------------

test "log_scroll_down/up adjust log_scroll without affecting selection or paging" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 5);
    defer m.deinit();
    var c1 = try update(&m, .log_scroll_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.log_scroll);
    try std.testing.expectEqual(@as(usize, 0), m.log_selected); // 選択は不変
    var c2 = try update(&m, .log_scroll_up);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.log_scroll);
    // 0 未満へは行かない
    var c3 = try update(&m, .log_scroll_up);
    c3.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.log_scroll);
}

test "log_scroll_down clamps at log_commits length" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var c = try update(&m, .log_scroll_down);
        c.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), m.log_scroll);
}

test "detail_files_scroll_down/up adjust detail_scroll" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f1"));
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f2"));
    var c1 = try update(&m, .detail_files_scroll_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.detail_scroll);
    var c2 = try update(&m, .detail_files_scroll_up);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.detail_scroll);
}

test "detail_diff_scroll clamps at line count - 1 (empty is no-op)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    // 空 diff は no-op
    var c0 = try update(&m, .detail_diff_scroll_down);
    c0.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.detail_diff_scroll);
    // 4 トークン（"a\nb\nc\n" → cap 3）
    try m.setStr(&m.detail_diff, "a\nb\nc\n");
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var c = try update(&m, .detail_diff_scroll_down);
        c.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), m.detail_diff_scroll);
    var c2 = try update(&m, .detail_diff_scroll_up);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.detail_diff_scroll);
}

// ----------------------------- detail_cursor_* -----------------------------

test "detail_cursor_down/up: empty detail_files is no-op (R2)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    var c1 = try update(&m, .detail_cursor_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.detail_selected);
    var c2 = try update(&m, .detail_cursor_up);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.detail_selected);
}

test "detail_cursor_down/up: move detail_selected and return none" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f1"));
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f2"));
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f3"));
    var c1 = try update(&m, .detail_cursor_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.detail_selected);
    var c2 = try update(&m, .detail_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.detail_selected);
    var c3 = try update(&m, .detail_cursor_down);
    c3.deinit(a); // 末尾で停止
    try std.testing.expectEqual(@as(usize, 2), m.detail_selected);
    var c4 = try update(&m, .detail_cursor_up);
    c4.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.detail_selected);
}

// ----------------------------- detail_select_file -----------------------------

test "detail_select_file: empty detail_files is no-op (R2)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    var cmd = try update(&m, .detail_select_file);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "detail_select_file: sets detail_kind=.diff and returns load_detail_diff (R16 payload-first)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "src/f.txt"));
    var cmd = try update(&m, .detail_select_file);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_detail_diff);
    try std.testing.expectEqualStrings("h0000", cmd.load_detail_diff.hash);
    try std.testing.expectEqualStrings("src/f.txt", cmd.load_detail_diff.path);
    try std.testing.expectEqual(DetailKind.diff, m.detail_kind);
    try std.testing.expectEqualStrings("h0000", m.detail_diff_owner_hash.?);
    try std.testing.expectEqualStrings("src/f.txt", m.detail_diff_owner_path.?);
    try std.testing.expectEqual(@as(usize, 0), m.detail_diff_scroll);
}

test "detail_select_file: R18 gates during in-flight page" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f.txt"));
    m.log_page_requested = 100;
    var cmd = try update(&m, .detail_select_file);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(DetailKind.files, m.detail_kind); // 切替無し
}

// ----------------------------- detail_back_to_files -----------------------------

test "detail_back_to_files: resets state to .files, clears diff and owner" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    m.detail_kind = .diff;
    try m.setStr(&m.detail_diff, "diff body");
    m.detail_diff_scroll = 5;
    try m.setDetailDiffOwner("h0000", "f.txt");
    var cmd = try update(&m, .detail_back_to_files);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(DetailKind.files, m.detail_kind);
    try std.testing.expectEqualStrings("", m.detail_diff);
    try std.testing.expectEqual(@as(usize, 0), m.detail_diff_scroll);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_diff_owner_hash);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_diff_owner_path);
}

// ----------------------------- log_select_index / detail_select_index -----------------------------

test "log_select_index: sets log_selected and focus=.changes, loads detail" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 5);
    defer m.deinit();
    m.focus = .commit;
    var cmd = try update(&m, .{ .log_select_index = 3 });
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 3), m.log_selected);
    try std.testing.expectEqual(Focus.changes, m.focus); // R14
    try std.testing.expectEqualStrings("h0003", cmd.load_commit_detail);
}

test "log_select_index: empty returns none (R2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    var cmd = try update(&m, .{ .log_select_index = 0 });
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_select_index: out-of-range is ignored but focus set, returns detail for current selection" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_selected = 1;
    var cmd = try update(&m, .{ .log_select_index = 99 }); // 範囲外
    defer cmd.deinit(a);
    // log_selected は変化しない（範囲外は無視）。detail load は現選択で発火。
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 1), m.log_selected);
    try std.testing.expectEqualStrings("h0001", cmd.load_commit_detail);
}

test "log_select_index: R18 gates detail load but updates selection and focus" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 5);
    defer m.deinit();
    m.log_page_requested = 100;
    m.focus = .commit;
    var cmd = try update(&m, .{ .log_select_index = 2 });
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 2), m.log_selected);
    try std.testing.expectEqual(Focus.changes, m.focus); // R14: focus は更新
}

test "detail_select_index: .files mode sets detail_selected and focus=.diff" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f1"));
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f2"));
    m.detail_kind = .files;
    m.focus = .commit;
    var cmd = try update(&m, .{ .detail_select_index = 1 });
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 1), m.detail_selected);
    try std.testing.expectEqual(Focus.diff, m.focus); // R14
}

test "detail_select_index: out-of-range in .files mode is ignored" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f1"));
    m.detail_kind = .files;
    m.detail_selected = 0;
    var cmd = try update(&m, .{ .detail_select_index = 99 });
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 0), m.detail_selected); // 変化無し
}

test "detail_select_index: .diff mode ignores click (no file move)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.detail_files.append(a, try mkNameStatus(a, 'M', "f1"));
    m.detail_kind = .diff;
    m.detail_selected = 0;
    var cmd = try update(&m, .{ .detail_select_index = 0 });
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    // .diff 中はマウスクリックでファイル選択を変更しない
}

// ----------------------------- request_refresh (log mode) -----------------------------

test "request_refresh in log mode: increments generation, saves restore hash, clears state, returns load_log" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_selected = 2;
    m.log_request_generation = 5;
    try m.setDetailOwnerHash("stale");
    // mkNameStatus は所有 NameStatus を返すので、replaceDetailFiles 後に明示的に deinit する。
    var ns = try mkNameStatus(a, 'M', "f.txt");
    try m.replaceDetailFiles(&.{ns});
    ns.deinit(a);
    var cmd = try update(&m, .request_refresh);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    try std.testing.expectEqual(@as(u64, 6), cmd.load_log.generation); // R3 +1
    try std.testing.expectEqual(@as(usize, 0), cmd.load_log.skip);
    // R4: 選択 hash 退避
    try std.testing.expectEqualStrings("h0002", m.log_restore_hash.?);
    // 状態クリア
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
    try std.testing.expectEqual(@as(usize, 0), m.detail_files.items.len);
    try std.testing.expectEqual(DetailKind.files, m.detail_kind);
    try std.testing.expect(!m.log_has_more);
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
}

test "request_refresh in log mode: empty log clears restore hash instead of saving" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    m.log_request_generation = 1;
    try m.setLogRestoreHash("stale");
    var cmd = try update(&m, .request_refresh);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_restore_hash); // 空なので clear
}

test "request_refresh in changes mode: returns refresh_status (unchanged)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var cmd = try update(&m, .request_refresh);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .refresh_status);
}

// ----------------------------- log_loaded -----------------------------

test "log_loaded: rejects when not in log mode (R3 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.view_mode = .changes; // log から抜けた後の遅延結果
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, ""), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len); // 適用されない
}

test "log_loaded: rejects when generation mismatch (H1 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 7; // 要求時と異なる
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, ""), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_loaded: rejects when skip != 0 (H3 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_loaded = .{
        .request_skip = 50, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, ""), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_loaded: fresh apply with restore hash restores selection (R4)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    try m.setLogRestoreHash("h0002"); // R4: 退避済み
    const entries = try a.alloc(log_mod.Commit, 3);
    entries[0] = try mkCommit(a, "h0000", "s0");
    entries[1] = try mkCommit(a, "h0001", "s1");
    entries[2] = try mkCommit(a, "h0002", "s2");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 3), m.log_commits.items.len);
    try std.testing.expectEqual(@as(usize, 2), m.log_selected); // R4: hash 一致で復元
    try std.testing.expectEqualStrings("h0002", cmd.load_commit_detail);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_restore_hash); // 復元後にクリア
    // entries.len(3) < max_count(100) → has_more = false
    try std.testing.expect(!m.log_has_more);
}

test "log_loaded: has_more is false when entries < max_count (M3)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    const entries = try a.alloc(log_mod.Commit, 3);
    entries[0] = try mkCommit(a, "h0000", "s0");
    entries[1] = try mkCommit(a, "h0001", "s1");
    entries[2] = try mkCommit(a, "h0002", "s2");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(!m.log_has_more);
}

test "log_loaded: has_more is true when entries >= max_count (M3)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    // max_count == 3 で entries も 3 → has_more = true
    const entries = try a.alloc(log_mod.Commit, 3);
    entries[0] = try mkCommit(a, "h0000", "s0");
    entries[1] = try mkCommit(a, "h0001", "s1");
    entries[2] = try mkCommit(a, "h0002", "s2");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 3, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(m.log_has_more);
}

test "log_loaded: empty result clears detail state (R2)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    try m.setDetailOwnerHash("stale");
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
}

// ----------------------------- log_page_loaded -----------------------------

test "log_page_loaded: rejects when generation mismatch (H1 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 3; // 期待 skip
    m.log_request_generation = 99;
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 3, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0000"),
        .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, 3), m.log_page_requested); // 変化無し
}

test "log_page_loaded: rejects when skip != log_page_requested (R11 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 3; // 期待 skip
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 99, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0000"),
        .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_page_loaded: rejects when log_page_requested already null" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = null; // 既に消化済み
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 3, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0000"),
        .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "log_page_loaded: appends entries, clears page_requested (R22), reloads detail (R10)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3); // h0000..h0002
    defer m.deinit();
    m.log_page_requested = 3; // 期待 skip
    m.log_has_more = true;
    // H-07: tip 照合を通過させるため log_snapshot_tip を設定（先頭 commit hash と一致）。
    try m.setLogSnapshotTip("h0000");
    // 追加分 2 件
    const entries = try a.alloc(log_mod.Commit, 2);
    entries[0] = try mkCommit(a, "h0003", "s3");
    entries[1] = try mkCommit(a, "h0004", "s4");
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 3, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0000"),
        .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail); // R10
    try std.testing.expectEqual(@as(usize, 5), m.log_commits.items.len); // 3 + 2
    try std.testing.expectEqualStrings("h0004", m.log_commits.items[4].hash);
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested); // R22 クリア
    try std.testing.expect(!m.log_has_more); // entries.len(2) < max_count(100) → false
    try std.testing.expectEqualStrings("h0000", cmd.load_commit_detail); // R10: 現選択で再ロード
}

test "log_page_loaded: empty append is no-op for detail but still clears page_requested" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 3;
    // H-07: tip 照合を通過させるため log_snapshot_tip を設定。
    try m.setLogSnapshotTip("h0000");
    const entries = try a.alloc(log_mod.Commit, 0);
    defer a.free(entries);
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 3, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0000"),
        .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_commit_detail); // 既存 3 件あるので R10 で再ロード
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
}

// ----------------------------- log_page_failed -----------------------------

test "log_page_failed: clears page_requested and sets error_text" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 5;
    var msg = Msg{ .log_page_failed = .{
        .request_skip = 5, .request_generation = 1, .error_text = try a.dupe(u8, "boom"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
    try std.testing.expectEqualStrings("boom", m.error_text);
}

test "log_page_failed: rejects on generation mismatch" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 5;
    m.log_request_generation = 99;
    var msg = Msg{ .log_page_failed = .{
        .request_skip = 5, .request_generation = 1, .error_text = try a.dupe(u8, "boom"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, 5), m.log_page_requested); // 変化無し
    try std.testing.expectEqualStrings("", m.error_text);
}

test "log_page_failed: rejects on skip mismatch (R11)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 5;
    var msg = Msg{ .log_page_failed = .{
        .request_skip = 99, .request_generation = 1, .error_text = try a.dupe(u8, "boom"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, 5), m.log_page_requested); // 変化無し
}

test "log_page_failed: rejects when page_requested already null" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = null;
    var msg = Msg{ .log_page_failed = .{
        .request_skip = 5, .request_generation = 1, .error_text = try a.dupe(u8, "boom"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("", m.error_text);
}

// ----------------------------- log_page_failed_silent -----------------------------

test "log_page_failed_silent: clears page_requested without setting error_text" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 5;
    try m.setStr(&m.error_text, "preexisting");
    var msg = Msg{ .log_page_failed_silent = .{ .request_skip = 5, .request_generation = 1 } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
    try std.testing.expectEqualStrings("preexisting", m.error_text); // 変更無し
}

test "log_page_failed_silent: rejects on stale generation" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_page_requested = 5;
    m.log_request_generation = 99;
    var msg = Msg{ .log_page_failed_silent = .{ .request_skip = 5, .request_generation = 1 } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, 5), m.log_page_requested); // 変化無し
}

// ----------------------------- commit_detail_loaded -----------------------------

test "commit_detail_loaded: rejects when not in log mode (R3 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    m.view_mode = .changes;
    try m.setDetailOwnerHash("h0000");
    const entries = try a.alloc(show_mod.NameStatus, 1);
    entries[0] = try mkNameStatus(a, 'M', "f.txt");
    var msg = Msg{ .commit_detail_loaded = .{ .request_hash = try a.dupe(u8, "h0000"), .entries = entries } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 0), m.detail_files.items.len); // 適用されない
}

test "commit_detail_loaded: rejects when hash mismatch (H1 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.setDetailOwnerHash("h0000"); // owner
    const entries = try a.alloc(show_mod.NameStatus, 1);
    entries[0] = try mkNameStatus(a, 'M', "f.txt");
    var msg = Msg{ .commit_detail_loaded = .{ .request_hash = try a.dupe(u8, "DIFFERENT"), .entries = entries } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 0), m.detail_files.items.len); // 適用されない
}

test "commit_detail_loaded: rejects when detail_owner_hash is null" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    // owner 未設定
    const entries = try a.alloc(show_mod.NameStatus, 1);
    entries[0] = try mkNameStatus(a, 'M', "f.txt");
    var msg = Msg{ .commit_detail_loaded = .{ .request_hash = try a.dupe(u8, "h0000"), .entries = entries } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "commit_detail_loaded: fresh apply replaces detail_files and resets selection" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.setDetailOwnerHash("h0000");
    m.detail_selected = 5;
    m.detail_kind = .diff;
    const entries = try a.alloc(show_mod.NameStatus, 2);
    entries[0] = try mkNameStatus(a, 'M', "f1");
    entries[1] = try mkNameStatus(a, 'A', "f2");
    var msg = Msg{ .commit_detail_loaded = .{ .request_hash = try a.dupe(u8, "h0000"), .entries = entries } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 2), m.detail_files.items.len);
    try std.testing.expectEqualStrings("f1", m.detail_files.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), m.detail_selected); // リセット
    try std.testing.expectEqual(DetailKind.files, m.detail_kind); // リセット
}

// ----------------------------- detail_diff_loaded -----------------------------

test "detail_diff_loaded: rejects when not in log mode (R3 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    m.view_mode = .changes;
    try m.setDetailDiffOwner("h0000", "f.txt");
    var msg = Msg{ .detail_diff_loaded = .{
        .request_hash = try a.dupe(u8, "h0000"),
        .request_path = try a.dupe(u8, "f.txt"),
        .text = try a.dupe(u8, "diff body"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("", m.detail_diff); // 適用されない
}

test "detail_diff_loaded: rejects when hash mismatch (H1 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.setDetailDiffOwner("h0000", "f.txt");
    var msg = Msg{ .detail_diff_loaded = .{
        .request_hash = try a.dupe(u8, "WRONG"),
        .request_path = try a.dupe(u8, "f.txt"),
        .text = try a.dupe(u8, "diff body"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("", m.detail_diff);
}

test "detail_diff_loaded: rejects when path mismatch (H1 stale)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.setDetailDiffOwner("h0000", "f.txt");
    var msg = Msg{ .detail_diff_loaded = .{
        .request_hash = try a.dupe(u8, "h0000"),
        .request_path = try a.dupe(u8, "WRONG"),
        .text = try a.dupe(u8, "diff body"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("", m.detail_diff);
}

test "detail_diff_loaded: fresh apply sets detail_diff and resets scroll" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try m.setDetailDiffOwner("h0000", "f.txt");
    m.detail_diff_scroll = 99;
    var msg = Msg{ .detail_diff_loaded = .{
        .request_hash = try a.dupe(u8, "h0000"),
        .request_path = try a.dupe(u8, "f.txt"),
        .text = try a.dupe(u8, "diff body\n+new line\n"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("diff body\n+new line\n", m.detail_diff);
    try std.testing.expectEqual(@as(usize, 0), m.detail_diff_scroll);
}

test "detail_diff_loaded: rejects when owner is null" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    // owner 未設定
    var msg = Msg{ .detail_diff_loaded = .{
        .request_hash = try a.dupe(u8, "h0000"),
        .request_path = try a.dupe(u8, "f.txt"),
        .text = try a.dupe(u8, "diff body"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("", m.detail_diff);
}

// ----------------------------- optEql helper -----------------------------

test "optEql: both null returns true" {
    try std.testing.expect(optEql(null, null));
}

test "optEql: one null returns false" {
    try std.testing.expect(!optEql(null, "x"));
    try std.testing.expect(!optEql("x", null));
}

test "optEql: matching strings returns true" {
    try std.testing.expect(optEql("hello", "hello"));
}

test "optEql: differing strings returns false" {
    try std.testing.expect(!optEql("hello", "world"));
}

// ----------------------------- 複合シナリオ: toggle → load → cursor -----------------------------

test "end-to-end: toggle_view_mode then log_loaded then log_cursor_down coordinates detail owner" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 1) toggle → load_log
    var c1 = try update(&m, .toggle_view_mode);
    defer c1.deinit(a);
    try std.testing.expect(c1 == .load_log);
    const gen = c1.load_log.generation;
    // 2) log_loaded 結果適用（同 generation）
    const entries = try a.alloc(log_mod.Commit, 2);
    entries[0] = try mkCommit(a, "h0000", "s0");
    entries[1] = try mkCommit(a, "h0001", "s1");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = gen,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var c2 = try update(&m, msg);
    defer c2.deinit(a);
    try std.testing.expect(c2 == .load_commit_detail); // 初回詳細ロード
    try std.testing.expectEqualStrings("h0000", m.detail_owner_hash.?);
    // 3) log_cursor_down → 次のコミットへ
    var c3 = try update(&m, .log_cursor_down);
    defer c3.deinit(a);
    try std.testing.expect(c3 == .load_commit_detail);
    try std.testing.expectEqual(@as(usize, 1), m.log_selected);
    try std.testing.expectEqualStrings("h0001", m.detail_owner_hash.?);
}

test "end-to-end: paging flow (cursor near end → page → append → detail reload)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 5); // len == 5
    defer m.deinit();
    // H-07: 実運用では log_loaded が log_snapshot_tip を設定する。seedLogModel は直接構築するため
    //   ここで明示的に設定（先頭 commit hash と一致）。
    try m.setLogSnapshotTip("h0000");
    // log_has_more=true なので、selected を境界まで進めると page trigger
    m.log_selected = 0;
    // selected >= len-5 == 0 を満たす（selected=0 は既に境界）→ 次の down で page
    var c1 = try update(&m, .log_cursor_down);
    defer c1.deinit(a);
    try std.testing.expect(c1 == .load_log_page); // page 発火
    try std.testing.expectEqual(@as(?usize, 5), m.log_page_requested);
    // page 結果到着: log_page_loaded arm が append + detail reload
    // H-07: log_loaded で log_snapshot_tip="h0000" が設定済み。request_tip を一致させる。
    const entries = try a.alloc(log_mod.Commit, 2);
    entries[0] = try mkCommit(a, "h0005", "s5");
    entries[1] = try mkCommit(a, "h0006", "s6");
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 5, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0000"),
        .entries = entries,
    } };
    defer msg.deinit(a);
    var c2 = try update(&m, msg);
    defer c2.deinit(a);
    try std.testing.expect(c2 == .load_commit_detail); // R10: 選択 hash で再ロード
    try std.testing.expectEqual(@as(usize, 7), m.log_commits.items.len); // 5 + 2
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested); // クリア
    // page 完了後は通常の down が detail ロードを発火できる
    var c3 = try update(&m, .log_cursor_down);
    defer c3.deinit(a);
    try std.testing.expect(c3 == .load_commit_detail);
}

// ----------------------------- phase 2: graph computation + bad revision recovery -----------------------------

test "log_loaded: builds graph state on success" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 1;
    const entries = try a.alloc(log_mod.Commit, 1);
    entries[0] = try mkCommit(a, "h0001", "subj");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0,
        .request_max_count = 100,
        .request_generation = 1,
        .request_tip = try a.dupe(u8, "h0001"),
        .is_unborn = false,
        .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // H-05: graph state が .valid で構築されていること。
    try std.testing.expect(m.log_graph_state == .valid);
    try std.testing.expectEqual(@as(usize, 1), m.log_graph_state.valid.rows.items.len);
    // H-07: log_snapshot_tip が先頭 commit hash で設定されていること。
    try std.testing.expectEqualStrings("h0001", m.log_snapshot_tip.?);
}

test "git_error in log mode is .none (phase 3a §4.8: no full refresh)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 5;
    try m.setLogSnapshotTip("h0000");
    var msg = Msg{ .git_error = try a.dupe(u8, "tip expired") };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // §4.8/M3: log 中の git_error は無条件 .none（busy を触らない・安全側）。
    try std.testing.expect(cmd == .none);
    // generation も snapshot_tip も commits も不変（bad revision 回復は LogPageFailed arm 側）。
    try std.testing.expectEqual(@as(u64, 5), m.log_request_generation);
    try std.testing.expectEqualStrings("h0000", m.log_snapshot_tip.?);
    try std.testing.expectEqual(@as(usize, 3), m.log_commits.items.len);
    // error_text のみ設定される。
    try std.testing.expectEqualStrings("tip expired", m.error_text);
}

// ----------------------------- phase 3a Task 6: snapshot_tip / filter clone / log_load_error -----------------------------

test "handleLogLoaded: stores snapshot_tip from request_tip (B1)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 1;
    const entries = try a.alloc(log_mod.Commit, 1);
    entries[0] = try mkCommit(a, "h0001", "s1");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "deadbeef"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // B1: snapshot_tip は appcmd が解決した request_tip から保存される（items[0].hash ではない）。
    try std.testing.expectEqualStrings("deadbeef", m.log_snapshot_tip.?);
}

test "handleLogLoaded: graph suppressed skips computeAll (B2)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 1;
    m.graph_render_policy = .suppressed;
    const entries = try a.alloc(log_mod.Commit, 2);
    entries[0] = try mkCommit(a, "h0001", "s1");
    entries[1] = try mkCommit(a, "h0002", "s2");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // B2: policy==.suppressed なら graph 計算スキップ・log_graph_state は .invalid のまま。
    try std.testing.expect(m.log_graph_state == .invalid);
}

test "handleLogLoaded: clears log_load_error on success (M-N8)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 1;
    try m.setLogLoadError("前回のエラー");
    const entries = try a.alloc(log_mod.Commit, 1);
    entries[0] = try mkCommit(a, "h0001", "s1");
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // M-N8: 成功時は log_load_error がクリアされる。
    try std.testing.expectEqualStrings("", m.log_load_error);
}

test "handleLogPageLoaded: rejects stale snapshot_tip mismatch (B1)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3); // h0000..h0002
    defer m.deinit();
    m.log_page_requested = 3;
    m.log_request_generation = 1;
    // model の snapshot_tip と異なる request_tip → stale reject。
    try m.setLogSnapshotTip("aaa111");
    const entries = try a.alloc(log_mod.Commit, 1);
    entries[0] = try mkCommit(a, "h0003", "s3");
    var msg = Msg{ .log_page_loaded = .{
        .request_skip = 3, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "bbb222"), .entries = entries,
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // 不一致 → 破棄・commits は増えない。
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(usize, 3), m.log_commits.items.len);
}

test "handleLogPageFailed: clears snapshot_tip for bad revision recovery (MINOR2/M3)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 1;
    m.log_page_requested = 3;
    try m.setLogSnapshotTip("h0000");
    var msg = Msg{ .log_page_failed = .{
        .request_skip = 3, .request_generation = 1, .error_text = try a.dupe(u8, "tip expired"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    // 次回 LoadLog で再解決させるため snapshot_tip をクリア。
    try std.testing.expectEqual(@as(?[]u8, null), m.log_snapshot_tip);
}

test "buildLoadLogCmd: clones current filter_state into load_log (M5)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    m.log_request_generation = 42;
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "alice");
    m.setFilterState(spec);
    // toggle_view_mode で load_log 発火 → filter が伝播しているか。
    m.view_mode = .changes;
    var cmd = try update(&m, .toggle_view_mode);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    try std.testing.expectEqual(@as(u64, 43), cmd.load_log.generation);
    // M5: filter_state が clone されて cmd へ伝播。
    try std.testing.expect(!cmd.load_log.filter.isEmpty());
    try std.testing.expectEqualStrings("alice", cmd.load_log.filter.author.?);
}

test "handleRequestRefreshLog: clears snapshot_tip + keeps filter (M5/MINOR2)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 10;
    try m.setLogSnapshotTip("h0000");
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "bob");
    m.setFilterState(spec);
    var cmd = try update(&m, .request_refresh);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    // snapshot_tip はクリア（次回 LoadLog で再解決）。
    try std.testing.expectEqual(@as(?[]u8, null), m.log_snapshot_tip);
    // filter は保持・伝播。
    try std.testing.expect(!cmd.load_log.filter.isEmpty());
    try std.testing.expectEqualStrings("bob", cmd.load_log.filter.author.?);
}

test "handleLogCursorDown: load_log_page clones filter + uses snapshot_tip (B1/M5)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 5);
    defer m.deinit();
    m.log_request_generation = 1;
    m.log_has_more = true;
    // B1: snapshot_tip を設定（実運用では handleLogLoaded が設定）。
    try m.setLogSnapshotTip("snapcafe");
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "carol");
    m.setFilterState(spec);
    m.log_selected = 0; // len-5 == 0 境界 → 次の down で page trigger
    var cmd = try update(&m, .log_cursor_down);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log_page);
    // tip_hash は snapshot_tip から dupe。
    try std.testing.expectEqualStrings("snapcafe", cmd.load_log_page.tip_hash);
    // filter が clone されて伝播。
    try std.testing.expect(!cmd.load_log_page.filter.isEmpty());
    try std.testing.expectEqualStrings("carol", cmd.load_log_page.filter.author.?);
}

// ----------------------------- phase 3a Task 7: apply_filter / clear_filter / modal / log_load_failed -----------------------------

test "apply_filter: payload-first transactional success (M4/M-N7)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 5;
    try m.setLogSnapshotTip("oldtip");
    m.graph_render_policy = .auto;
    const payload = try a.dupe(u8, "alice");
    defer a.free(payload);
    const msg = Msg{ .apply_filter = payload };
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // load_log 発火・filter が payload から構築されて clone 伝播。
    try std.testing.expect(cmd == .load_log);
    try std.testing.expect(!cmd.load_log.filter.isEmpty());
    try std.testing.expectEqualStrings("alice", cmd.load_log.filter.author.?);
    // generation は +1 で stale 化。
    try std.testing.expectEqual(@as(u64, 6), cmd.load_log.generation);
    // Model 側も filter_state が更新されている。
    try std.testing.expectEqualStrings("alice", m.filter_state.author.?);
    // モーダル閉・snapshot_tip クリア・policy suppressed・commits 空。
    try std.testing.expect(!m.filter_modal_open);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_snapshot_tip);
    try std.testing.expectEqual(GraphRenderPolicy.suppressed, m.graph_render_policy);
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
    try std.testing.expect(m.log_graph_state == .invalid);
}

test "apply_filter: empty payload normalizes to null filter" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 2);
    defer m.deinit();
    const payload = try a.dupe(u8, "");
    defer a.free(payload);
    const msg = Msg{ .apply_filter = payload };
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    // 空文字 → null 正規化・isEmpty==true。
    try std.testing.expect(cmd.load_log.filter.isEmpty());
    try std.testing.expect(m.filter_state.isEmpty());
}

test "apply_filter: AuthorTooLong sets log_load_error, Model unchanged" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    m.log_request_generation = 5;
    const too_long = try a.alloc(u8, 257);
    defer a.free(too_long);
    @memset(too_long, 'x');
    const payload = try a.dupe(u8, too_long);
    defer a.free(payload);
    const msg = Msg{ .apply_filter = payload };
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    // AuthorTooLong → .none・Model 不変。
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(u64, 5), m.log_request_generation);
    try std.testing.expect(m.filter_state.isEmpty());
    try std.testing.expect(m.log_load_error.len > 0);
}

test "apply_filter: UTF-8 author preserved through payload → filter" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 0);
    defer m.deinit();
    const payload = try a.dupe(u8, "山田太郎");
    defer a.free(payload);
    const msg = Msg{ .apply_filter = payload };
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    try std.testing.expectEqualStrings("山田太郎", cmd.load_log.filter.author.?);
    try std.testing.expectEqualStrings("山田太郎", m.filter_state.author.?);
}

test "clear_filter: resets to auto + isEmpty filter + load_log (B2/M5)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    // フィルタ適用状態をセットアップ。
    var spec = FilterSpec.init();
    try spec.setAuthor(a, "bob");
    m.setFilterState(spec);
    m.graph_render_policy = .suppressed;
    m.log_request_generation = 10;
    try m.setLogSnapshotTip("tip123");
    var cmd = try update(&m, .clear_filter);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .load_log);
    // filter は空。
    try std.testing.expect(cmd.load_log.filter.isEmpty());
    try std.testing.expect(m.filter_state.isEmpty());
    // policy は .auto へ復活。
    try std.testing.expectEqual(GraphRenderPolicy.auto, m.graph_render_policy);
    // generation +1。
    try std.testing.expectEqual(@as(u64, 11), cmd.load_log.generation);
    // snapshot_tip クリア。
    try std.testing.expectEqual(@as(?[]u8, null), m.log_snapshot_tip);
}

test "open_filter_modal / close_filter_modal: toggle flag" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    try std.testing.expect(!m.filter_modal_open);
    var c1 = try update(&m, .open_filter_modal);
    defer c1.deinit(a);
    try std.testing.expect(m.filter_modal_open);
    try std.testing.expect(c1 == .none);
    var c2 = try update(&m, .close_filter_modal);
    defer c2.deinit(a);
    try std.testing.expect(!m.filter_modal_open);
    try std.testing.expect(c2 == .none);
}

test "log_load_failed: stale reject by generation (B4/M3)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 10;
    // generation 不一致 → 破棄。
    var msg = Msg{ .log_load_failed = .{
        .request_generation = 1,
        .request_tip = null,
        .error_text = try a.dupe(u8, "boom"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    // commits はそのまま・error 未設定。
    try std.testing.expectEqual(@as(usize, 3), m.log_commits.items.len);
    try std.testing.expectEqualStrings("", m.log_load_error);
}

test "log_load_failed: sets log_load_error + clears commits (B4/M3)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 3);
    defer m.deinit();
    m.log_request_generation = 7;
    var msg = Msg{ .log_load_failed = .{
        .request_generation = 7,
        .request_tip = try a.dupe(u8, "snap1234"),
        .error_text = try a.dupe(u8, "HEAD 解決失敗"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqualStrings("HEAD 解決失敗", m.log_load_error);
    // commits 空化・detail クリア。
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
    // request_tip があれば snapshot_tip へ保存。
    try std.testing.expectEqualStrings("snap1234", m.log_snapshot_tip.?);
}

test "log_load_failed: null request_tip clears snapshot_tip" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 1);
    defer m.deinit();
    m.log_request_generation = 3;
    try m.setLogSnapshotTip("oldtip");
    var msg = Msg{ .log_load_failed = .{
        .request_generation = 3,
        .request_tip = null,
        .error_text = try a.dupe(u8, "spawn 失敗"),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    // request_tip 無し → snapshot_tip クリア。
    try std.testing.expectEqual(@as(?[]u8, null), m.log_snapshot_tip);
}

test "log_load_failed_silent: generation check only (OOM 極限)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 2);
    defer m.deinit();
    m.log_request_generation = 5;
    // generation 一致 → .none（log_load_error は触らない）。
    var msg1 = Msg{ .log_load_failed_silent = .{ .request_generation = 5 } };
    defer msg1.deinit(a);
    var c1 = try update(&m, msg1);
    defer c1.deinit(a);
    try std.testing.expect(c1 == .none);
    try std.testing.expectEqualStrings("", m.log_load_error);
    // generation 不一致 → .none。
    var msg2 = Msg{ .log_load_failed_silent = .{ .request_generation = 99 } };
    defer msg2.deinit(a);
    var c2 = try update(&m, msg2);
    defer c2.deinit(a);
    try std.testing.expect(c2 == .none);
}

test "apply_filter then clear_filter: graph policy transitions suppressed → auto (B2)" {
    const a = std.testing.allocator;
    var m = try seedLogModel(a, 2);
    defer m.deinit();
    // apply_filter → suppressed。
    const payload1 = try a.dupe(u8, "foo");
    defer a.free(payload1);
    const msg1 = Msg{ .apply_filter = payload1 };
    var c1 = try update(&m, msg1);
    defer c1.deinit(a);
    try std.testing.expectEqual(GraphRenderPolicy.suppressed, m.graph_render_policy);
    // clear_filter → auto。
    var c2 = try update(&m, .clear_filter);
    defer c2.deinit(a);
    try std.testing.expectEqual(GraphRenderPolicy.auto, m.graph_render_policy);
}
