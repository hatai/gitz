# git-tui QA 2026-06-18 UX 改善 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TODO.md「QA 2026-06-18 観察による UX 改善提案」の未対応 4 タスク（`v` 視覚化 / rename メタ行 / Ctrl+S README / `#`・`H` ショートカット）を実装する。

**Architecture:** Elm 風・副作用隔離。純粋層（`model/messages/update/diff/hunk`）を TDD で先行し、UI 層（`input/view`）を後続で配線する。既存の `selectionRange` / `validateAnchor` / `buildLinePatch` を再利用し、新規 state は増やさない。`stage_lines` と `stage_hunk` のパッチ構築は共通ヘルパへ切り出し重複を防ぐ。

**Tech Stack:** Zig 0.16.0 + zigzag v0.1.5（固定）。テストは実装 `.zig` 内の `test {}` ブロック、`std.testing.allocator` 必須（リーク検出）。ビルド・テストは `zig build` / `zig build test --summary all`。

**Spec:** `docs/superpowers/specs/2026-06-18-qa-ux-improvements-design.md`

**コマンド（`AGENTS.md` 準拠）:**
- ビルド: `zig build`
- テスト: `zig build test --summary all`（**Debug 既定を維持**。lint/typecheck/format は存在しない）
- 単一テストフィルタは `build.zig` に未配線。必要なら `zig test src/root_test.zig` を直接実行。

**規約:**
- 新規 `.zig` 追加時は `src/root_test.zig` へ `@import` 行を足す（本計画では新規 `.zig` は無し）。
- `Msg`/`AppCmd` の所有ペイロードは複製所有し、消費者が `deinit`。`deinit` の switch は `else` を使わず網羅（コンパイラが新バリアントの判断を強制）。
- コミットメッセージの Co-author 行は付けない（ユーザ指示: レビューは subagent/codex だがコミットは通常どおり）。

---

## ファイル構造

| ファイル | 役割 | 変更 |
|---|---|---|
| `src/messages.zig` | `Msg` tagged union | `select_hunk`, `stage_hunk` 追加 + `deinit` 網羅 |
| `src/diff/hunk.zig` | diff 構造化・パッチ生成 | `hunkBodyBottom` 追加 + テスト |
| `src/update.zig` | 純粋 reducer | `buildStagePatchFromSelection` 抽出、`.stage_lines` リファクタ、`.select_hunk`/`.stage_hunk` arm 追加 + テスト |
| `src/input.zig` | キー→Msg 正規化 | diff フォーカス時 `#`/`H` マッピング |
| `src/model.zig` | 状態 `Model` | `isRenamePartialState` 純粋関数 + テスト |
| `src/view.zig` | zigzag 描画 | `renderDiff` の `>` prefix + rename メタ行、`renderStatus` の `[SELECT]` |
| `README.md` | ユーザ向け docs | `Ctrl+S` 注意書き、`#`/`H` キーマップ表 |
| `TODO.md` | 将来 TODO | 該当 4 チェックボックスを `[x]` 化 |

---

## Task 1: messages.zig — select_hunk / stage_hunk バリアント追加

**Files:**
- Modify: `src/messages.zig`（`Msg` union 定義と `deinit` switch）

- [ ] **Step 1: `Msg` union へバリアントを追加**

`src/messages.zig` の `pub const Msg = union(enum) {` ブロック内、`.stage_lines,` 行の直後に 2 行を追加:

```zig
    stage_lines, // diff フォーカス時 s / space / Enter（選択レンジを stage/unstage）
    select_hunk, // diff フォーカス時 # （現在ハンク本文全体を選択範囲へ）
    stage_hunk, // diff フォーカス時 H （現在ハンクを即 stage/unstage）
    select_line_at: usize, // diff クリックの絶対行（カーソルへ解決・anchor クリア）
```

- [ ] **Step 2: `Msg.deinit` の解放不要グループへ追加**

`src/messages.zig` の `pub fn deinit` 内 switch の「借用 / 単純: 解放不要」グループへ `.select_hunk,` と `.stage_hunk,` を追加。`.stage_lines,` の直後へ:

```zig
            .stage_lines,
            .select_hunk,
            .stage_hunk,
            .select_line_at,
```

- [ ] **Step 3: ビルドで型検査**

Run: `zig build`
Expected: 成功（コンパイルエラー無し）。`deinit` の switch が網羅的でないとコンパイルエラーになるため、Step 2 を忘れるとここで検出される。

- [ ] **Step 4: テスト実行で既存テストが green であることを確認**

