# 部分ステージング（ハンク単位）実装計画 — TODO 1 / phase 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** diff ペインでハンク（`@@ ... @@` 単位）を選択し、その範囲だけを stage / unstage できるようにする。

**Architecture:** 既存の Elm 風層（model→update→appcmd→git）に、純粋モジュール `src/diff/hunk.zig`（diff_text を借用 slice で構造化する `parse` と、選択ハンク 1 つのパッチを組む `buildPatch`）を 1 枚足す。update が patch を生成して `AppCmd.apply_patch` を返し、appcmd が `.git/` 配下の一時ファイルへ書いて `git apply --cached [--reverse]` を実行、既存の status+diff 再読込に乗せる。

**Tech Stack:** Zig 0.16 + zigzag v0.1.5。git CLI 委譲（`std.process.run`、stdin 不可）。テストは実装と同じ `.zig` 内の `test {}`、`std.testing.allocator`。

**設計 spec:** `docs/superpowers/specs/2026-06-15-partial-staging-hunk-design.md`
**実 API ノート:** `docs/superpowers/plans/zigzag-api-notes.md`（食い違ったらノート優先）

## 計画上の確定事項（spec からの精緻化）

- **タスク順序の制約（重要）**: Zig の網羅 switch は `else` を持たない方針（CLAUDE.md）。`Msg` に variant を足すと
  `update.zig`（`switch (msg)`）と `messages.zig`（`Msg.deinit`）が、`AppCmd` に variant を足すと
  `messages.zig`（`AppCmd.deinit`）・`appcmd.zig`（`run`）・`main.zig`（`applyAppCmd` と `seedInitialStatus`）が
  **同時に**割れる。各コミットでビルド green を保つため、これらの型変更と全 switch 更新を **Task 5 に束ねる**。
- spec §10 の `hunkFromDiffLine`（input.zig・要 allocator）は **input.zig を allocation-free に保つ**ため
  factoring を変更する：マウスは diff ペイン相対行に `diff_scroll` を足した**絶対 diff 行**を
  `Msg.select_hunk_at_line: usize` で送り、reducer（allocator あり）が `hunk.parse` →
  `hunk.hunkIndexForLine` で解決して `selected_hunk` を設定する。挙動（受け入れ基準）は spec と同一。
- 一時パッチは `.git/git-tui-stage.patch`（worktree に出さず status を汚さない）。副作用は worker で
  直列化されるため固定名で衝突しない。書込先 Dir は `cwd`（production は `.{ .path = repo_root }`）から解決する
  （`Child.Cwd` は `inherit`/`dir`/`path` の 3 variant で確認済み）。

## ファイル構成

| ファイル | 責務 | 種別 |
|---|---|---|
| `src/diff/hunk.zig` | diff_text の構造化（`parse`）・パッチ生成（`buildPatch`）・行→ハンク解決（`hunkIndexForLine`）。純粋 | 新規 |
| `src/root_test.zig` | `diff/hunk.zig` の test 集約に追加 | 変更 |
| `src/model.zig` | `selected_hunk: usize` | 変更 |
| `src/git/commands.zig` | `applyPatchArgv`（純粋） | 変更 |
| `src/messages.zig` | `Msg` 4 種・`AppCmd.apply_patch`＋ deinit | 変更 |
| `src/update.zig` | ナビ 0 リセット・diff_loaded clamp・hunk_next/prev・select_hunk_at_line・stage_hunk | 変更 |
| `src/appcmd.zig` | `apply_patch` 解釈（`.git/` へ tmp 書込→git apply→refresh） | 変更 |
| `src/main.zig` | `applyAppCmd` / `seedInitialStatus` の網羅 switch に arm | 変更 |
| `src/input.zig` | `keyToMsg` の diff 分岐・マウスの diff_line 算出 | 変更 |
| `src/view.zig` | `renderDiff` を `*Model` 化・ハンクハイライト・自動スクロール | 変更 |
| `README.md` / `TODO.md` | キー操作追記・TODO 1 チェック | 変更 |

## タスク依存関係

```
Task 1 (hunk.parse) ─→ Task 2 (buildPatch/hunkIndexForLine) ─┐
Task 3 (model.selected_hunk) ────────────────────────────────┤
Task 4 (commands.applyPatchArgv) ────────────────────────────┴─→ Task 5 (end-to-end 配線)
                                                                      └─→ Task 6 (input) ─→ Task 7 (view) ─→ Task 8 (docs/最終)
```

---

### Task 1: `src/diff/hunk.zig` — `parse`（diff_text の構造化）

