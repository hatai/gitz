# 行単位 stage / unstage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** diff ペイン内の変更を行カーソル＋連続レンジで選択し、その範囲だけを stage / unstage できるようにする（tracked ファイルのみ）。

**Architecture:** 純粋層 `src/diff/hunk.zig` に行レンジ部分パッチ生成 `buildLinePatch` を追加し、`AppCmd.apply_patch`（既存・無改変）で `git apply --cached [--reverse]` に流す。`Model.selected_hunk` を `diff_cursor`/`diff_anchor` に置換し、reducer・入力・描画を行カーソル基準に組み替える。Elm 風（純粋 reducer ↔ 副作用解釈器）を踏襲。

**Tech Stack:** Zig 0.16（unmanaged ArrayList・`std.process.run` 等の Writergate 規約）、zigzag 0.1.5。テストは実装と同じ `.zig` 内 `test {}`、`std.testing.allocator`。

**Spec:** `docs/superpowers/specs/2026-06-16-line-staging-design.md`

**コミット規約:** メッセージ末尾に
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```
を付ける。ブランチは `feat/line-staging`（作成済み）。

**ビルド緑の不変条件:** Task 3〜7 は `selected_hunk` と旧 Msg（`hunk_next`/`hunk_prev`/`stage_hunk`/`select_hunk_at_line`）を**残したまま**新機能を追加する（各コミットがコンパイル＆テスト緑）。Task 8 で旧物を一括撤去する。

各タスク末尾の検証は `zig build test --summary all`（既定 Debug 維持）。

---

## File Structure

- `src/diff/hunk.zig` — **Modify**: `buildLinePatch` と内部 `parseHeader` を追加（純粋層の中心）。
- `src/appcmd.zig` — **Modify**: 行レンジ部分パッチの実 git ラウンドトリップ結合テストを追加。
- `src/model.zig` — **Modify**: `selected_hunk` 撤去、`diff_cursor`/`diff_anchor` 追加。
- `src/update.zig` — **Modify**: `clampCursor` ヘルパ＋新 Msg ハンドラ。旧ハンドラは Task 8 で撤去。
- `src/messages.zig` — **Modify**: 新 Msg 追加、旧 Msg は Task 8 で撤去。
- `src/input.zig` — **Modify**: diff キー写像とマウス写像を新 Msg へ。
- `src/view.zig` — **Modify**: `renderDiff` をカーソル ensure-visible ＋選択レンジ強調へ。status ヒント更新。
- `TODO.md` — **Modify**: 該当チェックボックスと将来項目を更新。

---

## Task 1: `buildLinePatch`（純粋層・部分パッチ生成）

**Files:**
- Modify: `src/diff/hunk.zig`（`buildPatch` の直後に追加）
- Test: `src/diff/hunk.zig`（同ファイル内 `test {}`）

- [ ] **Step 1: 失敗するテストを書く（stage forward / unstage reverse / フル等価 / null 2 種）**

`src/diff/hunk.zig` の末尾 `test { std.testing.refAllDecls(@This()); }` の**直前**に追記する:

```zig
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
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test --summary all`
Expected: コンパイルエラー（`buildLinePatch` 未定義）。

- [ ] **Step 3: `buildLinePatch` と `parseHeader` を実装**

`src/diff/hunk.zig` の `buildPatch`（89 行目あたりの `}`）の**直後**に追加:

```zig
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
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（全テスト緑）。

- [ ] **Step 5: コミット**

