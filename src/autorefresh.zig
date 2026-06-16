//! 自動 status リフレッシュのスロットル判定（純粋・zigzag/git 非依存）。
//! main の tick ハンドラから呼ぶ。worker 稼働中 / pending 退避ありのときは抑止し、
//! それ以外は前回 dispatch から interval_ms 以上経過していれば true。
const std = @import("std");

/// 自動 status リフレッシュを今 dispatch すべきか。
/// - worker_active: ワーカースレッドが稼働中（直列化中）なら true
/// - pending_active: 退避中の副作用がある（latest-wins）なら true
/// どちらかが true なら抑止（ポーリングを積まない・直列化を乱さない）。
/// それ以外は now_ms - last_ms >= interval_ms で判定。
pub fn shouldAutoRefresh(
    now_ms: i64,
    last_ms: i64,
    interval_ms: i64,
    worker_active: bool,
    pending_active: bool,
) bool {
    if (worker_active or pending_active) return false;
    return now_ms - last_ms >= interval_ms;
}

test "shouldAutoRefresh: skips while worker active" {
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, true, false));
}

test "shouldAutoRefresh: skips while pending active" {
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, false, true));
}

test "shouldAutoRefresh: fires when idle and interval elapsed" {
    try std.testing.expect(shouldAutoRefresh(1500, 0, 1500, false, false)); // 境界ちょうど
    try std.testing.expect(shouldAutoRefresh(5000, 1000, 1500, false, false));
}

test "shouldAutoRefresh: holds when interval not elapsed" {
    try std.testing.expect(!shouldAutoRefresh(1499, 0, 1500, false, false));
    try std.testing.expect(!shouldAutoRefresh(2000, 1000, 1500, false, false));
}

test {
    std.testing.refAllDecls(@This());
}