Run: `zig build test --summary all`
Expected: 既存テスト全て PASS（新バリアント追加のみで挙動変更無し）。

- [ ] **Step 5: Commit**

```bash
git add src/messages.zig
git commit -m "feat(messages): add select_hunk and stage_hunk Msg variants"
```

---

## Task 2: hunk.zig — hunkBodyBottom ヘルパ追加

**Files:**
- Modify: `src/diff/hunk.zig`（`hunkBodyTop` の近くへ追加）
- Test: `src/diff/hunk.zig` の `test {}` ブロック

- [ ] **Step 1: 失敗するテストを書く**

`src/diff/hunk.zig` の既存 `test "buildPatch emits only the selected hunk..."` の直前あたりへ 3 つのテストを追加:

```zig
test "hunkBodyBottom returns last body line for multi-line hunk" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n" ++
        "@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), p.hunks.len);
    // @@ は行3、本文 ' a'=4, '-b'=5, '+B'=6, ' c'=7 → 最終本文行は 7
    try std.testing.expectEqual(@as(usize, 7), hunkBodyBottom(p.hunks[0]));
}

test "hunkBodyBottom on degenerate hunk (line_count==1) returns start_line" {
    const a = std.testing.allocator;
    // 本文 0 行の退化ハンク（@@ のみ・line_count==1）は実 git diff では出ないが、
    // パーサが寛容に受理する可能性を考慮し start_line へ退化して安全に扱う。
    const h: Hunk = .{ .text = "@@ -1,1 +1,1 @@\n", .start_line = 3, .line_count = 1 };
    try std.testing.expectEqual(@as(usize, 3), hunkBodyBottom(h));
}

test "hunkBodyBottom on hunk with trailing no-newline marker returns the body line" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n" ++
        "@@ -1,1 +1,2 @@\n a\n+B\n\\ No newline at end of file\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), p.hunks.len);
    // @@ は行3、本文 ' a'=4, '+B'=5, '\'=6 → 最終本文行は 5（'\' は本文判定では行頭が '\\' だが
    // hunkBodyBottom は本文行を ' '/'+'/'-' のみと見なすため '\' を本文と見なさず '+B'=5 を返す）
    try std.testing.expectEqual(@as(usize, 5), hunkBodyBottom(p.hunks[0]));
}
```

- [ ] **Step 2: テストを実行して未定義エラーで失敗するか確認**

Run: `zig build test --summary all`
Expected: FAIL（`hunkBodyBottom` 未定義）。

- [ ] **Step 3: `hunkBodyBottom` を実装**

`src/diff/hunk.zig` の `hunkBodyTop` の直後（`pub fn hunkBodyTop` の閉じ `}` の後）へ追加:

```zig
/// ハンク `h` の本文の**最終本文行**（`@@` ヘッダを除く）の絶対行番号を返す。
/// 本文行 = 行頭が `' '`/`'+'`/`'-'` のいずれか。`@@` ヘッダ行（`abs == start_line`）や
/// `\ No newline` マーカー（行頭 `'\'`）は本文行と見なさない。
/// `line_count <= 1`（本文 0 行の退化ハンク）の場合は `start_line` を返す
/// （呼び出し側ガードで弾く前提の安全フォールバック）。
/// `update.zig` の `hunkBodyTop` と対。`update.hunkBodyTop` は `start_line + 1` を返すが、
/// 本関数は絶対行の最終本文行を返すため hunk 本体を行単位で走査する。
pub fn hunkBodyBottom(h: Hunk) usize {
    if (h.line_count <= 1) return h.start_line;
    // h.text を行に分割し、@@ ヘッダの次から最後の本文行（行頭が ' '/'+'/'-'）を探す。
    var it = std.mem.splitScalar(u8, h.text, '\n');
    const header = it.next() orelse return h.start_line; // "@@ ... @@" を読み飛ばす
    _ = header;
    var last_body_abs: usize = h.start_line; // 本文が無ければ @@ 行へ退化（安全）
    var abs: usize = h.start_line + 1;
    while (it.next()) |line| : (abs += 1) {
        if (line.len == 0) continue; // 末尾 \n 由来の空要素
        if (line[0] == ' ' or line[0] == '+' or line[0] == '-') {
            last_body_abs = abs;
        }
    }
    return last_body_abs;
}
```

- [ ] **Step 4: テストを実行して PASS するか確認**

Run: `zig build test --summary all`
Expected: 3 つの新テストが PASS、既存テストも全て PASS。

- [ ] **Step 5: Commit**

```bash
git add src/diff/hunk.zig
git commit -m "feat(hunk): add hunkBodyBottom helper for whole-hunk selection"
```

---

## Task 3: update.zig — 共通ヘルパ抽出 + select_hunk/stage_hunk arm 実装

**Files:**
- Modify: `src/update.zig`（`stage_lines` arm リファクタ + 新 arm 2 つ + ヘルパ）

- [ ] **Step 1: 失敗するテストを書く（select_hunk 系）**

`src/update.zig` の既存 `test "Bug 1 e2e: range selection survives diff_loaded..."` の直後へ追加:

```zig
test "select_hunk sets anchor=body top, cursor=body bottom, focus=diff" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6, h1 本文 8-10
    m.diff_cursor = 5; // h0 本文
    m.focus = .changes; // diff フォーカスで無い状態から
    var cmd = try update(&m, .select_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(m.focus == .diff);
    try std.testing.expectEqual(@as(usize, 4), m.diff_anchor.?); // h0 本文先頭
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // h0 本文末尾
}