```bash
git add src/diff/hunk.zig
git commit -m "feat(diff): buildLinePatch で行レンジ部分パッチを生成（純粋層・TDD）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: 行レンジ stage/unstage の実 git ラウンドトリップ結合テスト

**Files:**
- Test: `src/appcmd.zig`（既存 `apply_patch` テスト群の直後、`test "apply_patch surfaces git_error..."` の後）

既存 `TmpRepo` / `runOwned` / ローカル `process`（`process.run(a, io, argv, cwd)`）ヘルパ（同ファイル内・import 済み）を使う。`git diff --cached --` の出力で index 状態を assert する。**フィクスチャは純粋な挿入**（置換ではない）にする — 置換は git diff が `-...` 群と `+...` 群にまとめるため、単一 `+` 行選択だと文脈化行の後ろへ挿入され「曖昧だが apply は通る」状態になり検証が弱い。挿入なら単一行選択が一意に効く。

- [ ] **Step 1: 失敗するテストを書く（forward 行 stage / reverse 行 unstage）**

`src/appcmd.zig` の `test "apply_patch surfaces git_error on a corrupt patch"`（363 行目の `}`）の**直後**に追記:

```zig
// 一時 repo で `git diff --cached -- <path>` の出力（index 状態）を複製して返すヘルパ。
fn stagedDiff(repo: *TmpRepo, a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var r = try process.run(a, io, &.{ "git", "diff", "--cached", "--", path }, repo.cwd());
    defer r.deinit(a);
    return try a.dupe(u8, r.stdout); // 呼び出し側が free
}

test "apply_patch (line stage forward): only the selected inserted line enters the index" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\nc\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // a と c の間に B1/B2 を挿入（純粋挿入）。
    try repo.writeFile(io, "f.txt", "a\nB1\nB2\nc\n");
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len == 1);
    // '+B1' 行だけ選択して stage。'+B1' の絶対行を探す。
    var plus_b1: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) if (std.mem.eql(u8, ln, "+B1")) {
            plus_b1 = i;
        };
    }
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_b1, plus_b1, false);
    try std.testing.expect(maybe != null);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = maybe.?, .reverse = false } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error でないこと
    // index には B1 のみ入り、B2 はまだ unstaged。
    const sd = try stagedDiff(&repo, a, io, "f.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B2\n") == null);
}

test "apply_patch (line unstage reverse): only the selected inserted line leaves the index" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "f.txt", "a\nc\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    try repo.writeFile(io, "f.txt", "a\nB1\nB2\nc\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" }); // 全 stage
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .staged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    var plus_b1: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) if (std.mem.eql(u8, ln, "+B1")) {
            plus_b1 = i;
        };
    }
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_b1, plus_b1, true);
    try std.testing.expect(maybe != null);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{ .patch = maybe.?, .reverse = true } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    // index からは B1 だけ外れ（staged diff に +B1 が消える）、B2 はまだ staged。
    const sd = try stagedDiff(&repo, a, io, "f.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+B2\n") != null);
}
```

- [ ] **Step 2: テストが失敗→通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（`buildLinePatch` は Task 1 で実装済みのため、テスト追加のみで緑になる）。`process.run` の戻り値 `RunResult` のフィールド名（`.stdout`/`.deinit`）は同ファイルの既存利用に一致。万一食い違えば `src/git/process.zig` の定義に合わせる。

- [ ] **Step 3: コミット**

```bash
git add src/appcmd.zig
git commit -m "test(appcmd): 行レンジ stage/unstage の実 git ラウンドトリップ検証

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `Model` に `diff_cursor` / `diff_anchor` を追加

`selected_hunk` は**残したまま**新フィールドを追加する（ビルド緑維持）。

**Files:**
- Modify: `src/model.zig:22`（フィールド宣言）, `src/model.zig:41`（`init`）

- [ ] **Step 1: フィールドを追加**

`src/model.zig` の `selected_hunk: usize,`（22 行目）の**直後**に追加:

```zig
    diff_cursor: usize, // diff ペインのカーソル（絶対 diff 行 index）。行単位選択の基準。
    diff_anchor: ?usize, // ビジュアル選択の anchor（絶対 diff 行）。null=範囲未選択。
```

`init` の `.selected_hunk = 0,`（41 行目）の**直後**に追加:

```zig
            .diff_cursor = 0,
            .diff_anchor = null,
```

（どちらもスカラのため `deinit` の変更は不要。）

- [ ] **Step 2: ビルドが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（新フィールド追加のみ、既存テストに影響なし）。

- [ ] **Step 3: コミット**

