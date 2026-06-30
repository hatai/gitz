//! パフォーマンス計測 benchmark 本体（Phase 0 perf-tuning）。
//! `zig build bench` で起動（Debug 既定: correctness + alloc 数）。
//! `zig build bench -Doptimize=ReleaseFast` で fps/latency（配布ビルド相当）。
//!
//! `bench/repos/<profile>-<n>/`（`bench/gen-history.sh` が生成）を入力に、主要フェンスの
//! ms / alloc 数 / peak heap を計測し Markdown 表へ出力（spec §4.3/§4.4・codex B1/M9/m11）。
//!
//! Zig 0.16 実 API（codex B1/m11）:
//! - `std.time.Timer` は存在しない → `std.Io.Clock.now(.awake, io)` で `Io.Timestamp` を取得。
//! - `std.mem.Allocator` vtable は alloc/resize/remap/free の4関数。
//! - ファイル読込は `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit)`（`init.io` 経由）。

const std = @import("std");
const builtin = @import("builtin");
const topology = @import("git/topology.zig");
const log = @import("git/log.zig");
const graph = @import("git/graph.zig");
const graph_project = @import("git/graph_project.zig");
const process = @import("git/process.zig");
const appcmd = @import("appcmd.zig");
const messages = @import("messages.zig");
const filter_mod = @import("filter.zig");
const viewmod = @import("view.zig");

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

/// 2 timestamp の差分（ns）→ ms。
fn elapsedMs(t0: i96, t1: i96) f64 {
    const d: u64 = @intCast(t1 - t0);
    return formatMs(d);
}

/// フェンス計測結果。
const FenceResult = struct {
    ms: f64,
    allocs: usize,
    peak_bytes: usize,
    extra: usize = 0, // frontier max / entries 数 等（フェンス毎に意味が異なる）
};

const Profile = struct {
    name: []const u8,
    dir: []const u8,
    count: usize,
};