**Files:**
- Create: `src/diff/hunk.zig`
- Modify: `src/root_test.zig`

- [ ] **Step 1: スケルトンと parse・最初のテストを書く**

`src/diff/hunk.zig` を新規作成:

```zig
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

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 2: root_test.zig に登録**

`src/root_test.zig` の `test {}` ブロック内、`_ = @import("view.zig");` の直後に追加:

```zig
    _ = @import("diff/hunk.zig"); // 部分ステージング
```

- [ ] **Step 3: テストを実行して緑を確認**

Run: `zig build test --summary all`
Expected: PASS（`parse splits two hunks ...` を含む全テスト green）。

- [ ] **Step 4: エッジケースのテストを追加**

`src/diff/hunk.zig` の `test { refAllDecls }` の直前に追加:

```zig
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
```

- [ ] **Step 5: テストを実行して緑を確認**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 6: コミット**

```bash
git add src/diff/hunk.zig src/root_test.zig
git commit -m "feat(diff): ハンク構造化パーサ hunk.parse を追加（行頭@@アンカー・借用slice）"
```

---

### Task 2: `src/diff/hunk.zig` — `buildPatch` と `hunkIndexForLine`

**Files:**
- Modify: `src/diff/hunk.zig`

- [ ] **Step 1: 失敗テストを書く**

`src/diff/hunk.zig` の最初の `test "parse splits ..."` の直後に追加:

```zig
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
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `zig build test --summary all`
Expected: FAIL（`buildPatch` / `hunkIndexForLine` 未定義でコンパイルエラー）。

- [ ] **Step 3: buildPatch と hunkIndexForLine を実装**

`src/diff/hunk.zig` の `parse` 関数の直後（最初の `test` の前）に追加:

```zig
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

/// 絶対 diff 行番号（splitScalar の要素 index）が属するハンク index を返す。
/// どのハンクにも属さない（file_header / 範囲外）なら null。純粋・allocator 不要。
pub fn hunkIndexForLine(parsed: ParsedDiff, abs_line: usize) ?usize {
    for (parsed.hunks, 0..) |h, i| {
        if (abs_line >= h.start_line and abs_line < h.start_line + h.line_count) return i;
    }
    return null;
}
```

- [ ] **Step 4: テストを実行して緑を確認**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add src/diff/hunk.zig
git commit -m "feat(diff): buildPatch（選択ハンクのみ）と hunkIndexForLine を追加"
```

---

### Task 3: `src/model.zig` — `selected_hunk`

**Files:**
- Modify: `src/model.zig`

- [ ] **Step 1: フィールドと init を追加**

`src/model.zig` の `Model` struct 内、`diff_scroll: usize,` の直後に追加:

```zig
    selected_hunk: usize, // diff ペインの現在ハンク（0始まり）。ファイル切替で 0、diff 再読込で clamp。
```

`Model.init` の返り値リテラル内、`.diff_scroll = 0,` の直後に追加:

```zig
            .selected_hunk = 0,
```

- [ ] **Step 2: ビルドとテストで回帰なしを確認**

Run: `zig build test --summary all`
Expected: PASS（既存テストは selected_hunk 既定 0 で不変）。

- [ ] **Step 3: コミット**

```bash
git add src/model.zig
git commit -m "feat(model): selected_hunk フィールドを追加"
```

---

### Task 4: `src/git/commands.zig` — `applyPatchArgv`

**Files:**
- Modify: `src/git/commands.zig`

- [ ] **Step 1: 失敗テストを書く**

`src/git/commands.zig` の `test "diffArgv injects ..."` の直後に追加:

```zig
test "applyPatchArgv: forward has no --reverse, file_path last" {
    const a = std.testing.allocator;
    const argv = try applyPatchArgv(a, false, ".git/git-tui-stage.patch");
    defer a.free(argv);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("apply", argv[1]);
    try std.testing.expectEqualStrings("--cached", argv[2]);
    try std.testing.expectEqualStrings(".git/git-tui-stage.patch", argv[3]);
    try std.testing.expectEqual(@as(usize, 4), argv.len);
}