```bash
git add src/model.zig
git commit -m "feat(model): diff_cursor/diff_anchor を追加（行単位選択の状態）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: 新 `Msg` バリアントを追加

旧 Msg（`hunk_next`/`hunk_prev`/`stage_hunk`/`select_hunk_at_line`）は**残す**（Task 8 で撤去）。

**Files:**
- Modify: `src/messages.zig:21`（宣言）, `src/messages.zig:61`（`deinit` の網羅 switch）

- [ ] **Step 1: バリアントを追加**

`src/messages.zig` の `select_hunk_at_line: usize, ...`（21 行目）の**直後**に追加:

```zig
    diff_cursor_down, // diff フォーカス時 j / ↓（行カーソルを次の本文行へ）
    diff_cursor_up, // diff フォーカス時 k / ↑（行カーソルを前の本文行へ）
    diff_hunk_next, // diff フォーカス時 ]（次ハンク本文先頭へ）
    diff_hunk_prev, // diff フォーカス時 [（前ハンク本文先頭へ）
    toggle_line_selection, // diff フォーカス時 v（anchor のトグル）
    stage_lines, // diff フォーカス時 s / space / Enter（選択レンジを stage/unstage）
    select_line_at: usize, // diff クリックの絶対行（カーソルへ解決・anchor クリア）
```

`deinit` の網羅 switch（借用/単純グループ、`.select_hunk_at_line,`=61 行目）の**直後**に追加:

```zig
            .diff_cursor_down,
            .diff_cursor_up,
            .diff_hunk_next,
            .diff_hunk_prev,
            .toggle_line_selection,
            .stage_lines,
            .select_line_at,
```

- [ ] **Step 2: `update` に一時集約 no-op ハンドラを置く（ビルド緑維持）**

新 Msg を追加すると `src/update.zig` の `switch (msg)`（`else` 無しの網羅 switch）がコンパイルエラーになる。Task 5 で本実装に差し替えるまでの暫定として、`.quit => return .quit,`（128 行目あたり）の**直前**に集約ハンドラを追加:

```zig
        // Task 5 で本実装に差し替える暫定 no-op（網羅 switch を満たすため）。
        .diff_cursor_down,
        .diff_cursor_up,
        .diff_hunk_next,
        .diff_hunk_prev,
        .toggle_line_selection,
        .stage_lines,
        .select_line_at,
        => return .none,
```

- [ ] **Step 3: ビルドが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（新 Msg 追加＋暫定 no-op で網羅性を満たす。挙動はまだ無し）。

- [ ] **Step 4: コミット**

```bash
git add src/messages.zig src/update.zig
git commit -m "feat(messages): 行カーソル操作の Msg を追加（reducer は暫定 no-op）

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: reducer に行カーソル操作を実装

**Files:**
- Modify: `src/update.zig`（`hunk_prev` ハンドラ群の付近にケース追加、`diff_loaded` を変更、`clampCursor` ヘルパ追加）
- Test: `src/update.zig`（同ファイル内）

- [ ] **Step 1: 失敗するテストを書く**

`src/update.zig` の末尾 `test { std.testing.refAllDecls(@This()); }` の**直前**に追記:

