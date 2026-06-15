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

/// argv を cwd で実行し、stdout/stderr と正規化した exit code を返す。
/// 返り値の stdout/stderr の所有権は呼び出し側（`RunResult.deinit` で解放）。
/// エラーセットは `RunError`（= `std.process.RunError` の再エクスポート）で明示する。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: Cwd,
) RunError!RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c, // 既に u8
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = code };
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