test "applyPatchArgv: reverse inserts --reverse before file_path" {
    const a = std.testing.allocator;
    const argv = try applyPatchArgv(a, true, ".git/git-tui-stage.patch");
    defer a.free(argv);
    try std.testing.expectEqualStrings("--reverse", argv[3]);
    try std.testing.expectEqualStrings(".git/git-tui-stage.patch", argv[4]);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `zig build test --summary all`
Expected: FAIL（`applyPatchArgv` 未定義）。

- [ ] **Step 3: applyPatchArgv を実装**

`src/git/commands.zig` の `diffArgv` 関数の直後（`// --- 高レベル関数 ...` コメントの前）に追加:

```zig
/// "git apply --cached [--reverse] <file_path>"。呼び出し側が free。
/// file_path は cwd 相対（appcmd が cwd 配下の .git/ に書く）。-p1 は git diff 既定と一致するため不要。
pub fn applyPatchArgv(a: std.mem.Allocator, reverse: bool, file_path: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "apply", "--cached" });
    if (reverse) try list.append(a, "--reverse");
    try list.append(a, file_path);
    return list.toOwnedSlice(a);
}
```

- [ ] **Step 4: テストを実行して緑を確認**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add src/git/commands.zig
git commit -m "feat(git): applyPatchArgv（git apply --cached [--reverse]）を追加"
```

---

### Task 5: 新 variant を end-to-end 配線（messages / update / appcmd / main）

> **なぜ 1 タスクに束ねるか:** `Msg`/`AppCmd` に variant を足すと、`else` 無しの網羅 switch が
> `update.zig`・`messages.zig`・`appcmd.zig`・`main.zig` で同時に割れる。途中コミットでビルドを壊さない
> ため、型追加と全 switch 更新・実装を 1 タスクにまとめる。内部は TDD ステップで進める。

**Files:**
- Modify: `src/messages.zig`, `src/update.zig`, `src/appcmd.zig`, `src/main.zig`

- [ ] **Step 1: update.zig の失敗テストを書く**

`src/update.zig` 冒頭の import に hunk を追加（`const status = @import("git/status.zig");` の直後）:

```zig
const hunk = @import("diff/hunk.zig");
```

最後のテストの直後に追加:

```zig
// 2 ハンクを持つ unstaged diff を model に直接セットするヘルパ。
fn seedTwoHunkDiff(m: *Model) !void {
    const diff =
        "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n" ++
        "@@ -1,2 +1,2 @@\n a\n-b\n+B\n" ++ // @@ は行3
        "@@ -10,2 +10,3 @@\n x\n+Y\n z\n"; // @@ は行7
    try m.setStr(&m.diff_text, diff);
}

test "hunk_next/hunk_prev move within hunk count and clamp" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
    var c1 = try update(&m, .hunk_next);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected_hunk);
    var c2 = try update(&m, .hunk_next); // 末尾で止まる（2 ハンク）
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected_hunk);
    var c3 = try update(&m, .hunk_prev);
    c3.deinit(a);
    var c4 = try update(&m, .hunk_prev); // 0 で止まる
    c4.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
}

test "stage_hunk on unstaged returns apply_patch with reverse=false and selected hunk" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.selected_hunk = 1;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -10,2 +10,3 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -1,2 +1,2 @@") == null);
}

test "stage_hunk on staged sets reverse=true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .staged);
    try seedTwoHunkDiff(&m);
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(cmd.apply_patch.reverse);
}

test "stage_hunk on untracked is no-op with guidance message" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "new.txt", .untracked);
    try seedTwoHunkDiff(&m);
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
}

test "stage_hunk on rename (orig_path != null) is no-op with guidance message" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{ .path = try a.dupe(u8, "new.txt"), .orig_path = try a.dupe(u8, "old.txt"), .section = .staged });
    try seedTwoHunkDiff(&m);
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
}

test "stage_hunk while busy or with zero hunks returns none" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.busy = true;
    var c1 = try update(&m, .stage_hunk);
    c1.deinit(a);
    try std.testing.expect(c1 == .none);
    m.busy = false;
    try m.setStr(&m.diff_text, ""); // 0 ハンク
    var c2 = try update(&m, .stage_hunk);
    c2.deinit(a);
    try std.testing.expect(c2 == .none);
}

test "select_hunk_at_line resolves line to hunk; count==0 stays 0 (no underflow)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    // hunk1 の @@ 行は絶対行 7（header3 + hunk0[@@,a,-b,+B]=行3..6 → hunk1 @@ は行7）。
    var c1 = try update(&m, .{ .select_hunk_at_line = 7 });
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected_hunk);
    try std.testing.expectEqual(Focus.diff, m.focus);
    try m.setStr(&m.diff_text, ""); // 0 ハンクでも underflow しない
    var c2 = try update(&m, .{ .select_hunk_at_line = 5 });
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
}