test "select_hunk on empty diff (no hunks) is no-op" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try m.setStr(&m.diff_text, ""); // ハンク無し
    m.diff_cursor = 0;
    var cmd = try update(&m, .select_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}

test "select_hunk picks the hunk containing cursor even on @@ header" {
    // cursor が @@ ヘッダ行にあるときも hunkIndexForLine が non-null を返し、
    // そのハンクの本文先頭/末尾へジャンプする。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // @@h0 = 行3
    m.diff_cursor = 3; // @@h0 ヘッダ行
    var cmd = try update(&m, .select_hunk);
    defer cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.diff_anchor.?); // h0 本文先頭
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor); // h0 本文末尾
}
```

- [ ] **Step 2: テストを実行して select_hunk arm 無しでビルドエラーになるか確認**

Run: `zig build test --summary all`
Expected: ビルドエラー（`Msg` に `.select_hunk` があるが switch に arm が無い）。Zig の網羅的 switch はコンパイル時に検出する。

- [ ] **Step 3: `select_hunk` arm を実装**

`src/update.zig` の `update` 関数内、`.stage_lines => { ... }` arm の直後（`.quit => return .quit,` の前）へ追加:

```zig
        .select_hunk => {
            // 現在ハンクの本文全体を選択範囲へ。anchor=本文先頭, cursor=本文末尾。
            // 空 diff / ハンク無しは no-op（panic 回避）。
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const top = hunkBodyTop(parsed.hunks[idx]);
            const bot = hunk.hunkBodyBottom(parsed.hunks[idx]);
            model.focus = .diff;
            model.diff_anchor = top;
            model.diff_cursor = bot;
            return .none;
        },
```

- [ ] **Step 4: テストを実行して select_hunk 系が PASS するか確認**

Run: `zig build test --summary all`
Expected: Task 3 Step 1 の 3 テストが PASS。`stage_hunk` は未実装でビルドエラーのままなので、この時点では `zig build` が通らない。次の Step で `stage_hunk` も実装する。

- [ ] **Step 5: 失敗するテストを書く（stage_hunk 系）**

`src/update.zig` の Task 3 Step 1 で追加したテストの直後へ追加:

```zig
test "stage_hunk builds apply_patch for whole hunk body" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6: ' a', '-b', '+B'
    m.diff_cursor = 5;
    m.focus = .diff;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse); // unstaged → forward
    // h0 全体がパッチへ含まれる: -b と +B 両方
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "-b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+B\n") != null);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択消費
}

test "stage_hunk on empty diff is no-op" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try m.setStr(&m.diff_text, "");
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "stage_hunk respects busy guard" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    m.busy = true;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
}

test "stage_hunk respects rename guard (orig_path != null)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 .R の unstaged エントリ（orig_path != null）
    try m.files.append(m.allocator, .{
        .path = try m.allocator.dupe(u8, "new.txt"),
        .orig_path = try m.allocator.dupe(u8, "old.txt"),
        .section = .unstaged,
    });
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    var cmd = try update(&m, .stage_hunk);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, m.error_text, "rename") != null);
}

