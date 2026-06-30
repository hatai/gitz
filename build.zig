const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag = b.dependency("zigzag", .{ .target = target, .optimize = optimize });
    const zigzag_mod = zigzag.module("zigzag");

    // Executable
    const exe = b.addExecutable(.{
        .name = "git-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigzag", .module = zigzag_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run git-tui");
    run_step.dependOn(&run_cmd.step);

    // Aggregated unit tests (all in-file `test {}` blocks via src/root_test.zig)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigzag", .module = zigzag_mod },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Performance benchmark (Phase 0 perf-tuning). Debug 既定・-Doptimize=ReleaseFast で配布相当。
    // codex M4 反映: view.render 系計測（renderDiff/renderGraphCells/fitPane）のため zigzag import 必須。
    const bench_exe = b.addExecutable(.{
        .name = "git-tui-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigzag", .module = zigzag_mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);
    const bench_step = b.step("bench", "Run performance benchmarks (Phase 0 perf-tuning)");
    bench_step.dependOn(&bench_cmd.step);
}