```zig
// seedTwoHunkDiff の絶対行: file_header 0..2 / @@h0=3 ' a'4 '-b'5 '+B'6 / @@h1=7 ' x'8 '+Y'9 ' z'10
test "diff_cursor_down/up skip @@ headers and clamp to body lines" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 4; // h0 本文先頭 ' a'
    var c1 = try update(&m, .diff_cursor_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), m.diff_cursor); // '-b'
    m.diff_cursor = 6; // h0 末尾本文 '+B'
    var c2 = try update(&m, .diff_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor); // @@h1(7) を飛ばして ' x'(8)
    m.diff_cursor = 8;
    var c3 = try update(&m, .diff_cursor_up);
    c3.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // 戻りも @@h1 を飛ばす
}

test "diff_hunk_next/prev jump to hunk body tops and clear anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 4; // h0
    m.diff_anchor = 4;
    var c1 = try update(&m, .diff_hunk_next);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 8), m.diff_cursor); // h1 本文先頭
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
    var c2 = try update(&m, .diff_hunk_prev);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.diff_cursor); // h0 本文先頭
}

test "toggle_line_selection sets then clears anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    var c1 = try update(&m, .toggle_line_selection);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor);
    var c2 = try update(&m, .toggle_line_selection);
    c2.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "stage_lines on unstaged builds apply_patch for the cursor line and clears anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 6; // '+B'（h0 の変更行）
    m.diff_anchor = 6;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+B\n") != null);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択消費
}

test "stage_lines on staged sets reverse=true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .staged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 6;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(cmd.apply_patch.reverse);
}

test "stage_lines on context-only selection is no-op (null patch)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 4; // ' a' 文脈行のみ
    m.diff_anchor = null;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "stage_lines guards: untracked / busy" {
    const a = std.testing.allocator;
    {
        var m = try Model.init(a, "/r");
        defer m.deinit();
        try addFile(&m, "u.txt", .untracked);
        try seedTwoHunkDiff(&m);
        m.diff_cursor = 6;
        var c1 = try update(&m, .stage_lines);
        c1.deinit(a);
        try std.testing.expect(c1 == .none);
        try std.testing.expect(m.error_text.len > 0);
    }
    {
        var m = try Model.init(a, "/r");
        defer m.deinit();
        try addFile(&m, "f.txt", .unstaged);
        try seedTwoHunkDiff(&m);
        m.busy = true;
        var c2 = try update(&m, .stage_lines);
        c2.deinit(a);
        try std.testing.expect(c2 == .none);
    }
}

test "diff_loaded clamps cursor into a hunk body and resets anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.diff_cursor = 999;
    m.diff_anchor = 3;
    const diff = try a.dupe(u8, "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,1 +1,2 @@\n a\n+B\n");
    var cmd = try update(&m, .{ .diff_loaded = diff });
    cmd.deinit(a);
    // file_header 0..3 / @@=4 / ' a'=5 / '+B'=6 → 範囲外 999 は先頭ハンク本文先頭(5) へ。
    try std.testing.expectEqual(@as(usize, 5), m.diff_cursor);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "select_line_at moves cursor, sets diff focus, clears anchor" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_anchor = 4;
    var cmd = try update(&m, .{ .select_line_at = 9 }); // h1 '+Y'
    cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 9), m.diff_cursor);
    try std.testing.expect(m.focus == .diff);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test --summary all`
Expected: FAIL（暫定 no-op ハンドラのため挙動が無く、新規テストが期待値と不一致）。

- [ ] **Step 3: Task 4 の暫定ブロックを削除し、`clampCursor` ヘルパと本実装を追加**

まず Task 4 で追加した暫定集約ブロック（`// Task 5 で本実装に差し替える暫定 no-op` から `=> return .none,` まで）を**削除**する。次に以下を実装する。

まず `src/update.zig` の `update` 関数の**閉じ括弧の後（`loadDiffCmd` などの他ヘルパの並び）**に `clampCursor` を追加:

```zig
/// diff 再読込/カーソル移動後にカーソルを本文行へ正規化し anchor をリセットする（純粋）。
/// - ハンク 0 個: cursor=0。
/// - カーソルがどのハンク本文にも属さない（file_header/ヘッダ/範囲外）: 先頭ハンク本文先頭へ。
/// - 既にいずれかのハンク本文内: そのまま維持（リフレッシュ時のジャンプ防止）。
/// anchor は常に null へ（再読込/ファイル切替で選択は無効）。
fn clampCursor(model: *Model) !void {
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    model.diff_anchor = null;
    if (parsed.hunks.len == 0) {
        model.diff_cursor = 0;
        return;
    }
    if (hunk.hunkIndexForLine(parsed, model.diff_cursor) == null) {
        const h0 = parsed.hunks[0];
        model.diff_cursor = if (h0.line_count > 1) h0.start_line + 1 else h0.start_line;
    }
}

/// 絶対行 `abs` が「本文行」（いずれかのハンク内 かつ @@ ヘッダ行でない）かを返す。
fn isBodyLine(parsed: hunk.ParsedDiff, abs: usize) bool {
    if (hunk.hunkIndexForLine(parsed, abs)) |i| return abs != parsed.hunks[i].start_line;
    return false;
}
```

