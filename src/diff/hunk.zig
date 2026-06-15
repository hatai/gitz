//! diff_text（git diff 出力）を純粋に構造化するモジュール（部分ステージング phase 1）。
//! `parse` は diff_text を **複製せず slice で借用**し、Hunk 配列だけ allocator 所有する
//! （diff_text は model 所有・persistent で次の diff_loaded まで安定）。zigzag/git 非依存。
const std = @import("std");

pub const Hunk = struct {
    /// "@@ ... @@\n" ＋本文を diff_text から verbatim に切り出した slice（パッチ生成に使う）。
    text: []const u8,
    /// diff_text 内での @@ 行の 0 始まり行番号（ハイライト/カーソル/ヒットテスト用。
    /// 行番号は std.mem.splitScalar(_, '\n') の要素 index と一致する）。
    start_line: usize,
    /// @@ 行＋本文が占める行数。ハイライト範囲 = [start_line, start_line+line_count)。
    line_count: usize,
};

pub const ParsedDiff = struct {
    /// 先頭〜最初の @@ 行直前（diff --git / index / --- / +++）の verbatim slice。
    file_header: []const u8,
    /// 配列のみ allocator 所有。各 text / file_header は diff_text を借用する。
    /// `[]const` にして view のフォールバック空スライス（`&[_]Hunk{}`）も同型で扱えるようにする。
    hunks: []const Hunk,
    pub fn deinit(self: *ParsedDiff, a: std.mem.Allocator) void {
        a.free(self.hunks); // Allocator.free は const slice も受ける（toOwnedSlice 由来のみ deinit される）
    }
};

/// slice が占める表示行数（末尾改行の有無を吸収）。
fn lineCount(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (text.len > 0 and text[text.len - 1] != '\n') n += 1;
    return n;
}

/// diff_text を ParsedDiff に分解する。**行頭が "@@" の行のみ**をハンク境界とする
/// （本文行は ' '/'+'/'-'/'\' で始まるため、本文中に "@@" を含む行があっても誤検出しない）。
/// hunks.len == 0: 空 / @@ を含まない（ヘッダのみ）/ バイナリ差分。
pub fn parse(a: std.mem.Allocator, diff_text: []const u8) !ParsedDiff {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(a);

    var first_off: ?usize = null; // 最初の @@ 行のバイト開始位置
    var cur_off: ?usize = null; // 構築中ハンクの開始バイト位置
    var cur_ln: usize = 0; // 構築中ハンクの開始行番号
    var off: usize = 0; // 現在行の開始バイト位置
    var idx: usize = 0; // 現在行の 0 始まり行番号

    var it = std.mem.splitScalar(u8, diff_text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            if (first_off == null) first_off = off;
            if (cur_off) |s| try hunks.append(a, .{
                .text = diff_text[s..off],
                .start_line = cur_ln,
                .line_count = lineCount(diff_text[s..off]),
            });
            cur_off = off;
            cur_ln = idx;
        }
        off += line.len + 1; // 改行ぶん（最終行で overshoot するが以降未使用）
        idx += 1;
    }
    if (cur_off) |s| try hunks.append(a, .{
        .text = diff_text[s..diff_text.len],
        .start_line = cur_ln,
        .line_count = lineCount(diff_text[s..diff_text.len]),
    });

    return .{
        .file_header = diff_text[0..(first_off orelse diff_text.len)],
        .hunks = try hunks.toOwnedSlice(a),
    };
}

test "parse splits two hunks and captures file_header" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n" ++
        "index e69de29..0000000 100644\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+B\n" ++
        "@@ -10,2 +10,3 @@\n" ++
        " x\n" ++
        "+Y\n" ++
        " z\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), p.hunks.len);
    try std.testing.expect(std.mem.startsWith(u8, p.file_header, "diff --git"));
    try std.testing.expect(std.mem.endsWith(u8, p.file_header, "+++ b/f.txt\n"));
    try std.testing.expectEqual(@as(usize, 4), p.hunks[0].start_line); // @@ は 5 行目 = index 4
    try std.testing.expectEqual(@as(usize, 4), p.hunks[0].line_count); // @@ + 3 本文
    try std.testing.expect(std.mem.startsWith(u8, p.hunks[0].text, "@@ -1,2 +1,2 @@"));
    try std.testing.expectEqual(@as(usize, 8), p.hunks[1].start_line);
    try std.testing.expectEqual(@as(usize, 4), p.hunks[1].line_count);
    try std.testing.expect(std.mem.startsWith(u8, p.hunks[1].text, "@@ -10,2 +10,3 @@"));
}

test "parse returns zero hunks for header-only / empty / binary" {
    const a = std.testing.allocator;
    inline for (.{
        "",
        "diff --git a/x b/x\nindex 111..222 100644\n",
        "diff --git a/x b/x\nBinary files a/x and b/x differ\n",
    }) |d| {
        var p = try parse(a, d);
        defer p.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), p.hunks.len);
    }
}

test "parse anchors @@ at line start (body line containing @@ is not a header)" {
    const a = std.testing.allocator;
    const diff =
        "--- a/f\n+++ b/f\n" ++
        "@@ -1,1 +1,2 @@\n" ++
        " keep\n" ++
        "+foo@@bar\n"; // 本文に @@ を含むがヘッダではない
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), p.hunks.len);
    try std.testing.expectEqual(@as(usize, 3), p.hunks[0].line_count); // @@ + keep + foo@@bar
}

test "parse includes trailing No-newline marker in hunk body" {
    const a = std.testing.allocator;
    const diff =
        "--- a/f\n+++ b/f\n" ++
        "@@ -1 +1 @@\n" ++
        "-a\n" ++
        "+b\n" ++
        "\\ No newline at end of file\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), p.hunks.len);
    try std.testing.expect(std.mem.indexOf(u8, p.hunks[0].text, "\\ No newline at end of file") != null);
}

test "parse handles Japanese body and filename (raw UTF-8)" {
    const a = std.testing.allocator;
    const diff =
        "--- a/日本語.txt\n+++ b/日本語.txt\n" ++
        "@@ -1,1 +1,2 @@\n" ++
        " 一行目\n" ++
        "+二行目\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), p.hunks.len);
    try std.testing.expect(std.mem.indexOf(u8, p.file_header, "日本語.txt") != null);
}

test {
    std.testing.refAllDecls(@This());
}