test "select_hunk followed by auto-refresh preserves anchor (Bug 1 e2e analog)" {
    // select_hunk 後に diff_loaded が来ても validateAnchor が保持する。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6
    try m.setDiffOwner("f.txt", .unstaged); // 層 1 セットアップ
    m.diff_cursor = 5;
    var c1 = try update(&m, .select_hunk);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 4), m.diff_anchor);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
    // auto-refresh シミュレーション: 同じ diff で diff_loaded 再送
    const same = try a.dupe(u8, m.diff_text);
    defer a.free(same);
    var c2 = try update(&m, .{ .diff_loaded = same });
    c2.deinit(a);
    // 層 1（owner 一致）+ 層 2（anchor=h0本文, cursor=同h0）で保持
    try std.testing.expectEqual(@as(?usize, 4), m.diff_anchor);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
}
```

- [ ] **Step 6: `buildStagePatchFromSelection` 共通ヘルパを追加**

`src/update.zig` の `fn clampCursor` の直前（既存ヘルパ群の近く）へ追加:

```zig
/// 選択レンジから apply_patch AppCmd を構築する共通ヘルパ（stage_lines / stage_hunk 共用）。
/// 純粋（Model を read-only で参照・error_text のみ setStr で変更）。
/// - rename ガードは呼び出し側で済ませること（本関数は f.orig_path を見ない）。
/// - 戻り値: `.apply_patch`（成功）または `.none`（null パッチ時は error_text をセット）。
/// ★本関数は model.diff_anchor を clear しない。呼び出し側が消費後に clear する（責務分離）。
fn buildStagePatchFromSelection(
    model: *Model,
    parsed: hunk.ParsedDiff,
    idx: usize,
    sel: struct { lo: usize, hi: usize },
) !AppCmd {
    const f = model.files.items[model.selected];
    const maybe = try hunk.buildLinePatch(model.allocator, parsed, idx, sel.lo, sel.hi, f.section == .staged);
    if (maybe) |patch| {
        errdefer model.allocator.free(patch);
        const gd: ?[]u8 = if (model.git_dir) |g| try model.allocator.dupe(u8, g) else null;
        errdefer if (gd) |x| model.allocator.free(x);
        return .{ .apply_patch = .{
            .patch = patch,
            .reverse = (f.section == .staged),
            .git_dir = gd,
        } };
    }
    try model.setStr(&model.error_text, "選択範囲を stage できません（変更行なし、または末尾改行境界）");
    return .none;
}
```

- [ ] **Step 7: `stage_lines` arm をヘルパ呼び出しへリファクタ**

`src/update.zig` の `.stage_lines => { ... }` arm を、以下のように `buildStagePatchFromSelection` を使う形へ書き換える。**rename ガードと busy ガードと選択消費（`diff_anchor = null`）は arm 側に残す**:

```zig
        .stage_lines => {
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            // untracked ガード削除（2026-06-17）: buildLinePatch(reverse=false) が --no-index diff の
            //   全行挿入を自然に処理する（未選択 + は削除、選択 + は保持 → @@ -0,0 +1,N @@ の部分挿入パッチ）。
            //   git apply --cached は index 未登録パスも新規作成として受理する（実証実験で確認）。
            //   部分 stage 後は status が 1 AM となり replaceFiles が staged+unstaged 2 エントリへ展開する。
            //   No-newline マーカーは直前の + 行の kept/dropped に追従し、文脈化は発生しないため null にはならない。
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse return .none;
            const sel = @import("model.zig").selectionRange(model.diff_cursor, model.diff_anchor);
            const cmd = try buildStagePatchFromSelection(model, parsed, idx, sel);
            model.diff_anchor = null; // 成否に関わらず選択は消費（null パスでもハイライトを残さない）
            return cmd;
        },
```

- [ ] **Step 8: `stage_hunk` arm を実装**

`src/update.zig` の `.select_hunk => { ... }` arm の直後（`.quit => return .quit,` の前）へ追加。

**注意**: `select_hunk` と異なり `model.diff_cursor = bot` をセットする（選択視覚化で cursor が範囲末尾にあり `▌` マーカーで本文末尾を示すため）。`buildStagePatchFromSelection` は `sel` を直接受け取るため cursor 値はパッチ構築に影響しないが、Bug 1 e2e analog テスト（auto-refresh 後の validateAnchor）が cursor と anchor の同ハンク性を検証するため、cursor は本文末尾にある必要がある:

```zig
        .stage_hunk => {
            // 現在ハンクの本文全体を即 stage（select_hunk + stage_lines と等価）。
            // 空 diff / busy / rename ガード付き。
            if (model.busy) return .none;
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            if (f.orig_path != null) {
                try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
                return .none;
            }
            var parsed = try hunk.parse(model.allocator, model.diff_text);
            defer parsed.deinit(model.allocator);
            if (parsed.hunks.len == 0) return .none;
            const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0;
            const top = hunkBodyTop(parsed.hunks[idx]);
            const bot = hunk.hunkBodyBottom(parsed.hunks[idx]);
            model.focus = .diff;
            model.diff_cursor = bot; // 視覚化: cursor は本文末尾（▌ マーカー）
            model.diff_anchor = top;
            const sel = @import("model.zig").selectionRange(bot, top); // [top, bot]
            const cmd = try buildStagePatchFromSelection(model, parsed, idx, sel);
            model.diff_anchor = null; // 選択消費
            return cmd;
        },