次に新 Msg ハンドラを追加する。`src/update.zig` の `.hunk_prev => {...}` ケース（93 行目あたり）の**直後**に追加:

```zig
        .diff_cursor_down => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            var total: usize = 0;
            var cit = std.mem.splitScalar(u8, model.diff_text, '\n');
            while (cit.next()) |_| total += 1;
            var n = model.diff_cursor + 1;
            while (n < total) : (n += 1) {
                if (isBodyLine(parsed, n)) {
                    model.diff_cursor = n;
                    break;
                }
            }
            return .none;
        },
        .diff_cursor_up => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            var n = model.diff_cursor;
            while (n > 0) {
                n -= 1;
                if (isBodyLine(parsed, n)) {
                    model.diff_cursor = n;
                    break;
                }
            }
            return .none;
        },
        .diff_hunk_next => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const cur = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const next = @min(cur + 1, parsed.hunks.len - 1);
            const h = parsed.hunks[next];
            model.diff_cursor = if (h.line_count > 1) h.start_line + 1 else h.start_line;
            model.diff_anchor = null;
            return .none;
        },
        .diff_hunk_prev => {
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const cur = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const prev = if (cur == 0) 0 else cur - 1;
            const h = parsed.hunks[prev];
            model.diff_cursor = if (h.line_count > 1) h.start_line + 1 else h.start_line;
            model.diff_anchor = null;
            return .none;
        },
        .toggle_line_selection => {
            model.diff_anchor = if (model.diff_anchor == null) model.diff_cursor else null;
            return .none;
        },
        .select_line_at => |line| {
            model.focus = .diff;
            model.diff_cursor = line;
            try clampCursor(model); // 本文外クリックはハンク本文へクランプ・anchor リセット
            return .none;
        },
        .stage_lines => {
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
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse return .none;
            const anchor = model.diff_anchor orelse model.diff_cursor;
            const lo = @min(model.diff_cursor, anchor);
            const hi = @max(model.diff_cursor, anchor);
            const maybe = try hunk.buildLinePatch(model.allocator, parsed, idx, lo, hi, f.section == .staged);
            if (maybe) |patch| {
                model.diff_anchor = null; // 選択消費
                return .{ .apply_patch = .{ .patch = patch, .reverse = (f.section == .staged) } };
            }
            try model.setStr(&model.error_text, "選択範囲に stage できる変更行がありません");
            return .none;
        },
```

最後に `diff_loaded` ハンドラ（135〜142 行目）の `selected_hunk` clamp の**後ろ**に `clampCursor` 呼び出しを追加する。`diff_loaded` ケースを次のように変更:

