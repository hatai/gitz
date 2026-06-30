//! 環境設定の純粋 parser（Phase 1 perf-tuning/codex B3）。
//! `appcmd.zig`（本番）と `bench.zig`（計測）の双方が import する共用境界。
//! `std.process.getEnvVar` は Zig 0.16 に存在しない（codex B2）ため、env 取得は
//! 呼出側が `init.environ_map.get(...)` で行い、値の解釈のみここで純粋に行う。

const std = @import("std");

/// 環境変数値（MiB 単位の文字列）を byte 数へ変換する純粋関数。
/// - `null`（env 未設定）・空・parseInt 失敗・0 以下 → `default_mib` へフォールバック。
/// - 戻り値は MiB 単位（呼出側が `* 1024 * 1024` で byte へ）。
pub fn parseLimitValue(value: ?[]const u8, default_mib: usize) usize {
    const v = value orelse return default_mib;
    const trimmed = std.mem.trim(u8, v, " \t");
    if (trimmed.len == 0) return default_mib;
    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch return default_mib;
    if (parsed == 0) return default_mib;
    return parsed;
}

test "parseLimitValue: 正常値（perf phase1/B2）" {
    try std.testing.expectEqual(@as(usize, 128), parseLimitValue("128", 64));
    try std.testing.expectEqual(@as(usize, 1), parseLimitValue("1", 64));
    try std.testing.expectEqual(@as(usize, 99999), parseLimitValue("99999", 64));
}

test "parseLimitValue: 前後空白は許容" {
    try std.testing.expectEqual(@as(usize, 256), parseLimitValue("  256  ", 64));
    try std.testing.expectEqual(@as(usize, 256), parseLimitValue("\t256\t", 64));
}

test "parseLimitValue: 不正値は既定へフォールバック" {
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue("abc", 64));
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue("12.5", 64));
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue("-8", 64));
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue("0", 64)); // 0 以下は既定
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue("", 64)); // 空
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue("   ", 64)); // 空白のみ
}

test "parseLimitValue: null（env 未設定）は既定" {
    try std.testing.expectEqual(@as(usize, 64), parseLimitValue(null, 64));
    try std.testing.expectEqual(@as(usize, 32), parseLimitValue(null, 32));
}

test {
    std.testing.refAllDecls(@This());
}
