//! Aggregates every module's in-file `test {}` blocks so `zig build test`
//! runs the whole suite in one command (acceptance criterion #9).
//!
//! Each subsequent task enables its module's import line (in its final
//! Commit step) so the aggregated suite stays green as the project grows.
//! Task 1 only has main.zig, so the rest stay commented out for now.

test {
    _ = @import("git/process.zig"); // Task 2
    _ = @import("git/status.zig"); // Task 3
    _ = @import("git/commands.zig"); // Task 4
    _ = @import("model.zig"); // Task 5
    _ = @import("messages.zig"); // Task 6
    _ = @import("update.zig"); // Task 7
    _ = @import("appcmd.zig"); // Task 8
    _ = @import("input.zig"); // Task 9
    _ = @import("view.zig"); // Task 10
    _ = @import("diff/hunk.zig"); // 部分ステージング
    _ = @import("autorefresh.zig"); // 自動リフレッシュ
    _ = @import("git/log.zig"); // TODO 2 phase 1: log パーサ
}
