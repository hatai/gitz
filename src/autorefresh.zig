//! 自動 status リフレッシュのスロットル判定（純粋・zigzag/git 非依存）。
//! main の tick ハンドラから呼ぶ。worker 稼働中 / pending 退避ありのときは抑止し、
//! それ以外は前回 dispatch から interval_ms 以上経過していれば true。
const std = @import("std");
const ViewMode = @import("model.zig").ViewMode;

/// 自動 status リフレッシュを今 dispatch すべきか。
/// - view_mode: log モード中は自動リフレッシュを完全抑止（L5: log は読み取り専用・`r` で明示的再取得のみ）。
/// - worker_active: ワーカースレッドが稼働中（直列化中）なら true
/// - pending_active: 退避中の副作用がある（latest-wins）なら true
/// worker/pending が true なら抑止（ポーリングを積まない・直列化を乱さない）。
/// それ以外は now_ms - last_ms >= interval_ms で判定。
pub fn shouldAutoRefresh(
    now_ms: i64,
    last_ms: i64,
    interval_ms: i64,
    worker_active: bool,
    pending_active: bool,
    view_mode: ViewMode,
) bool {
    if (view_mode == .log) return false; // L5: log モード中は自動リフレッシュ抑止
    if (worker_active or pending_active) return false;
    return now_ms - last_ms >= interval_ms;
}

test "shouldAutoRefresh: skips while worker active" {
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, true, false, .changes));
}

test "shouldAutoRefresh: skips while pending active" {
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, false, true, .changes));
}

test "shouldAutoRefresh: fires when idle and interval elapsed" {
    try std.testing.expect(shouldAutoRefresh(1500, 0, 1500, false, false, .changes)); // 境界ちょうど
    try std.testing.expect(shouldAutoRefresh(5000, 1000, 1500, false, false, .changes));
}

test "shouldAutoRefresh: holds when interval not elapsed" {
    try std.testing.expect(!shouldAutoRefresh(1499, 0, 1500, false, false, .changes));
    try std.testing.expect(!shouldAutoRefresh(2000, 1000, 1500, false, false, .changes));
}

// --- TODO 2 phase 1: log モード抑止（L5） ---

test "shouldAutoRefresh: log mode always suppresses (even when idle and interval elapsed)" {
    // log モードでは worker/pending が idle で interval 経過していても抑止。
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, false, false, .log));
    try std.testing.expect(!shouldAutoRefresh(100_000, 0, 1500, false, false, .log));
}

test "shouldAutoRefresh: log mode suppresses even while worker/pending active" {
    // 念のため: log モードかつ worker/pending active でも false（log 判定が先なので自明だが回帰保護）。
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, true, false, .log));
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, false, true, .log));
}

test {
    std.testing.refAllDecls(@This());
}