```zig
        .diff_loaded => |text| {
            model.busy = false;
            try model.setStr(&model.diff_text, text);
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            model.selected_hunk = if (parsed.hunks.len == 0) 0 else @min(model.selected_hunk, parsed.hunks.len - 1);
            try clampCursor(model);
            return .none;
        },
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add src/update.zig
git commit -m "feat(update): 行カーソル移動・選択・行 stage/unstage を reducer に実装

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: 入力写像を行カーソル操作へ

**Files:**
- Modify: `src/input.zig:52-63`（diff キー写像）, `src/input.zig:112-113`（マウス写像）
- Test: `src/input.zig`（既存 diff テストを更新・追加）

- [ ] **Step 1: 失敗するテストを書く**

`src/input.zig` の `test "diff focus: hunk navigation and stage keys map"`（296 行目）を次の新テストに**置き換える**（旧テストは Task 8 で消える Msg を参照しているため、ここで新 Msg ベースに更新）:

```zig
test "diff focus: line cursor / selection / hunk-jump / stage keys map" {
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'j' }).? == .diff_cursor_down);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'k' }).? == .diff_cursor_up);
    try std.testing.expect(keyToMsg(.diff, .down).? == .diff_cursor_down);
    try std.testing.expect(keyToMsg(.diff, .up).? == .diff_cursor_up);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 'v' }).? == .toggle_line_selection);
    try std.testing.expect(keyToMsg(.diff, .{ .char = ']' }).? == .diff_hunk_next);
    try std.testing.expect(keyToMsg(.diff, .{ .char = '[' }).? == .diff_hunk_prev);
    try std.testing.expect(keyToMsg(.diff, .{ .char = 's' }).? == .stage_lines);
    try std.testing.expect(keyToMsg(.diff, .{ .char = ' ' }).? == .stage_lines);
    try std.testing.expect(keyToMsg(.diff, .enter).? == .stage_lines);
}
```

`test "fromZigzagMouse: click on diff pane yields select_hunk_at_line with scroll offset"`（453 行目）の `select_hunk_at_line` を `select_line_at` に更新（テスト名と assert 2 箇所）:

```zig
test "fromZigzagMouse: click on diff pane yields select_line_at with scroll offset" {
    // ... 既存の本文をそのまま、末尾 2 行の assert を差し替え:
    try std.testing.expect(msg.? == .select_line_at);
    try std.testing.expectEqual(@as(usize, 5), msg.?.select_line_at);
}
```
（先頭 `m.diff_scroll = 3;` 等の本文は変更不要。`select_hunk_at_line` を `select_line_at` に変えるだけ。）

- [ ] **Step 2: テストが失敗することを確認**

Run: `zig build test --summary all`
Expected: FAIL（写像が旧 Msg のまま）。

- [ ] **Step 3: 写像を更新**

`src/input.zig` の `if (focus == .diff)` ブロック（51〜68 行目）を次に置換:

```zig
    if (focus == .diff) {
        return switch (key) {
            .char => |c| switch (c) {
                'j' => .diff_cursor_down,
                'k' => .diff_cursor_up,
                'v' => .toggle_line_selection,
                ']' => .diff_hunk_next,
                '[' => .diff_hunk_prev,
                's', ' ' => .stage_lines,
                'c' => .focus_commit,
                'r' => .request_refresh,
                'q' => .quit,
                else => null,
            },
            .down => .diff_cursor_down,
            .up => .diff_cursor_up,
            .enter => .stage_lines,
            .tab => .focus_next,
            .ctrl_d => .scroll_diff_down,
            .ctrl_u => .scroll_diff_up,
            else => null,
        };
    }
```

`mouseToMsg` の diff クリック（112〜113 行目）の `.{ .select_hunk_at_line = dl }` を次に変更:

```zig
        else if (ev.diff_line) |dl|
            .{ .select_line_at = dl }