test "file navigation resets selected_hunk; diff_loaded clamps it" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try addFile(&m, "g.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.selected_hunk = 1;
    var c1 = try update(&m, .key_down); // 別ファイルへ → 0 リセット
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
    // diff_loaded は clamp（リセットしない）。selected_hunk=5 を 1 ハンク diff に当てると 0 に収まる。
    m.selected_hunk = 5;
    var msg = Msg{ .diff_loaded = try a.dupe(u8, "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n") };
    defer msg.deinit(a); // diff_loaded は setStr で複製するため呼び出し側が原本を解放（所有権規約）
    var c2 = try update(&m, msg);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.selected_hunk);
}
```

- [ ] **Step 2: テストを実行して失敗を確認（コンパイルエラー）**

Run: `zig build test --summary all`
Expected: FAIL（新 Msg/AppCmd 未定義、または update の網羅 switch エラー）。

- [ ] **Step 3: messages.zig に Msg 4 種・AppCmd.apply_patch・deinit を追加**

`src/messages.zig` の `Msg` union 内、`scroll_diff_up,` の直後に追加:

```zig
    hunk_next, // diff フォーカス時 j / ↓（ハンクカーソルを次へ）
    hunk_prev, // diff フォーカス時 k / ↑（ハンクカーソルを前へ）
    stage_hunk, // diff フォーカス時 s / space / Enter（section で stage/unstage 決定）
    select_hunk_at_line: usize, // diff ペインクリックの絶対 diff 行（reducer がハンクに解決）
```

`Msg.deinit` の「借用 / 単純」側 switch（`.scroll_diff_up,` を含むリスト）に 4 つを追加:

```zig
            .scroll_diff_down,
            .scroll_diff_up,
            .hunk_next,
            .hunk_prev,
            .stage_hunk,
            .select_hunk_at_line,
            .quit,
```

`AppCmd` union 内、`commit: []u8,` の直後に追加:

```zig
    apply_patch: ApplyPatch,
```

`AppCmd` の `pub const LoadDiff = ...;` の直後に型定義を追加:

```zig
    /// 部分ステージング: 単一ハンクのパッチ（所有）と適用方向。
    /// reverse=false: stage（git apply --cached）。reverse=true: unstage（--reverse）。
    pub const ApplyPatch = struct { patch: []u8, reverse: bool };
```

`AppCmd.deinit` の「所有」側 switch に追加（`.commit => |m| a.free(m),` の直後）:

```zig
            .apply_patch => |ap| a.free(ap.patch),
```

`src/messages.zig` の末尾に所有テストを追加（`test "AppCmd.commit owns ..."` の直後でも可）:

```zig
test "AppCmd.apply_patch owns its patch and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .apply_patch = .{ .patch = try a.dupe(u8, "@@ -1 +1 @@\n-a\n+b\n"), .reverse = true } };
    defer cmd.deinit(a);
    try std.testing.expect(cmd.apply_patch.reverse);
    try std.testing.expectEqualStrings("@@ -1 +1 @@\n-a\n+b\n", cmd.apply_patch.patch);
}
```

- [ ] **Step 4: update.zig に reducer を実装**

`src/update.zig` の `.key_down` / `.key_up` / `.select_index` の各アームに、既存の
`model.diff_scroll = 0;` の直後へ `model.selected_hunk = 0;` を追加する。例（`.key_down`）:

```zig
        .key_down => {
            if (model.selected + 1 < model.files.items.len) model.selected += 1;
            model.diff_scroll = 0;
            model.selected_hunk = 0;
            return loadDiffCmd(model);
        },
```

`.diff_loaded` アームを clamp に変更:

```zig
        .diff_loaded => |text| {
            model.busy = false;
            try model.setStr(&model.diff_text, text);
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            model.selected_hunk = if (parsed.hunks.len == 0) 0 else @min(model.selected_hunk, parsed.hunks.len - 1);
            return .none;
        },
```

`.quit => return .quit,` の直前に新ハンドラを追加:

```zig
        .hunk_next => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (model.selected_hunk + 1 < parsed.hunks.len) model.selected_hunk += 1;
            return .none;
        },
        .hunk_prev => {
            if (model.selected_hunk > 0) model.selected_hunk -= 1;
            return .none;
        },
        .select_hunk_at_line => |line| {
            model.focus = .diff; // diff ペインクリックはフォーカスも移す
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (hunk.hunkIndexForLine(parsed, line)) |i| model.selected_hunk = i;
            return .none;
        },
        .stage_hunk => {
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            if (f.section == .untracked) {
                try model.setStr(&model.error_text, "untracked はファイル単位で stage してください");
                return .none;
            }
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = @min(model.selected_hunk, parsed.hunks.len - 1);
            const patch = try hunk.buildPatch(model.allocator, parsed, idx);
            return .{ .apply_patch = .{ .patch = patch, .reverse = (f.section == .staged) } };
        },