```

- [ ] **Step 9: テストを実行して stage_hunk 系と既存 stage_lines 系が PASS するか確認**

Run: `zig build test --summary all`
Expected: 全テスト PASS。`stage_lines` のリファクタで既存テスト（`stage_lines on unstaged...` / `Bug 1 e2e...` 等）が green のまま、新 stage_hunk テスト 4 つと select_hunk テスト 3 つも PASS。

- [ ] **Step 10: Commit**

```bash
git add src/update.zig
git commit -m "feat(update): add select_hunk/stage_hunk arms + extract buildStagePatchFromSelection"
```

---

## Task 4: input.zig — `#` / `H` キーマップ追加

**Files:**
- Modify: `src/input.zig`（`keyToMsg` の diff フォーカス時 `char` switch）

- [ ] **Step 1: 失敗するテストを書く**

`src/input.zig` の `test` ブロック（既存の `keyToMsg` テストの近く）へ追加。まず既存テストの位置を確認:

```bash
grep -n "keyToMsg" src/input.zig | head
```

以下のテストを `src/input.zig` のテスト群（`fn pointInRect` テスト等の近く）へ追加:

```zig
test "keyToMsg diff focus: '#' maps to select_hunk" {
    try std.testing.expectEqual(@as(?Msg, .select_hunk), keyToMsg(.diff, .{ .char = '#' }));
}

test "keyToMsg diff focus: 'H' maps to stage_hunk" {
    try std.testing.expectEqual(@as(?Msg, .stage_hunk), keyToMsg(.diff, .{ .char = 'H' }));
}

test "keyToMsg diff focus: lowercase 'h' is unmapped (stays null)" {
    // 大文字 H のみ。小文字 h は未割当（将来 vim 系 left 等と衝突回避）。
    try std.testing.expectEqual(@as(?Msg, null), keyToMsg(.diff, .{ .char = 'h' }));
}
```

- [ ] **Step 2: テストを実行して FAIL するか確認**

Run: `zig build test --summary all`
Expected: FAIL（`#`/`H` が `null` を返すため）。

- [ ] **Step 3: キーマップを実装**

`src/input.zig` の `keyToMsg` 関数、`if (focus == .diff) { return switch (key) { .char => |c| switch (c) { ...` ブロックの `'v' => .toggle_line_selection,` の直後へ 2 行を追加:

```zig
                'v' => .toggle_line_selection,
                '#' => .select_hunk,
                'H' => .stage_hunk,
                ']' => .diff_hunk_next,
```

- [ ] **Step 4: テストを実行して PASS するか確認**

Run: `zig build test --summary all`
Expected: 3 つの新テスト PASS、既存テストも全て green。

- [ ] **Step 5: Commit**

```bash
git add src/input.zig
git commit -m "feat(input): map '#' to select_hunk and 'H' to stage_hunk in diff focus"
```

---

## Task 5: model.zig — isRenamePartialState 純粋関数

**Files:**
- Modify: `src/model.zig`（`selectByPathPriority` の近くへ追加）

- [ ] **Step 1: 失敗するテストを書く**

`src/model.zig` のテストブロック（`test "selectByPathPriority defensive fallback..."` の直後）へ追加:

```zig
test "isRenamePartialState: 2 RM staged entry with unstaged sibling returns true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 RM 展開後: staged(new.txt, orig=old.txt) + unstaged(new.txt, orig=null)
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .staged,
    });
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = null,
        .section = .unstaged,
    });
    m.selected = 0; // staged 側を選択
    try std.testing.expect(isRenamePartialState(&m));
}

test "isRenamePartialState: 2 R. (full stage, no unstaged sibling) returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .staged,
    });
    // unstaged 兄弟無し（完全 stage）→ false
    m.selected = 0;
    try std.testing.expect(!isRenamePartialState(&m));
}

test "isRenamePartialState: 1 AM staged entry (orig_path null) returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{
        .path = try a.dupe(u8, "f.txt"),
        .orig_path = null,
        .section = .staged,
    });
    try m.files.append(a, .{
        .path = try a.dupe(u8, "f.txt"),
        .orig_path = null,
        .section = .unstaged,
    });
    m.selected = 0;
    try std.testing.expect(!isRenamePartialState(&m)); // orig_path null
}

test "isRenamePartialState: 2 .R unstaged entry returns false (section mismatch)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.files.append(a, .{
        .path = try a.dupe(u8, "new.txt"),
        .orig_path = try a.dupe(u8, "old.txt"),
        .section = .unstaged,
    });
    m.selected = 0;
    try std.testing.expect(!isRenamePartialState(&m)); // section が unstaged
}

test "isRenamePartialState: empty files returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expect(!isRenamePartialState(&m));
}
```

