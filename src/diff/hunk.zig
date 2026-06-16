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

/// 選択ハンク 1 つ分のパッチ文字列を組む（file_header ＋ hunk.text、末尾改行を保証）。
/// ハンク単位では選択行の変換が無く @@ の行数は git 値をそのまま使える（再計算不要）。
/// forward / reverse でパッチ内容は同一（方向は appcmd の --reverse フラグで切り替える）。
/// 返り値は呼び出し側所有（update が AppCmd.apply_patch へ move する）。
pub fn buildPatch(a: std.mem.Allocator, parsed: ParsedDiff, hunk_index: usize) ![]u8 {
    std.debug.assert(hunk_index < parsed.hunks.len);
    const h = parsed.hunks[hunk_index];
    const ends_nl = h.text.len > 0 and h.text[h.text.len - 1] == '\n';
    if (ends_nl) {
        return std.fmt.allocPrint(a, "{s}{s}", .{ parsed.file_header, h.text });
    }
    return std.fmt.allocPrint(a, "{s}{s}\n", .{ parsed.file_header, h.text });
}

/// `@@ -A[,B] +C[,D] @@[trailing]` から old_start / new_start / trailing を借用 slice で取り出す。
const HunkHeader = struct { old_start: []const u8, new_start: []const u8, trailing: []const u8 };
fn parseHeader(header: []const u8) HunkHeader {
    var old_start: []const u8 = "0";
    var new_start: []const u8 = "0";
    var trailing: []const u8 = "";
    if (std.mem.indexOfScalar(u8, header, '-')) |dash| {
        const rest = header[dash + 1 ..];
        const end = std.mem.indexOfAny(u8, rest, ", ") orelse rest.len;
        old_start = rest[0..end];
    }
    if (std.mem.indexOfScalar(u8, header, '+')) |plus| {
        const rest = header[plus + 1 ..];
        const end = std.mem.indexOfAny(u8, rest, ", ") orelse rest.len;
        new_start = rest[0..end];
    }
    if (std.mem.indexOf(u8, header, "@@")) |first| {
        if (std.mem.indexOf(u8, header[first + 2 ..], "@@")) |rel| {
            const second = first + 2 + rel;
            trailing = header[second + 2 ..];
        }
    }
    return .{ .old_start = old_start, .new_start = new_start, .trailing = trailing };
}

/// 直前本文行の処理結果。後続の `\ No newline` マーカーの扱いを決めるために追跡する。
const Disp = enum { kept, dropped, contextified };

/// ハンク `hunk_index` のうち絶対行 index `[sel_start, sel_end]`（閉区間）に入る `+`/`-` 行だけを
/// 選択として、stage(forward) / unstage(reverse) 用の部分パッチを組む。変換規則は git add -p と同一:
///   選択 +/- は保持。stage: 未選択 + 削除・未選択 - 文脈化。unstage: 未選択 - 削除・未選択 + 文脈化。
///   文脈行は常に保持。@@ count は再計算、start は据え置き（単一ハンク）。
/// 戻り値 null = 保持される change 行ゼロ（文脈のみ選択）/ No-newline 境界の矛盾（safe no-op）。
/// 非 null は呼び出し側所有（update が AppCmd.apply_patch へ move、または解放）。
pub fn buildLinePatch(
    a: std.mem.Allocator,
    parsed: ParsedDiff,
    hunk_index: usize,
    sel_start: usize,
    sel_end: usize,
    reverse: bool,
) !?[]u8 {
    std.debug.assert(hunk_index < parsed.hunks.len);
    const h = parsed.hunks[hunk_index];

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var old_count: usize = 0;
    var new_count: usize = 0;
    var kept_changes: usize = 0;
    var prev: Disp = .kept;

    var it = std.mem.splitScalar(u8, h.text, '\n');
    const header = it.next() orelse return null; // "@@ ... @@" 行
    var tok: usize = 1;
    while (it.next()) |line| : (tok += 1) {
        if (line.len == 0) continue; // 末尾 \n 由来の空要素（本文行は prefix 1 文字以上）
        const abs = h.start_line + tok;
        const selected = abs >= sel_start and abs <= sel_end;
        switch (line[0]) {
            '\\' => switch (prev) { // \ No newline マーカー: 直前行の処理に従う
                .kept => {
                    try body.appendSlice(a, line);
                    try body.append(a, '\n');
                },
                .dropped => {}, // 直前行ごと落とす
                .contextified => return null, // 文脈化した行が no-newline 主張 → 矛盾
            },
            ' ' => {
                try body.appendSlice(a, line);
                try body.append(a, '\n');
                old_count += 1;
                new_count += 1;
                prev = .kept;
            },
            '+' => {
                if (selected) {
                    try body.appendSlice(a, line);
                    try body.append(a, '\n');
                    new_count += 1;
                    kept_changes += 1;
                    prev = .kept;
                } else if (reverse) { // unstage: index に存在 → 文脈化
                    try body.append(a, ' ');
                    try body.appendSlice(a, line[1..]);
                    try body.append(a, '\n');
                    old_count += 1;
                    new_count += 1;
                    prev = .contextified;
                } else { // stage: 削除
                    prev = .dropped;
                }
            },
            '-' => {
                if (selected) {
                    try body.appendSlice(a, line);
                    try body.append(a, '\n');
                    old_count += 1;
                    kept_changes += 1;
                    prev = .kept;
                } else if (reverse) { // unstage: index に不在 → 削除
                    prev = .dropped;
                } else { // stage: 文脈化
                    try body.append(a, ' ');
                    try body.appendSlice(a, line[1..]);
                    try body.append(a, '\n');
                    old_count += 1;
                    new_count += 1;
                    prev = .contextified;
                }
            },
            else => { // 想定外は保持（防御的）
                try body.appendSlice(a, line);
                try body.append(a, '\n');
                prev = .kept;
            },
        }
    }

    if (kept_changes == 0) return null;

    const hdr = parseHeader(header);
    return try std.fmt.allocPrint(a, "{s}@@ -{s},{d} +{s},{d} @@{s}\n{s}", .{
        parsed.file_header, hdr.old_start, old_count, hdr.new_start, new_count, hdr.trailing, body.items,
    });
}