```

- [ ] **Step 5: appcmd.zig に apply_patch 分岐を実装**

`src/appcmd.zig` の `run` の switch、`.commit => |message| { ... }` アームの直後（switch を閉じる `}` の前）に追加:

```zig
        .apply_patch => |ap| {
            // 書込先 Dir を cwd から解決（.dir=借用 / .path=open / .inherit=process cwd）。
            var owned_dir = false;
            var base: std.Io.Dir = switch (cwd) {
                .dir => |d| d,
                .path => |p| blk: {
                    owned_dir = true;
                    break :blk try std.Io.Dir.openDirAbsolute(io, p, .{});
                },
                .inherit => std.Io.Dir.cwd(),
            };
            defer if (owned_dir) base.close(io);
            // .git/ 配下に書く（worktree に出さず status を汚さない）。副作用は worker で
            // 直列化されるため固定名で衝突しない。
            const rel = ".git/git-tui-stage.patch";
            try base.writeFile(io, .{ .sub_path = rel, .data = ap.patch });
            const argv = try cmds.applyPatchArgv(a, ap.reverse, rel);
            defer a.free(argv);
            var res = try process.run(a, io, argv, cwd);
            defer res.deinit(a);
            base.deleteFile(io, rel) catch {}; // status を読む前に消す
            if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            var sres = try cmds.statusRaw(a, io, cwd);
            defer sres.deinit(a);
            if (sres.exit_code != 0) return .{ .git_error = try a.dupe(u8, sres.stderr) };
            return .{ .status_loaded = try statusmod.parse(a, sres.stdout) };
        },
```

- [ ] **Step 6: main.zig の網羅 switch 2 箇所に arm を追加**

`src/main.zig` の `applyAppCmd` の switch を変更:

```zig
    switch (cmd) {
        .none => {},
        .quit => program.quit(),
        .refresh_status, .stage, .unstage, .load_diff, .commit, .apply_patch => dispatchSideEffect(app, cmd),
    }
```

`seedInitialStatus` の `switch (cmd1)` の `.none, .quit => {},` アームを変更（起動チェーンで
apply_patch は生じないが網羅 switch なので no-op arm に含める）:

```zig
        .none, .quit, .apply_patch => {},
```

- [ ] **Step 7: update のユニットテストが緑になることを確認**

Run: `zig build test --summary all`
Expected: PASS（Step 1 で書いた update テスト＋ messages の apply_patch テストが green、既存も green）。

- [ ] **Step 8: appcmd の結合テストを追加**

`src/appcmd.zig` の `test "load_diff failure ..."` の直後に追加:

```zig
test "apply_patch stages a single hunk (partial stage), leaving the rest unstaged" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // 先頭と末尾を変更 → 2 ハンクの unstaged diff（3 行コンテキストで離れているため分離）。
    try repo.writeFile(io, "f.txt", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n");
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 2);
    const patch = try hunk.buildPatch(a, parsed, 0);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = patch, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "f.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
}

test "apply_patch with reverse=true unstages a single staged hunk" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "f.txt", "1x\n2\n3\n4\n5\n6\n7\n8\n9\n10x\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" }); // 全 stage → staged diff に 2 ハンク
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .staged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 2);
    const patch = try hunk.buildPatch(a, parsed, 0);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = patch, .reverse = true } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "f.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
}

test "apply_patch succeeds on a hunk with No-newline-at-eof" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "f.txt", "a"); // 末尾改行を削る → "\ No newline at end of file"
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    const patch = try hunk.buildPatch(a, parsed, 0);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = patch, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error にならず apply 成功
}