- [ ] **Step 2: テストを実行して未定義エラーで失敗するか確認**

Run: `zig build test --summary all`
Expected: FAIL（`isRenamePartialState` 未定義）。

- [ ] **Step 3: `isRenamePartialState` を実装**

`src/model.zig` の `fn selectByPathPriority` の直前（`/// ビジュアル選択レンジ...` の `pub fn selectionRange` の直前）へ追加:

```zig
/// 現在選択中のエントリが「rename の部分 stage 状態」（2 RM 等）かを純粋判定する。
/// true の条件（全て AND）:
///   1. files 非空 かつ selected が有効
///   2. selected エントリの section == .staged
///   3. selected エントリの orig_path != null（rename/copy 由来）
///   4. 同 path を持つ .unstaged エントリが files 内に存在（content modify がまだ残っている）
/// 条件 4 は 2 R.（rename+内容変更が両方 staged・完全 stage）と 2 RM（rename staged + content
/// modify unstaged）を区別する。view.renderDiff がメタ行表示の判定に使う。純粋・allocator 不要。
pub fn isRenamePartialState(model: *const Model) bool {
    if (model.files.items.len == 0) return false;
    if (model.selected >= model.files.items.len) return false;
    const cur = model.files.items[model.selected];
    if (cur.section != .staged) return false;
    if (cur.orig_path == null) return false;
    // 同 path の .unstaged エントリが存在するか
    for (model.files.items) |f| {
        if (f.section == .unstaged and std.mem.eql(u8, f.path, cur.path)) return true;
    }
    return false;
}
```

- [ ] **Step 4: テストを実行して PASS するか確認**

Run: `zig build test --summary all`
Expected: 5 つの新テスト PASS、既存テストも全て green。

- [ ] **Step 5: Commit**

```bash
git add src/model.zig
git commit -m "feat(model): add isRenamePartialState for rename+modify diff display"
```

---

## Task 6: view.zig — `>` prefix / rename メタ行 / SELECT 表示

**Files:**
- Modify: `src/view.zig`（`renderDiff` と `renderStatus`）

- [ ] **Step 1: `renderDiff` の `in_sel` ブロックで `>` prefix を付ける**

`src/view.zig` の `renderDiff` 関数、`if (in_sel) { ... }` ブロックを以下へ書き換える。`line` の前に `>` を付けてから `sel_style` を適用する:

```zig
        if (in_sel) {
            // タスク A: anchor 非 null のとき範囲全体に `>` prefix + reverse（テキストダンプでも選択判別可能）。
            const prefixed = std.fmt.allocPrint(a, ">{s}", .{line}) catch line;
            lines.append(a, sel_style.render(a, prefixed) catch prefixed) catch break;
            continue;
        }
```

- [ ] **Step 2: `renderDiff` の冒頭で rename メタ行を挿入**

`src/view.zig` の `renderDiff` 関数、`if (model.diff_text.len == 0) return "(no diff)";` の直後へ、rename メタ行の準備を追加。`var lines: std.ArrayList([]const u8) = .empty;` の宣言の後、`var it = std.mem.splitScalar(...)` の前にメタ行を push する。

**limit との相互作用**: 既存の本文描画ループ `while (it.next()) |line| ...` は `if (lines.items.len >= limit) break;` で打ち切るため、メタ行を先頭へ入れると本文は `limit - 1` 行になる（diff の最終 1 行が隠れることがある）。これは `model.diff_text` へ触れない代償として許容する（spec §3.2・§8 リスク記載）。`ensureVisible(model.diff_scroll, model.diff_cursor, limit)` は `limit` を使うため、メタ行有りでも cursor 可視性は担保される（cursor 行自体は本文側にあるため）。

```zig
    var lines: std.ArrayList([]const u8) = .empty;

    // タスク B: rename+modify の部分 stage 状態（2 RM）で diff が new file mode になる誤認防止。
    // model.diff_text に触れず、描画時のみ先頭行へメタ行を差し込む（diffLineCount 不整合回避）。
    if (@import("model.zig").isRenamePartialState(model)) {
        const cur = model.files.items[model.selected];
        const orig = cur.orig_path orelse "";
        const meta = std.fmt.allocPrint(a, "[rename staged: {s} → {s} · content partial]", .{ orig, cur.path }) catch "[rename staged · content partial]";
        lines.append(a, meta) catch {};
    }

    var it = std.mem.splitScalar(u8, model.diff_text, '\n');
```