/// `io` 経由で Markdown 表行を stdout へ出力。
fn printRow(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

fn writeRaw(io: std.Io, s: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

/// `bench/repos/<dir>/<name>` を読込（gpa 所有）。失敗時 null。
fn readRepoFile(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "bench/repos/{s}/{s}", .{ dir, name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024 * 1024)) catch return null;
}

// --- 各フェンス（純粋関数・計測対象関数へ CountingAlloc を注入） ---

fn benchTopology(gpa: std.mem.Allocator, io: std.Io, substrate_raw: []const u8) ?FenceResult {
    var ca = CountingAlloc.init(gpa);
    const a = ca.allocator();
    const t0 = nowNs(io);
    var sub = topology.parse(a, substrate_raw) catch return null;
    const t1 = nowNs(io);
    const entries_len = sub.entries.len;
    sub.deinit(a);
    return .{ .ms = elapsedMs(t0, t1), .allocs = ca.alloc_count, .peak_bytes = ca.peak_bytes, .extra = entries_len };
}

fn benchComputeAll(gpa: std.mem.Allocator, io: std.Io, commits: []const log.Commit) ?FenceResult {
    var tracker = graph.FrontierTracker{};
    var ca = CountingAlloc.init(gpa);
    const a = ca.allocator();
    const t0 = nowNs(io);
    var state = graph.computeAllTracked(a, commits, 1, null, &tracker) catch return null;
    const t1 = nowNs(io);
    state.deinit(a);
    return .{ .ms = elapsedMs(t0, t1), .allocs = ca.alloc_count, .peak_bytes = ca.peak_bytes, .extra = tracker.max_frontier };
}

fn benchComputeIncremental(gpa: std.mem.Allocator, io: std.Io, commits: []const log.Commit) ?FenceResult {
    if (commits.len < 10) return null;
    const split = commits.len * 4 / 5;
    const base = commits[0..split];
    const delta = commits[split..];
    // base は setup（非計測・gpa）。computeIncremental 成功時は base_state を消費(.invalid 化)し、
    // 失敗時は触らない。defer は成功時(.invalid で no-op)・失敗時(return null 前に解放)の両方で安全。
    var base_state = graph.computeAll(gpa, base, 1, null) catch return null;
    defer base_state.deinit(gpa);
    var ca = CountingAlloc.init(gpa);
    const a = ca.allocator();
    const t0 = nowNs(io);
    var state = graph.computeIncremental(a, &base_state, delta) catch return null;
    const t1 = nowNs(io);
    // computeIncremental は base_state の行（gpa 確保）を新 state へ move するため、
    // 結果 state の内存は gpa 起源と ca 起源が混在する。ca 経由で free すると
    // current_bytes が未追跡分を引いて underflow するので、基盤の gpa で直接解放する
    // （ca は forwarding のみ・peak/alloc_count は計測済み）。
    state.deinit(gpa);
    return .{ .ms = elapsedMs(t0, t1), .allocs = ca.alloc_count, .peak_bytes = ca.peak_bytes, .extra = delta.len };
}

fn benchProject(gpa: std.mem.Allocator, io: std.Io, substrate_raw: []const u8, commits: []const log.Commit) ?FenceResult {
    // substrate parse は setup（非計測・gpa）。project() 本体のみ計測。
    var sub = topology.parse(gpa, substrate_raw) catch return null;
    defer sub.deinit(gpa);
    var ca = CountingAlloc.init(gpa);
    const a = ca.allocator();
    const t0 = nowNs(io);
    const derived = graph_project.project(a, sub, commits) catch return null;
    const t1 = nowNs(io);
    graph_project.freeDerived(a, derived);
    return .{ .ms = elapsedMs(t0, t1), .allocs = ca.alloc_count, .peak_bytes = ca.peak_bytes, .extra = commits.len };
}

/// `appcmd.run(.load_log)` で runLogInt 全体（headState/rev-parse/git log/fetchSubstrate）を計測。
/// filter 活性時は substrate 取得経路も含む（codex M9 必須）。cwd = bench/repos/<dir>。
fn benchRunLogInt(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, with_filter: bool) ?FenceResult {
    var path_buf: [512]u8 = undefined;
    const repo_path = std.fmt.bufPrint(&path_buf, "bench/repos/{s}", .{dir}) catch return null;
    const cwd: process.Cwd = .{ .path = repo_path };
    // filter は cmd へ所有権移譲（cmd.deinit が解放）。filter 自体の deinit は二重 free 防止で行わない。
    var filter = filter_mod.FilterSpec.init();
    if (with_filter) {
        const author = gpa.dupe(u8, "Bench Generator") catch return null;
        filter.addCondition(gpa, .{ .author = author }) catch {
            gpa.free(author);
            filter.deinit(gpa);
            return null;
        };
    }
    var cmd = messages.AppCmd{ .load_log = .{
        .skip = 0,
        .max_count = 1000,
        .generation = 1,
        .filter = filter,
    } };
    defer cmd.deinit(gpa);
    var ca = CountingAlloc.init(gpa);
    const a = ca.allocator();
    const t0 = nowNs(io);
    var msg = appcmd.run(a, io, cwd, cmd) catch return null;
    const t1 = nowNs(io);
    var entry_count: usize = 0;
    if (msg == .log_loaded) entry_count = msg.log_loaded.entries.len;
    msg.deinit(a);
    return .{ .ms = elapsedMs(t0, t1), .allocs = ca.alloc_count, .peak_bytes = ca.peak_bytes, .extra = entry_count };
}

/// view.render 系純粋 helper（renderGraphCells/fitPane）をフレーム相当で計測。
/// 本番は ctx.allocator（フレーム arena）へ描画するため、ArenaAllocator + CountingAlloc で
/// 1 フレームの alloc 数・peak を再現（renderDiff は Model/Context 構築が重いため省略・Task 6 で再測）。
fn benchView(gpa: std.mem.Allocator, io: std.Io, commits: []const log.Commit) ?FenceResult {
    var state = graph.computeAll(gpa, commits, 1, null) catch return null;
    defer state.deinit(gpa);
    const rows = state.valid.rows.items;
    const win = if (rows.len > 50) rows[0..50] else rows; // 可視窓（最大50行・本番相当）
    const sample = "diff --git a/f b/f\n+added line content here\n-removed line\n this is a context line\nこれは日本語の行 East Asian Width 計測用\n" ** 4;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ca = CountingAlloc.init(arena.allocator());
    const a = ca.allocator();
    const t0 = nowNs(io);
    for (win) |row| {
        _ = viewmod.renderGraphCells(a, row, 40);
    }
    _ = viewmod.fitPane(a, sample, .{ .x = 0, .y = 0, .w = 80, .h = 40 });
    const t1 = nowNs(io);
    return .{ .ms = elapsedMs(t0, t1), .allocs = ca.alloc_count, .peak_bytes = ca.peak_bytes, .extra = win.len };
}

fn emit(io: std.Io, phase: []const u8, fence: []const u8, pf: Profile, res: ?FenceResult) void {
    if (res) |r| {
        printRow(io, "| {s} | {s} | {s} | {d} | {d:.3} | {d} | {d} | extra={d} |\n", .{
            phase, fence, pf.name, pf.count, r.ms, r.allocs, r.peak_bytes, r.extra,
        });
    } else {
        printRow(io, "| {s} | {s} | {s} | {d} | ERROR | - | - | - |\n", .{ phase, fence, pf.name, pf.count });
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const profiles = [_]Profile{
        .{ .name = "linear", .dir = "linear-1000", .count = 1000 },
        .{ .name = "wide-branches", .dir = "wide-branches-1000", .count = 1000 },
        .{ .name = "periodic-merge", .dir = "periodic-merge-1000", .count = 1000 },
        .{ .name = "path-filter-sparse", .dir = "path-filter-sparse-1000", .count = 1000 },
        .{ .name = "author-filter-sparse", .dir = "author-filter-sparse-1000", .count = 1000 },
        .{ .name = "long-subject-refs", .dir = "long-subject-refs-1000", .count = 1000 },
    };

    writeRaw(io, "| phase | fence | profile | commits | ms | allocs | peak_heap | note |\n");
    writeRaw(io, "|---|---|---|---|---|---|---|---|\n");

    for (profiles) |pf| {
        const substrate_opt = readRepoFile(io, gpa, pf.dir, "substrate.txt");
        const log_opt = readRepoFile(io, gpa, pf.dir, "log.txt");
        if (substrate_opt == null or log_opt == null) {
            if (substrate_opt) |s| gpa.free(s);
            if (log_opt) |l| gpa.free(l);
            printRow(io, "| 0 | (all) | {s} | {d} | SKIPPED | - | - | bench/repos/{s} 未生成 |\n", .{ pf.name, pf.count, pf.dir });
            continue;
        }
        const substrate_raw = substrate_opt.?;
        const log_raw = log_opt.?;
        defer gpa.free(substrate_raw);
        defer gpa.free(log_raw);

        // log commits を一度パース（computeAll/incremental/project/view フェンスの共通入力・gpa 所有）。
        const commits_owned = log.parse(gpa, log_raw) catch {
            printRow(io, "| 0 | (all) | {s} | {d} | SKIPPED | - | - | log parse 失敗 |\n", .{ pf.name, pf.count });
            continue;
        };
        defer {
            for (commits_owned) |*c| c.deinit(gpa);
            gpa.free(commits_owned);
        }
        const commits: []const log.Commit = commits_owned;

        emit(io, "0", "topology.parse", pf, benchTopology(gpa, io, substrate_raw));
        emit(io, "0", "graph.computeAll", pf, benchComputeAll(gpa, io, commits));
        emit(io, "0", "graph.computeIncremental", pf, benchComputeIncremental(gpa, io, commits));
        emit(io, "0", "graph_project.project", pf, benchProject(gpa, io, substrate_raw, commits));
        emit(io, "0", "runLogInt (no-filter)", pf, benchRunLogInt(gpa, io, pf.dir, false));
        emit(io, "0", "runLogInt (filter)", pf, benchRunLogInt(gpa, io, pf.dir, true));
        emit(io, "0", "view.render 系", pf, benchView(gpa, io, commits));
    }

    // 再現性メタデータ（m12）
    writeRaw(io, "\n");
    printRow(io, "- build mode: {s}\n", .{@tagName(builtin.mode)});
    printRow(io, "- zig version: {s}\n", .{builtin.zig_version_string});
    writeRaw(io, "- note: 1000 commits × 6 profiles（小規模 before 計測・10万コミットは省略）\n");
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