test "apply_patch surfaces git_error on a corrupt patch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    const bad = try a.dupe(u8, "--- a/f.txt\n+++ b/f.txt\n@@ -100,1 +100,1 @@\n-zzz\n+yyy\n");
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = bad, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .git_error); // 握り潰さない
}
```

- [ ] **Step 9: 全テストとビルドを確認**

Run: `zig build test --summary all`
Expected: PASS（update ユニット＋appcmd 結合＋messages 所有テスト＋既存すべて green）。

Run: `zig build`
Expected: コンパイル成功（網羅 switch エラー無し）。

- [ ] **Step 10: コミット**

```bash
git add src/messages.zig src/update.zig src/appcmd.zig src/main.zig
git commit -m "feat: ハンク stage/unstage の Msg/AppCmd 経路を end-to-end 配線"
```

---

### Task 6: `src/input.zig` — diff フォーカスのキー分岐とハンククリック選択

**Files:**
- Modify: `src/input.zig`

- [ ] **Step 1: 失敗テストを書く（keyToMsg diff 分岐 + changes 回帰 + マウス）**

`src/input.zig` の `test "changes focus: unmapped char returns null"` の直後に追加:

```zig
test "diff focus: hunk navigation and stage keys map" {
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'j' }).? == .hunk_next);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'k' }).? == .hunk_prev);
    try std.testing.expect(keyToMsg(.diff, .down).? == .hunk_next);
    try std.testing.expect(keyToMsg(.diff, .up).? == .hunk_prev);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 's' }).? == .stage_hunk);
    try std.testing.expect(keyToMsg(.diff, .{ .char = ' ' }).? == .stage_hunk);
    try std.testing.expect(keyToMsg(.diff, .enter).? == .stage_hunk);
    try std.testing.expect(keyToMsg(.diff, .ctrl_d).? == .scroll_diff_down);
    try std.testing.expect(keyToMsg(.diff, .ctrl_u).? == .scroll_diff_up);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'c' }).? == .focus_commit);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'r' }).? == .request_refresh);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'q' }).? == .quit);
    try std.testing.expect(keyToMsg(.diff, .tab).? == .focus_next);
}