/// 絶対 diff 行番号（splitScalar の要素 index）が属するハンク index を返す。
/// どのハンクにも属さない（file_header / 範囲外）なら null。純粋・allocator 不要。
pub fn hunkIndexForLine(parsed: ParsedDiff, abs_line: usize) ?usize {
    for (parsed.hunks, 0..) |h, i| {
        if (abs_line >= h.start_line and abs_line < h.start_line + h.line_count) return i;
    }
    return null;
}

test "buildPatch emits only the selected hunk plus file_header, newline-terminated" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n" ++
        "--- a/f.txt\n" ++
        "+++ b/f.txt\n" ++
        "@@ -1,2 +1,2 @@\n" ++
        " a\n-b\n+B\n" ++
        "@@ -10,2 +10,3 @@\n" ++
        " x\n+Y\n z\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    const patch = try buildPatch(a, p, 1); // 2 番目のハンクのみ
    defer a.free(patch);
    try std.testing.expect(std.mem.startsWith(u8, patch, "diff --git a/f.txt b/f.txt\n"));
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -10,2 +10,3 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -1,2 +1,2 @@") == null);
    try std.testing.expect(patch[patch.len - 1] == '\n');
}

test "hunkIndexForLine maps absolute diff line to hunk (header rows -> null outside)" {
    const a = std.testing.allocator;
    const diff =
        "--- a/f\n+++ b/f\n" ++ // 行 0,1（file_header）
        "@@ -1,1 +1,2 @@\n" ++ //   行 2  hunk0 開始
        " a\n+B\n" ++ //            行 3,4
        "@@ -9,1 +10,2 @@\n" ++ //  行 5  hunk1 開始
        " x\n+Y\n"; //             行 6,7
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), hunkIndexForLine(p, 0)); // file_header
    try std.testing.expectEqual(@as(?usize, 0), hunkIndexForLine(p, 2)); // hunk0 ヘッダ
    try std.testing.expectEqual(@as(?usize, 0), hunkIndexForLine(p, 4)); // hunk0 本文
    try std.testing.expectEqual(@as(?usize, 1), hunkIndexForLine(p, 5)); // hunk1 ヘッダ
    try std.testing.expectEqual(@as(?usize, 1), hunkIndexForLine(p, 7)); // hunk1 本文
    try std.testing.expectEqual(@as(?usize, null), hunkIndexForLine(p, 99)); // 範囲外
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