- [ ] **Step 3: `renderStatus` を `[SELECT]` 表示 + `#`/`H` hint 追加へ書き換え**

`src/view.zig` の `renderStatus` 関数全体を、以下の最終形へ書き換える。変更点:
- `select_indicator`: `model.focus == .diff and model.diff_anchor != null` で `[SELECT]  `（末尾スペ 2 つ）を立てる。
- `hint_base`: diff フォーカス時に `# hunk  H stage-hunk` を追加（タスク D の案内）。
- `hint`: `select_indicator + hint_base` を結合（`allocPrint` 失敗時は `hint_base` へフォールバック）。
- 戻り値の `base` と `hint` の結合は `"{s}  {s}"`（スペース 2 つ）で一貫性を保つ。

```zig
/// Status バー: branch / busy スピナ / error_text / キーヒント。
/// スピナは `model.working`（変更系操作の実行中のみ）で出す。`model.busy`（全 in-flight ゲート）では
/// 出さない＝自動リフレッシュ/ナビゲーションの読み取りでステータスバーが点滅しない。
/// タスク A: diff フォーカス + anchor 非 null のとき `[SELECT]` を先頭に表示（テキストダンプでも判別）。
fn renderStatus(model: *const Model, ctx: *const zz.Context) []const u8 {
    const a = ctx.allocator;
    const branch = if (model.branch.len == 0) "(detached)" else model.branch;
    const spin = if (model.working) " [busy]" else "";
    const select_indicator: []const u8 = if (model.focus == .diff and model.diff_anchor != null)
        "[SELECT]  "
    else
        "";
    const hint_base = if (model.focus == .diff)
        "j/k line  v select  # hunk  H stage-hunk  s stage/unstage  ]/[ hunk  tab pane  r refresh  q quit"
    else
        "j/k move  space stage  c commit  r refresh  q quit";
    const hint = std.fmt.allocPrint(a, "{s}{s}", .{ select_indicator, hint_base }) catch hint_base;
    const base = std.fmt.allocPrint(a, " {s}{s}", .{ branch, spin }) catch " ?";
    if (model.error_text.len > 0) {
        const err_style = zz.Style{ .foreground = zz.Color.red, .bold_attr = true };
        const err = err_style.render(a, model.error_text) catch model.error_text;
        return std.fmt.allocPrint(a, "{s}  {s}  {s}", .{ base, err, hint }) catch base;
    }
    return std.fmt.allocPrint(a, "{s}  {s}", .{ base, hint }) catch base;
}
```

（元の関数のドキュメントコメント・branch・spin 計算は据え置き。`hint` 生成と最終戻り値の結合のみ変更。）

- [ ] **Step 4: ビルドで型検査**

Run: `zig build`
Expected: 成功。

- [ ] **Step 5: テスト実行で既存テストが green であることを確認**

Run: `zig build test --summary all`
Expected: view.zig のテストは `refAllDecls` と純粋関数（`ensureVisible`/`clampScroll`/`changesRowLayout`/`fitPane`）のみで描画文字列検証は無しため、既存テストは green のまま。`isRenamePartialState` テストも green。

- [ ] **Step 6: 手動 pty 検証（tmux で視認）**

実機で確認（`CLAUDE.md` の手順）:

```bash
# 作業用スクラッチリポジトリで
mkdir -p /tmp/qa-ux && cd /tmp/qa-ux && git init -q
echo a > f.txt && git add f.txt && git commit -qm "init"
echo b >> f.txt  # unstaged 変更

# tmux で起動
tmux new-session -d -s qa -x 100 -y 30
tmux send-keys -t qa "cd /tmp/qa-ux && zig build && zig-out/bin/git-tui" Enter
sleep 2
tmux send-keys -t qa Tab # diff ペインへ
tmux send-keys -t qa v   # 範囲選択開始
sleep 1
tmux capture-pane -p -t qa | tail -5  # [SELECT] インジケータと > prefix を視認
tmux send-keys -t qa q
tmux kill-session -t qa
```

Expected: ステータスバーに `[SELECT]`、範囲行に `>` prefix が付く（キャプチャで確認）。

- [ ] **Step 7: rename メタ行の手動検証**