test "changes focus mapping is unchanged (regression)" {
    try std.testing.expect(keyToMsg(.changes, .{ .char = 'j' }).? == .key_down);
    try std.testing.expect(keyToMsg(.changes, .{ .char = 's' }).? == .toggle_stage);
    try std.testing.expect(keyToMsg(.changes, .{ .char = ' ' }).? == .toggle_stage);
    try std.testing.expect(keyToMsg(.changes, .enter) == null); // enter は changes では無命令
}
```

マウス behavioral テストを `test "fromZigzagMouse: left press on file row B ..."` の直後に追加:

```zig
test "fromZigzagMouse: click on diff pane yields select_hunk_at_line with scroll offset" {
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    m.diff_scroll = 3; // 表示オフセットを合算する検証
    // diff ペイン (x=50, y=2)。ペイン相対行 = 2 - layout.diff.y(=0) = 2 → 絶対 diff 行 = 3 + 2 = 5。
    const ev = zz.MouseEvent{ .x = 50, .y = 2, .button = .left, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    const msg = mouseToMsg(me);
    try std.testing.expect(msg.? == .select_hunk_at_line);
    try std.testing.expectEqual(@as(usize, 5), msg.?.select_hunk_at_line);
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `zig build test --summary all`
Expected: FAIL（diff 分岐未実装・`select_hunk_at_line` を mouse が出さない）。

- [ ] **Step 3: keyToMsg に diff 分岐を追加**

`src/input.zig` の `keyToMsg` で、`if (focus == .commit) { ... }` ブロックの直後・最後の
`return switch (key) { ... }`（changes 用）の前に追加:

```zig
    if (focus == .diff) {
        return switch (key) {
            .char => |c| switch (c) {
                'j' => .hunk_next,
                'k' => .hunk_prev,
                's', ' ' => .stage_hunk,
                'c' => .focus_commit,
                'r' => .request_refresh,
                'q' => .quit,
                else => null,
            },
            .down => .hunk_next,
            .up => .hunk_prev,
            .enter => .stage_hunk,
            .tab => .focus_next,
            .ctrl_d => .scroll_diff_down,
            .ctrl_u => .scroll_diff_up,
            else => null,
        };
    }
```

- [ ] **Step 4: MouseEvent に diff_line を追加し mouseToMsg/fromZigzagMouse を更新**

`src/input.zig` の `MouseEvent` struct に `on_diff` フィールドの直後に追加:

```zig
    /// diff ペインクリック時の **絶対 diff 行番号**（diff_scroll + ペイン相対行）。null=diff 外。
    diff_line: ?usize = null,
```

`mouseToMsg` の `.left_click` アームを変更（file_row 優先、次に diff_line、次に pane）:

```zig
        .left_click => if (ev.file_row) |r|
            .{ .select_index = r }
        else if (ev.diff_line) |dl|
            .{ .select_hunk_at_line = dl }
        else if (ev.pane) |p|
            .{ .set_focus = p }
        else
            null,
```

`fromZigzagMouse` で、`file_row` を計算した直後に `diff_line` を計算:

```zig
    // diff ペイン内クリックなら、ペイン相対行に diff_scroll を足した絶対 diff 行を作る
    // （renderDiff が diff_scroll を ensure-visible 済みで書き戻すため、描画と一致する）。
    const diff_line: ?usize = if (on_diff)
        model.diff_scroll + @as(usize, ev.y - layout.diff.y)
    else
        null;
```

`fromZigzagMouse` の `switch (ev.button)` 内の各返り値リテラル（`.wheel_up` / `.wheel_down` /
`.left` の `break :blk` 2 箇所 / 末尾 `else`）に `.diff_line = diff_line,` を追加する。例（`.wheel_up`）:

```zig
        .wheel_up => .{ .kind = .wheel_up, .pane = pane, .file_row = file_row, .on_diff = on_diff, .diff_line = diff_line },
```

- [ ] **Step 5: テストを実行して緑を確認**

Run: `zig build test --summary all`
Expected: PASS（diff キー分岐・changes 回帰・diff クリックの全テスト green。既存マウステストは
`diff_line` 既定 null で set_focus 経路を通り不変）。

- [ ] **Step 6: コミット**

```bash
git add src/input.zig
git commit -m "feat(input): diff フォーカスのキー分岐とハンククリック選択を追加"
```

---

### Task 7: `src/view.zig` — `renderDiff` のハイライトと自動スクロール

**Files:**
- Modify: `src/view.zig`

- [ ] **Step 1: import を追加し renderDiff を `*Model` 化・ハイライト/自動スクロールを実装**

`src/view.zig` 冒頭の import に hunk を追加（`const Section = @import("git/status.zig").Section;` の直後）:

```zig
const hunk = @import("diff/hunk.zig");
```

`renderDiff` を以下に置き換える（シグネチャ `*const Model`→`*Model`、ハイライト＋自動スクロール）:

```zig
/// Diff ペイン: `model.diff_text` を `model.diff_scroll` を先頭行として描画。`+`/`-` を色分け。
/// focus==.diff かつ hunk>0 のとき、選択ハンクの @@ ヘッダ行を反転＋マーカー強調し、
/// その行が可視範囲に入るよう `model.diff_scroll` を ensure-visible で書き戻す（diff_scroll の唯一 writer）。
fn renderDiff(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.diff_text.len == 0) return "(no diff)";

    const add_style = zz.Style{ .foreground = zz.Color.green };
    const del_style = zz.Style{ .foreground = zz.Color.red };
    const sel_style = zz.Style{ .reverse_attr = true, .bold_attr = true };

    const limit: usize = if (height == 0) 1 else height;

    // ハンク境界を取得（arena）。失敗時は空スライスでハイライト無しの従来描画にフォールバック。
    const parsed = hunk.parse(a, model.diff_text) catch hunk.ParsedDiff{ .file_header = "", .hunks = &[_]hunk.Hunk{} };
    const hunks = parsed.hunks;

    // 選択ハンクが可視になるよう diff_scroll を ensure-visible（focus==.diff かつ hunk>0 のときのみ）。
    var sel_header_line: ?usize = null;
    if (model.focus == .diff and hunks.len > 0) {
        const sel = @min(model.selected_hunk, hunks.len - 1);
        sel_header_line = hunks[sel].start_line;
        model.diff_scroll = ensureVisible(model.diff_scroll, hunks[sel].start_line, limit);
    }

    // 総行数で clamp（末尾超過の空表示を防ぐ）。
    var total_lines: usize = 0;
    {
        var cit = std.mem.splitScalar(u8, model.diff_text, '\n');
        while (cit.next()) |_| total_lines += 1;
    }
    const scroll_off = clampScroll(model.diff_scroll, total_lines);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, model.diff_text, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx < scroll_off) continue;
        if (lines.items.len >= limit) break;
        // 選択ハンクの @@ ヘッダ行は反転＋左マーカーで強調する。
        if (sel_header_line != null and idx == sel_header_line.?) {
            const marked = std.fmt.allocPrint(a, "\u{258C}{s}", .{line}) catch line;
            lines.append(a, sel_style.render(a, marked) catch marked) catch break;
            continue;
        }
        const styled: []const u8 = if (line.len > 0 and line[0] == '+')
            (add_style.render(a, line) catch line)
        else if (line.len > 0 and line[0] == '-')
            (del_style.render(a, line) catch line)
        else
            line;
        lines.append(a, styled) catch break;
    }
    if (lines.items.len == 0) return "";
    return std.mem.join(a, "\n", lines.items) catch "(diff render error)";
}
```

- [ ] **Step 2: ビルドとテストで型整合・回帰なしを確認**

`render` は既に `model: *Model` を受け取り `renderDiff(model, ctx, layout.diff.h)` を呼ぶため呼び出し側変更は不要。

Run: `zig build`
Expected: コンパイル成功。

Run: `zig build test --summary all`
Expected: PASS（既存 view テストは focus 既定 .changes で diff_scroll を書かない経路を通り不変）。

- [ ] **Step 3: コミット**

```bash
git add src/view.zig
git commit -m "feat(view): renderDiff を *Model 化しハンクハイライト・自動スクロールを実装"
```

---

### Task 8: README / TODO 更新と最終検証（ビルド・テスト・tmux 目視）

**Files:**
- Modify: `README.md`
- Modify: `TODO.md`

- [ ] **Step 1: README にキー操作を追記**

`README.md` のキー操作説明の該当箇所に、diff ペインの操作を追記する（既存のキー表/箇条書きに合わせる）:

```markdown
- diff ペイン（Tab で移動 / クリックで選択）:
  - `j` / `k`: ハンクカーソルを上下に移動
  - `s` / `Space` / `Enter`: 選択中ハンクを stage（unstaged 時）/ unstage（staged 時）
  - `Ctrl+d` / `Ctrl+u`: diff を行スクロール
  - untracked / rename ファイルはハンク単位 stage 非対応（ファイル単位で操作）
```

- [ ] **Step 2: TODO.md の TODO 1 を更新**

`TODO.md` の「TODO 1」の Sub Tasks を更新（phase 1 完了分にチェック、未対応を phase 2 として明記）:

```markdown
### Sub Tasks
- [x] diff のハンク（`@@ ... @@` 単位）を構造化してモデルに保持
- [x] diff ペインでハンク選択 UI（ハイライト・カーソル）を追加
- [x] 選択ハンクから `git apply --cached`（or `--cached --reverse`）用のパッチを生成
- [x] `git apply --cached <tmpfile>` でパッチを適用して stage / unstage（stdin 不可のため一時ファイル方式）
- [ ] 行単位選択（複数行レンジ）→ 部分パッチ生成（phase 2）
- [ ] untracked ファイルのハンク stage（intent-to-add `git add -N`）（phase 2）
- [x] パッチ生成のユニットテスト（コンテキスト行・改行末尾・日本語を含む差分）
- [ ] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）
```

- [ ] **Step 3: 全テストとビルドの最終確認**

Run: `zig build test --summary all`
Expected: PASS（全テスト green、リーク無し）。

Run: `zig build`
Expected: コンパイル成功。

- [ ] **Step 4: tmux で実 pty 目視（非 tty では unverified）**

別シェルで作業用リポジトリのファイルを 2 箇所変更しておき:

```bash
zig build
tmux new-session -d -s gittui -x 120 -y 40 "zig-out/bin/git-tui"
sleep 1
tmux send-keys -t gittui Tab        # diff ペインへフォーカス
tmux send-keys -t gittui j          # ハンク移動
sleep 0.3
tmux capture-pane -t gittui -p      # 選択ハンクが反転＋▌マーカーで強調されているか確認
tmux send-keys -t gittui s          # ハンク stage
sleep 0.5
tmux capture-pane -t gittui -p      # Changes に staged/unstaged 両エントリが出るか確認
tmux send-keys -t gittui q
tmux kill-session -t gittui 2>/dev/null || true
```

Expected: 選択ハンクが反転表示され、`s` で 1 ハンクだけ staged に移り、残りが unstaged に残る。

- [ ] **Step 5: コミット**

```bash
git add README.md TODO.md
git commit -m "docs: ハンク単位 stage のキー操作を README に追記・TODO 1 を更新"
```

---

## 完了時の状態

- diff ペインで `j`/`k` ハンク移動・`s`/`Enter` で stage/unstage（section で方向決定）。
- untracked / rename はファイル単位のみ（案内メッセージ）。
- apply 失敗は git_error で表面化。既存のファイル単位 stage・コミット・マウス・スクロールは不変。
- 純粋層（hunk.parse/buildPatch/hunkIndexForLine、update、applyPatchArgv）はユニットテスト、
  appcmd は実 git の結合テスト、view/input の純粋部はテスト済み。
- 受け入れ基準 1〜10（spec §13）を満たす。各コミットでビルド green を維持。
```