```

- [ ] **Step 4: テストが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add src/input.zig
git commit -m "feat(input): diff キー/マウスを行カーソル操作へ写像

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `renderDiff` をカーソル ensure-visible ＋選択レンジ強調へ

**Files:**
- Modify: `src/view.zig:193-258`（`renderDiff`）, `src/view.zig:279-282`（`renderStatus` ヒント）

> **テスト方針:** 既存 view テストは純粋関数のみ（`computeLayout`/`ensureVisible`/`clampScroll`/`fitPane`/`changesRowLayout`）で、`zz.Context` を構築して `renderDiff`/`renderChanges` を直接呼ぶテストは**存在しない**。`renderChanges` の ensure-visible も `ensureVisible` の純粋テスト（363 行目）に検証を委ねている。本タスクも同パターンに従い、新規 Context 依存テストは**書かない**。カーソル ensure-visible は `model.diff_scroll = ensureVisible(...)`（既存純粋テストでカバー済み）、選択レンジは `@min`/`@max` の自明計算。表示崩れ・カーソル追従の最終確認は Task 8 の pty 目視で行う。

- [ ] **Step 1: `renderDiff` を書き換える**

`src/view.zig` の `renderDiff`（193〜258 行目）の本体を次に置換。`selected_hunk` 依存のハンク重なり調整を**カーソル行 ensure-visible** に、`@@` ヘッダ強調を**カーソル行＋選択レンジ強調**に変更する:

```zig
fn renderDiff(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    const a = ctx.allocator;
    if (model.diff_text.len == 0) return "(no diff)";

    const add_style = zz.Style{ .foreground = zz.Color.green };
    const del_style = zz.Style{ .foreground = zz.Color.red };
    const sel_style = zz.Style{ .reverse_attr = true, .bold_attr = true };

    const limit: usize = if (height == 0) 1 else height;

    // 総行数。
    var total_lines: usize = 0;
    {
        var cit = std.mem.splitScalar(u8, model.diff_text, '\n');
        while (cit.next()) |_| total_lines += 1;
    }

    // focus==.diff のときカーソル行を可視範囲に収める（diff_scroll の唯一 writer）。
    // ensureVisible はカーソルが窓の外なら scroll を最小限ずらす（マウス当たり判定と一致）。
    if (model.focus == .diff) {
        model.diff_scroll = ensureVisible(model.diff_scroll, model.diff_cursor, limit);
    }
    const scroll_off = clampScroll(model.diff_scroll, total_lines);

    // 選択レンジ [lo, hi]（anchor 非 null 時のみ）。
    const sel_lo: ?usize = if (model.diff_anchor) |anc| @min(model.diff_cursor, anc) else null;
    const sel_hi: usize = if (model.diff_anchor) |anc| @max(model.diff_cursor, anc) else model.diff_cursor;

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, model.diff_text, '\n');
    var idx: usize = 0;
    while (it.next()) |line| : (idx += 1) {
        if (idx < scroll_off) continue;
        if (lines.items.len >= limit) break;
        const is_cursor = (model.focus == .diff and idx == model.diff_cursor);
        const in_sel = (model.focus == .diff and sel_lo != null and idx >= sel_lo.? and idx <= sel_hi);
        if (is_cursor) {
            const marked = std.fmt.allocPrint(a, "\u{258C}{s}", .{line}) catch line;
            lines.append(a, sel_style.render(a, marked) catch marked) catch break;
            continue;
        }
        if (in_sel) {
            lines.append(a, sel_style.render(a, line) catch line) catch break;
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

`renderStatus` の diff ヒント（279〜282 行目）を更新:

```zig
    const hint = if (model.focus == .diff)
        "  j/k line  v select  s stage/unstage  ]/[ hunk  tab pane  r refresh  q quit"
    else
        "  j/k move  space stage  c commit  r refresh  q quit";
```

- [ ] **Step 2: ビルド＋全テストが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（既存 `ensureVisible`/`fitPane` テストが緑のまま）。

- [ ] **Step 3: コミット**

```bash
git add src/view.zig
git commit -m "feat(view): diff をカーソル ensure-visible＋選択レンジ強調へ

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: 旧 `selected_hunk` / 旧 Msg の撤去と TODO 更新

**Files:**
- Modify: `src/model.zig`（`selected_hunk` 削除）, `src/update.zig`（旧ハンドラ・旧テスト削除、`key_down`/`key_up`/`select_index` の `selected_hunk=0` を `diff_cursor=0`/`diff_anchor=null` に置換）, `src/messages.zig`（旧 Msg 削除）, `TODO.md`

- [ ] **Step 1: `update.zig` のナビ系で selected_hunk リセットを置換**

`key_down`（17〜21 行目）/`key_up`（23〜27）/`select_index`（29〜34）の各 `model.selected_hunk = 0;` を次へ置換（3 箇所）:

```zig
            model.diff_cursor = 0;
            model.diff_anchor = null;
```

- [ ] **Step 2: 旧 Msg ハンドラと旧テストを削除**

`src/update.zig` から次を削除:
- `.hunk_next => {...}`（86〜91）, `.hunk_prev => {...}`（92〜95）, `.select_hunk_at_line => |line| {...}`（96〜108）, `.stage_hunk => {...}`（109〜127）の 4 ハンドラ。
- 旧テスト: `"hunk_next/hunk_prev move within hunk count and clamp"`, `"stage_hunk on unstaged ..."`, `"stage_hunk on staged ..."`, `"stage_hunk on untracked ..."`, `"stage_hunk on rename ..."`, `"stage_hunk while busy ..."`, `"select_hunk_at_line resolves ..."`, および `"file navigation resets selected_hunk; diff_loaded clamps it"`（`selected_hunk` を参照するため。同等の検証は Task 5 の `diff_loaded clamps cursor` テストが担う）。

`diff_loaded` ハンドラの `model.selected_hunk = ...;` 行（Task 5 で残した行）を削除し、`clampCursor` のみ残す:

```zig
        .diff_loaded => |text| {
            model.busy = false;
            try model.setStr(&model.diff_text, text);
            try clampCursor(model);
            return .none;
        },
```

- [ ] **Step 3: `model.zig` から `selected_hunk` を削除**

`src/model.zig` の `selected_hunk: usize, ...`（22 行目）の宣言と、`init` の `.selected_hunk = 0,`（41 行目）を削除。

- [ ] **Step 4: `messages.zig` から旧 Msg を削除**

`src/messages.zig` の宣言（18〜21 行目 `hunk_next`/`hunk_prev`/`stage_hunk`/`select_hunk_at_line`）と、`deinit` 網羅 switch の対応 4 エントリ（58〜61 行目）を削除。

- [ ] **Step 5: ビルドが通ることを確認（旧物の参照漏れ検出）**

Run: `zig build test --summary all`
Expected: PASS。失敗する場合は `selected_hunk` / 旧 Msg の参照残り（grep `selected_hunk`, `hunk_next`, `hunk_prev`, `stage_hunk`, `select_hunk_at_line` で 0 件になるまで）を解消。

- [ ] **Step 6: `TODO.md` を更新**

`TODO.md` の TODO 1 Sub Tasks:
- `- [ ] 行単位選択（複数行レンジ）→ 部分パッチ生成（phase 2）` を `- [x]` に変更。

TODO 1 の「留意点」の phase 2 既知制約リストに次の 2 項目を追加:

```markdown
  - **行単位 stage の phase 2 で未対応（さらに将来）**:
    - 飛び飛び（discontiguous）のマーク集合選択（チェックボックス型）。現状は連続レンジのみ。
    - マウスのドラッグ範囲拡張 / Shift クリック範囲拡張（`MouseEvent` に修飾キーフィールド追加が前提。現状クリックはカーソル移動のみ）。
    - No-newline 境界に掛かる選択は矛盾パッチ回避のため no-op（ガイダンス表示）。
```

- [ ] **Step 7: 全テスト＋実機 pty 確認（任意だが推奨）**

Run: `zig build test --summary all`
Expected: PASS（全モジュール）。

実機確認（CLAUDE.md「対話 TUI は tmux で検証」）:
```bash
zig build
# tmux で git リポジトリ内に起動し、diff フォーカスで j/k 移動・v 範囲・s stage を目視
```

- [ ] **Step 8: コミット**

```bash
git add src/model.zig src/update.zig src/messages.zig TODO.md
git commit -m "refactor: selected_hunk と旧ハンク Msg を撤去し行カーソルへ一本化

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 完了条件

- `zig build test --summary all` が全緑。
- diff フォーカスで `j/k` 行移動・`v` 範囲選択・`s`/space/Enter で行 stage/unstage・`]`/`[` ハンクジャンプ・クリックでカーソル移動が動作。
- `git grep -nE "selected_hunk|hunk_next|hunk_prev|stage_hunk|select_hunk_at_line"` が 0 件。
- `TODO.md` の「行単位選択」が `[x]`、将来項目（マーク集合・ドラッグ範囲）が追記済み。
