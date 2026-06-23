//! git 子プロセス実行ラッパ（zigzag 非依存）。
//! argv と cwd を受け取り、stdout/stderr/exit code を返す薄いラッパ。
//! Zig 0.16 の `std.process.run`（Io 版）を使う。

const std = @import("std");

pub const Cwd = std.process.Child.Cwd; // .inherit / .path / .dir

/// 明示エラーセット規約への準拠。薄いラッパゆえ std の `std.process.run` の
/// エラーセットをそのまま再エクスポートして使う（手書きで再現すると std 内部
/// 実装に密結合するため、再エクスポートが最も簡潔で結合度も低い）。
pub const RunError = std.process.RunError;

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8, // 異常終了(シグナル等)は 255 に正規化

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// std.process.run の既定ストリーム上限（16MiB）。
/// 注意: `run` では stdout/stderr 両方へ適用するが、`runWithLimit` では
/// stderr のみへ適用する（stdout は注入引数 `stdout_limit` で置換）。
pub const default_stream_limit: std.Io.Limit = .limited(16 * 1024 * 1024);

/// argv を cwd で実行し、stdout/stderr と正規化した exit code を返す。
/// `stdout_limit` は呼び出し側が指定（テストでの StreamTooLong 再現用 seam）。
/// stderr は常に `default_stream_limit`（git のエラー文は小さく超過しないため）。
/// 返り値の stdout/stderr の所有権は呼び出し側（`RunResult.deinit` で解放）。
pub fn runWithLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: Cwd,
    stdout_limit: std.Io.Limit,
) RunError!RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = stdout_limit,
        .stderr_limit = default_stream_limit,
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c, // 既に u8
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = code };
}

/// 既定 limit（16MiB）で argv を実行する薄いラッパ。本番経路はこちらを使う。
/// エラーセットは `RunError`（= `std.process.RunError` の再エクスポート）で明示する。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: Cwd,
) RunError!RunResult {
    return runWithLimit(allocator, io, argv, cwd, default_stream_limit);
}

test "run echo returns stdout and exit 0" {
    const a = std.testing.allocator;
    var res = try run(a, std.testing.io, &.{ "echo", "hello" }, .inherit);
    defer res.deinit(a);
    try std.testing.expectEqualStrings("hello\n", res.stdout);
    try std.testing.expectEqual(@as(u8, 0), res.exit_code);
}

test "run false returns nonzero exit" {
    const a = std.testing.allocator;
    var res = try run(a, std.testing.io, &.{"false"}, .inherit);
    defer res.deinit(a);
    try std.testing.expect(res.exit_code != 0);
}

test "runWithLimit returns StreamTooLong when stdout exceeds the limit" {
    const a = std.testing.allocator;
    // "hello\n" は 6 byte。stdout_limit=2 で超過 → error.StreamTooLong。
    // 前提（spec §6）: limit 超過は truncate ではなく error。本テストがその回帰ガード。
    try std.testing.expectError(
        error.StreamTooLong,
        runWithLimit(a, std.testing.io, &.{ "echo", "hello" }, .inherit, .limited(2)),
    );
}