test "buildLinePatch stage(forward): keeps selected +, drops unselected +, context-ifies unselected -" {
    const a = std.testing.allocator;
    // file_header(2 行) + @@(行2) + 本文: ' a'(3) '-b'(4) '+B'(5) '+C'(6)
    const diff =
        "--- a/f\n+++ b/f\n" ++
        "@@ -1,2 +1,3 @@\n" ++
        " a\n-b\n+B\n+C\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // +B(行5) だけ選択して stage。-b は未選択→文脈化、+C は未選択→削除。
    const maybe = try buildLinePatch(a, p, 0, 5, 5, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    // 期待ハンク: old=' a','b'(文脈化)=2 / new=' a',' b'(文脈),'+B'=3 → @@ -1,2 +1,3 @@?
    // old_count = (' a')+(' b'=元 -b 文脈化) = 2 ; new_count = (' a')+(' b')+('+B') = 3
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -1,2 +1,3 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+B\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+C\n") == null); // 未選択 + は消える
    try std.testing.expect(std.mem.indexOf(u8, patch, "-b\n") == null); // 未選択 - は文脈化
    try std.testing.expect(std.mem.indexOf(u8, patch, " b\n") != null); // 文脈化された b
    try std.testing.expect(std.mem.startsWith(u8, patch, "--- a/f\n+++ b/f\n"));
    try std.testing.expect(patch[patch.len - 1] == '\n');
}

test "buildLinePatch unstage(reverse): drops unselected -, context-ifies unselected +" {
    const a = std.testing.allocator;
    const diff =
        "--- a/f\n+++ b/f\n" ++
        "@@ -1,3 +1,2 @@\n" ++
        " a\n-b\n-c\n+B\n"; // ' a'(3) '-b'(4) '-c'(5) '+B'(6)
    var p = try parse(a, diff);
    defer p.deinit(a);
    // -b(行4) だけ選択して unstage(reverse)。-c 未選択→削除、+B 未選択→文脈化。
    const maybe = try buildLinePatch(a, p, 0, 4, 4, true);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "-c\n") == null); // 未選択 - は削除
    try std.testing.expect(std.mem.indexOf(u8, patch, "+B\n") == null); // 未選択 + は文脈化
    try std.testing.expect(std.mem.indexOf(u8, patch, " B\n") != null);
    // old_count = (' a')+('-b')+(' B'=元 +B 文脈化) = 3 ; new_count = (' a')+(' B') = 2
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -1,3 +1,2 @@") != null);
}

test "buildLinePatch: full-hunk selection equals buildPatch output" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n" ++
        "@@ -1,2 +1,2 @@\n a\n-b\n+B\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // ハンク本文を丸ごと覆うレンジ（@@ 行〜末尾本文）。
    const h = p.hunks[0];
    const maybe = try buildLinePatch(a, p, 0, h.start_line, h.start_line + h.line_count - 1, false);
    try std.testing.expect(maybe != null);
    const line_patch = maybe.?;
    defer a.free(line_patch);
    const hunk_patch = try buildPatch(a, p, 0);
    defer a.free(hunk_patch);
    try std.testing.expectEqualStrings(hunk_patch, line_patch);
}

test "buildLinePatch: context-only selection yields null (no change lines)" {
    const a = std.testing.allocator;
    const diff = "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n"; // ' a'=行3
    var p = try parse(a, diff);
    defer p.deinit(a);
    const maybe = try buildLinePatch(a, p, 0, 3, 3, false); // 文脈行 ' a' のみ選択
    try std.testing.expectEqual(@as(?[]u8, null), maybe);
}

test "buildLinePatch: context-ifying a No-newline-owning line yields null (safe no-op)" {
    const a = std.testing.allocator;
    // '-a' が \ No newline を所有。+b を選択 stage → -a 文脈化が必要 → 矛盾 → null。
    const diff =
        "--- a/f\n+++ b/f\n" ++
        "@@ -1,1 +1,2 @@\n" ++
        "-a\n\\ No newline at end of file\n+a\n+b\n"; // '-a'(3) '\\'(4) '+a'(5) '+b'(6)
    var p = try parse(a, diff);
    defer p.deinit(a);
    const maybe = try buildLinePatch(a, p, 0, 6, 6, false); // +b のみ選択 → -a 文脈化
    try std.testing.expectEqual(@as(?[]u8, null), maybe);
}

test "buildLinePatch: Japanese body stages selected line only" {
    const a = std.testing.allocator;
    const diff =
        "--- a/日本語.txt\n+++ b/日本語.txt\n" ++
        "@@ -1,1 +1,3 @@\n 一行目\n+二行目\n+三行目\n"; // '+二行目'(4) '+三行目'(5)
    var p = try parse(a, diff);
    defer p.deinit(a);
    const maybe = try buildLinePatch(a, p, 0, 4, 4, false); // 二行目のみ
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+二行目\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+三行目\n") == null);
}

test {
    std.testing.refAllDecls(@This());
}