```bash
cd /tmp/qa-ux
git mv f.txt renamed.txt
echo c >> renamed.txt
git add renamed.txt  # rename を stage
# この時点で 2 RM（rename staged + content modify unstaged）

tmux new-session -d -s qa2 -x 100 -y 30
tmux send-keys -t qa2 "cd /tmp/qa-ux && zig-out/bin/git-tui" Enter
sleep 2
tmux send-keys -t qa2 Tab # diff ペイン（staged 側の renamed.txt が選択されている前提）
sleep 1
tmux capture-pane -p -t qa2 | head -5  # [rename staged: f.txt → renamed.txt · content partial] を視認
tmux send-keys -t qa2 q
tmux kill-session -t qa2
```

Expected: diff ペイン先頭に `[rename staged: f.txt → renamed.txt · content partial]` メタ行。

- [ ] **Step 8: Commit**

```bash
git add src/view.zig
git commit -m "feat(view): add SELECT indicator, range prefix, rename partial meta line"
```

---

## Task 7: README.md + TODO.md 更新

**Files:**
- Modify: `README.md`（キーマップ表）
- Modify: `TODO.md`（チェックボックス）

- [ ] **Step 1: README のキーマップ表へ `#` / `H` と `Ctrl+S` 注意書きを追加**

`README.md` の「操作キー」セクション、diff フォーカス時の表の末尾（`s` / `space` / `Enter（diff フォーカス時）` 行の後）へ 2 行を追加:

```markdown
| `#`（diff フォーカス時） | 現在ハンク全体を選択範囲に設定（`s` で stage） |
| `H`（diff フォーカス時） | 現在ハンクを即 stage / unstage |
```

また、`Ctrl+S` 行の直後に注意書き段落を追加:

```markdown
> **注意**: 一部の端末では `Ctrl+S` がフロー制御（XOFF）に捕捉され、コミットが実行されないことがあります。その場合は `stty -ixon` を実行して無効化してください（シェルの起動ファイルへ追記すると恒久化されます）。
```

- [ ] **Step 2: TODO.md のチェックボックスを更新**

`TODO.md` の「QA 2026-06-18 観察による UX 改善提案」セクションの 4 つの `- [ ]` を `- [x]` へ変更:

```markdown
- [x] **`v` トグル状態の視覚的明示**（低優先・UX）
- [x] **rename+modify の staged diff 表示の補足**（低優先・UX）
- [x] **commit の `Ctrl+S` キーバインドの代替検証**（低優先・互換性）
- [x] **`#` 等でハンク全体を選択するショートカット**（新規・任意）
```

各項目の「提案」段落へ「**対応済み（2026-06-18）**: 」行を追加し、spec/plan への参照を書く。例:

```markdown
  - **対応済み**（2026-06-18）: ステータスバーに `[SELECT]` インジケータ、範囲行頭に `>` prefix を実装。
    spec: `docs/superpowers/specs/2026-06-18-qa-ux-improvements-design.md` §2。
```

（rename メタ行は §3、Ctrl+S は §4、`#`/`H` は §5 への参照。）

- [ ] **Step 3: Commit**

```bash
git add README.md TODO.md
git commit -m "docs: add UX improvements to README and mark TODO checkboxes done"
```

---

## 最終検証

- [ ] **Step F1: 全テスト実行**

Run: `zig build test --summary all`
Expected: 全テスト PASS（リーク検出含む）。

- [ ] **Step F2: 配布ビルドが成功するか確認**

Run: `zig build -Doptimize=ReleaseFast`
Expected: 成功（ReleaseFast でも型検査・最適化が通る）。

- [ ] **Step F3: 実機 e2e（全 4 タスクを 1 シナリオで）**

スクラッチリポジトリで以下を順に実行し、全タスクが連携するか確認:

1. `v` 押下 → `[SELECT]` と `>` prefix 表示（タスク A）
2. `#` 押下 → ハンク全体選択 → `s` で stage（タスク D の select_hunk）
3. `H` 押下 → ハンク即 stage（タスク D の stage_hunk）
4. rename+modify ファイルを選択 → メタ行表示（タスク B）
5. `Ctrl+S` でコミット成功（README の `stty -ixon` 注意書きは実動作と無関係だが、`Ctrl+S` が効く環境で確認）

---

## 受け入れ基準（spec §7 準拠）

- `zig build test --summary all` が全テスト green。
- `zig build` が型検査通過。
- 実機 pty 検証（tmux capture-pane）で 4 タスク全て確認。
- README のキーマップ表に `Ctrl+S` 注意書き、`#`/`H` が追記されている。
- TODO.md の該当 4 チェックボックスが `- [x]` になっている。
