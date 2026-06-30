//! パフォーマンス計測 benchmark 本体（Phase 0 perf-tuning）。
//! `zig build bench` で起動。Phase 0 Task 2 では計測インフラ（formatMs/CountingAlloc/timestamp）
//! と scaffolding を実装し、本格計測は Task 3（gen-history.sh）で入力データを生成した Task 4 で実施。
//!
//! Zig 0.16 実 API（codex B1/m11）:
//! - `std.time.Timer` は存在しない → `std.Io.Clock.now(.awake, io)` で `Io.Timestamp` を取得。
//! - `std.mem.Allocator` vtable は alloc/resize/remap/free の4関数。

const std = @import("std");

/// ns → ms 変換（純粋関数・テスト対象）。
pub fn formatMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

/// 計測用 counting allocator。child allocator をラップし、alloc/resize/remap/free で
/// 統計（alloc_count/dealloc_count/current_bytes/peak_bytes）を記録（codex m11）。
/// resize/remap は in-place 成功時と再配置成功時で current_bytes を調整。
pub const CountingAlloc = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    dealloc_count: usize = 0,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn init(child: std.mem.Allocator) CountingAlloc {
        return .{ .child = child };
    }

    /// `std.mem.Allocator` interface への変換（計測対象関数へ渡す）。
    pub fn allocator(self: *CountingAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn adjustGrowth(self: *CountingAlloc, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.current_bytes += new_len - old_len;
        } else {
            self.current_bytes -= old_len - new_len;
        }
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
    }

    fn allocFn(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAlloc = @ptrCast(@alignCast(ptr));
        const result = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        if (result != null) {
            self.alloc_count += 1;
            self.current_bytes += len;
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        }
        return result;
    }

    fn resizeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAlloc = @ptrCast(@alignCast(ptr));
        if (self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr)) {
            self.adjustGrowth(memory.len, new_len);
            return true;
        }
        return false;
    }

    fn remapFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAlloc = @ptrCast(@alignCast(ptr));
        const result = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (result != null) {
            self.adjustGrowth(memory.len, new_len);
        }
        return result;
    }

    fn freeFn(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAlloc = @ptrCast(@alignCast(ptr));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        self.dealloc_count += 1;
        self.current_bytes -= memory.len;
    }
};

/// `std.Io.Clock.now(.awake, io)` で monotonic timestamp（ns）を取得（codex B1）。
pub fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

/// `io` 経由で Markdown 表行を stdout へ出力。
fn printRow(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

/// Phase 0 Task 2: scaffolding。Task 3 で bench/repos を生成した後に Task 4 で本格計測。
/// 未生成時は SKIPPED 行を出力。
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, "| phase | fence | profile | commits | ms | allocs | peak_heap |\n") catch {};
    stdout.writeStreamingAll(io, "|---|---|---|---|---|---|---|\n") catch {};

    // Task 3 が bench/repos/<profile>-<n>/ を生成するまで SKIPPED。
    // Task 4 で topology.parse / computeAll / computeIncremental / graph_project.project /
    // runLogInt / view.render 系の各フェンスを bench/repos を入力に計測する。
    printRow(io, "| 0 | topology.parse | - | - | SKIPPED | - | - |\n", .{});
    printRow(io, "| 0 | graph.computeAll | - | - | SKIPPED | - | - |\n", .{});
    printRow(io, "| 0 | graph.computeIncremental | - | - | SKIPPED | - | - |\n", .{});
    printRow(io, "| 0 | graph_project.project | - | - | SKIPPED | - | - |\n", .{});
    printRow(io, "| 0 | runLogInt (no-filter) | - | - | SKIPPED | - | - |\n", .{});
    printRow(io, "| 0 | runLogInt (filter) | - | - | SKIPPED | - | - |\n", .{});
    printRow(io, "| 0 | view.render 系 | - | - | SKIPPED | - | - |\n", .{});

    // timestamp 計測の sanity check（1 つの Clock.now 呼出が成功することを確認）。
    const t0 = nowNs(io);
    _ = t0;
    stdout.writeStreamingAll(io, "(timestamp API: OK)\n") catch {};
}

test "formatMs: ns -> ms 変換（境界値）" {
    try std.testing.expectEqual(@as(f64, 0.0), formatMs(0));
    try std.testing.expectEqual(@as(f64, 1.0), formatMs(std.time.ns_per_ms));
    try std.testing.expectEqual(@as(f64, 1000.0), formatMs(std.time.ns_per_s));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), formatMs(std.time.ns_per_ms / 2), 1e-9);
}

test "CountingAlloc: alloc/free で count と bytes を記録" {
    var ca = CountingAlloc.init(std.testing.allocator);
    const a = ca.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 1), ca.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), ca.dealloc_count);
    try std.testing.expectEqual(@as(usize, 100), ca.current_bytes);
    try std.testing.expectEqual(@as(usize, 100), ca.peak_bytes);
    a.free(buf);
    try std.testing.expectEqual(@as(usize, 1), ca.dealloc_count);
    try std.testing.expectEqual(@as(usize, 0), ca.current_bytes);
    try std.testing.expectEqual(@as(usize, 100), ca.peak_bytes); // peak は最大値を保持
}

test "CountingAlloc: peak は最大値を保持（解放後も不変）" {
    var ca = CountingAlloc.init(std.testing.allocator);
    const a = ca.allocator();
    const b1 = try a.alloc(u8, 50);
    const b2 = try a.alloc(u8, 30);
    try std.testing.expectEqual(@as(usize, 80), ca.peak_bytes);
    try std.testing.expectEqual(@as(usize, 80), ca.current_bytes);
    a.free(b1);
    try std.testing.expectEqual(@as(usize, 80), ca.peak_bytes); // 解放されても peak は不変
    try std.testing.expectEqual(@as(usize, 30), ca.current_bytes);
    a.free(b2);
    try std.testing.expectEqual(@as(usize, 0), ca.current_bytes);
}

test {
    std.testing.refAllDecls(@This());
}
