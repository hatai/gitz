# untracked ファイルのハンク stage 実装計画（TODO 1 phase 2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** untracked ファイル（index 未登録）を行/ハンク単位で部分 stage できるようにする（tracked と同一操作感 `j/k/v/s`）。

**Architecture:** TODO.md 記載の `git add -N`（intent-to-add）方式は採らず、`git apply --cached` 単体経路を使う（実証実験で受理を確認済み）。現行 `buildLinePatch(reverse=false)` が `--no-index` 形式の全行挿入 diff を自然に処理するため、実装変更は `src/update.zig` の `stage_lines` arm から untracked ガード 4 行を削除するだけ。他の全ファイル（`diff/hunk`/`appcmd`/`messages`/`model`/`view`/`input`/`main`/`git/*`）は不変。

**Tech Stack:** Zig 0.16（unmanaged ArrayList / `std.process.run` / `std.Io`）、zigzag v0.1.5 固定、Elm 風純粋 reducer + 副作用隔離。テストは実装と同じ `.zig` 内の `test {}` ブロック、`std.testing.allocator` 必須。

**前提 spec:** `docs/superpowers/specs/2026-06-17-untracked-hunk-stage-design.md`（subagent + codex レビュー経て確定）。

**コマンド（`CLAUDE.md`/`AGENTS.md` 準拠）:**
- ビルド: `zig build`
- テスト: `zig build test --summary all`（**Debug 既定を維持**=実行時安全チェックを保つ。Release にしない）
- **lint / typecheck / format / migration は存在しない。** 型検査と検証は `zig build test` に一本化。
- **単一テストフィルタは `build.zig` に未配線。** 全テストを毎回走らせる。

---

## ファイル構成（変更対象と責務）

| ファイル | 責務 | 本計画での変更 |
|---|---|---|
| `src/diff/hunk.zig` | `parse` / `buildPatch` / `buildLinePatch`（純粋・diff 構造化） | 新規テスト 4 件追加のみ（実装不変） |
| `src/update.zig` | 純粋 reducer `update(*Model, Msg) !AppCmd` | `stage_lines` arm の untracked ガード削除・既存テスト書き換え・新規テスト追加 |
| `src/appcmd.zig` | `AppCmd` 解釈器（git 実行・結合テスト対象） | 新規結合テスト 1 件追加のみ（実装不変） |
| `TODO.md` | 未実装機能の方式/サブタスク | 該当チェックボックス `[x]` 化・留意点追記 |

他（`messages.zig`/`model.zig`/`view.zig`/`input.zig`/`main.zig`/`git/*`）は一切触らない。

---

## Task 1: `src/diff/hunk.zig` の純粋テスト 4 件追加（実装不変）

`buildLinePatch` が untracked の `--no-index` 形式 diff を処理できることを pin する。実装は変更しない（テストのみ）。これらのテストは「untracked ガード削除が安全であること」の純粋層での根拠となる（受け入れ基準 1/2/8/日本語）。

**Files:**
- Modify: `src/diff/hunk.zig`（末尾の既存 `test` ブロック手前に新規テストを追加）
- Test: 同ファイル内 `test {}` ブロック

- [ ] **Step 1: テスト 1（部分選択の基本）を書く**

`src/diff/hunk.zig` の末尾付近（既存の `test "buildLinePatch: Japanese body stages selected line only"` の直後、`test { std.testing.refAllDecls(@This()); }` の直前）へ挿入:

```zig
test "buildLinePatch on untracked (--no-index form): only selected + lines, @@ -0,0 +1,N @@" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,4 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n" ++
        "+L4\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // +L2(行7) と +L3(行8) だけ選択して stage。
    const maybe = try buildLinePatch(a, p, 0, 7, 8, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -0,0 +1,2 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L4\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "--- /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+++ b/new.txt") != null);
    try std.testing.expect(patch[patch.len - 1] == '\n');
}
```

- [ ] **Step 2: テスト 2（フルハンク選択で `buildPatch` と等価）を書く**

直後に挿入。受け入れ基準 2（全行選択 ≈ `git add`）を純粋層で裏付ける:

```zig
test "buildLinePatch on untracked: full-hunk selection equals buildPatch output" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n";
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
    // 全行選択なら buildPatch と等価（git add 相当の index 状態になることの純粋層での裏付け）。
    try std.testing.expectEqualStrings(hunk_patch, line_patch);
}
```

- [ ] **Step 3: テスト 3（No-newline 境界・最終行選択で有効パッチ）を書く**

直後に挿入。受け入れ基準 8（修正後）を pin する。**`null` ではなくマーカー保持の有効パッチが出ることを検証**する（これが spec レビューの blocker 1 で指摘された誤解の再発防止）:

```zig
test "buildLinePatch on untracked: selected final + line keeps No-newline marker (not null)" {
    const a = std.testing.allocator;
    // 末尾改行無しの untracked 3 行ファイル。最終行にのみ \ No newline マーカー。
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n" ++
        "\\ No newline at end of file\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // 最終行 +L3(行8) のみ選択。L1/L2 は未選択→dropped、L3 は選択→kept、マーカーも prev=.kept で保持。
    // untracked では contextified 状態に到達しないため null-conflict は発火せず、有効パッチが返る。
    const maybe = try buildLinePatch(a, p, 0, 8, 8, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -0,0 +1,1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "\\ No newline at end of file") != null); // マーカー保持
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L2\n") == null);
}
```

- [ ] **Step 4: テスト 4（日本語 body）を書く**

直後に挿入。CLAUDE.md の日本語カバー重視に準拠:

```zig
test "buildLinePatch on untracked with Japanese body: only selected line" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/日本語.txt b/日本語.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/日本語.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+一行目\n" ++
        "+二行目\n" ++
        "+三行目\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // +二行目(行7) だけ選択。
    const maybe = try buildLinePatch(a, p, 0, 7, 7, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+二行目\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+一行目\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+三行目\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -0,0 +1,1 @@") != null);
}
```

- [ ] **Step 5: テストを実行して全て PASS することを確認**

Run: `zig build test --summary all`
Expected: PASS（既存テスト全て + 新規 4 件が green）。実装は変更していないため、既存テストは影響を受けるはずが無く、新規 4 件も `buildLinePatch` の既存ロジックで通るはず。

- [ ] **Step 6: Commit**

```bash
git add src/diff/hunk.zig
git commit -m "$(cat <<'EOF'
test(hunk): pin buildLinePatch untracked --no-index handling

Adds 4 pure tests covering untracked file partial staging: partial-select
basic shape (@@ -0,0 +1,N @@), full-hunk select equivalence to buildPatch,
no-newline boundary (final line selected keeps marker, not null), and
Japanese body. buildLinePatch implementation is unchanged.

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>
EOF
)"
```

---

## Task 2: `src/update.zig` の untracked ガード削除 + reducer テスト整備（実装変更の本体）

`stage_lines` arm から untracked ガード（4 行）を削除し、既存テストを busy のみへ縮小、新規テストを追加する。これが本計画で**唯一の実装変更**。

**Files:**
- Modify: `src/update.zig`（`stage_lines` arm + テスト 2 件）
- Test: 同ファイル内 `test {}` ブロック

- [ ] **Step 1: 新規テスト（untracked で apply_patch 発行）を先に書く（TDD・red）**

`src/update.zig` の `test "stage_lines guards: untracked / busy"` の**直前**へ挿入（既存テストは次ステップで書き換える）:

```zig
test "stage_lines on untracked builds apply_patch (reverse=false) for partial stage" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "new.txt", .untracked);
    // untracked の diff（--no-index 形式・全行挿入）を直接セット。
    try m.setStr(&m.diff_text,
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n");
    m.diff_cursor = 7; // +L2 の絶対行（file_header 5 行 + @@ が行5, +L1=6, +L2=7, +L3=8）
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse); // untracked は reverse=false
    // 選択行 L2 のみパッチへ含まれ、L1/L3 は含まれない。
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L3\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -0,0 +1,1 @@") != null);
}
```

- [ ] **Step 2: テストを実行して red（FAIL）を確認**

Run: `zig build test --summary all`
Expected: FAIL。`stage_lines on untracked builds apply_patch` が `cmd == .none` で期待 `.apply_patch` に合わず失敗（現状 untracked ガードが `.none` を返すため）。これで「実装がまだ untracked を弾いている」ことが確認できる。

- [ ] **Step 3: 実装を変更（untracked ガード 4 行を削除・コメント追記）**

`src/update.zig` の `.stage_lines => { ... }` arm 内の下記ブロックを削除:

```zig
            if (f.section == .untracked) {
                try model.setStr(&model.error_text, "untracked はファイル単位で stage してください");
                return .none;
            }
```

削除後、`const f = model.files.items[model.selected];` の直後へコメントを追記して意図を明示する。変更後の arm 先頭部:

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
            // ... 以降（parse → buildLinePatch → apply_patch）は現状どおり変更なし
```

`busy` ゲート・`files.len == 0` ガード・rename(`orig_path != null`)ガードは**残す**。`buildLinePatch(..., f.section == .staged)` の呼び出しも不変（untracked は `.staged` でないため `reverse=false` になる）。`errdefer` 二重ガードも不変。

- [ ] **Step 4: 新規テストが green になることを確認**

Run: `zig build test --summary all`
Expected: `stage_lines on untracked builds apply_patch` が PASS。ただし既存テスト `stage_lines guards: untracked / busy` が untracked を no-op で弾くことを検証しているため**FAIL するはず**（次ステップで書き換える）。

- [ ] **Step 5: 既存テスト `stage_lines guards: untracked / busy` を busy のみへ書き換え**

現状のテスト（2 ケースを 1 test ブロックに入れている）:

```zig
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
```

これを untracked ケース（前半）を削除し、busy のみへ縮小して **test 名も変更**する:

```zig
test "stage_lines guards: busy" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.busy = true;
    var c = try update(&m, .stage_lines);
    defer c.deinit(a);
    try std.testing.expect(c == .none);
}
```

- [ ] **Step 6: テストを実行して全て green を確認**

Run: `zig build test --summary all`
Expected: PASS（既存テスト全て + 新規 1 件 green、書き換えた busy テスト green）。untracked が `apply_patch` を発行するようになり、他の stage_lines テスト（staged/unstaged/rename/context-only/null）は影響を受けないはず。

- [ ] **Step 7: Commit**

```bash
git add src/update.zig
git commit -m "$(cat <<'EOF'
feat(update): enable untracked file partial stage via stage_lines

Removes the untracked guard in stage_lines: buildLinePatch(reverse=false)
naturally handles --no-index all-insert diffs (unselected + dropped,
selected + kept → @@ -0,0 +1,N @@ partial insert patch). git apply --cached
accepts new-file hunks without git add -N (validated by experiment).

Post-stage 1 AM status is absorbed by existing replaceFiles dual-entry logic.
rename guard and busy gate remain. Split stage_lines guards test into
busy-only and added untracked partial-stage reducer test.

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>
EOF
)"
```

---

## Task 3: `src/appcmd.zig` の結合テスト追加（実装不変）

実 git で untracked ファイルの部分 stage が `apply_patch` 経路で成功することを検証する。実装は変更しない（テストのみ）。実証実験 1 で成功した経路そのものを回帰テスト化する。

**Files:**
- Modify: `src/appcmd.zig`（末尾の既存結合テスト群の最後、`apply_patch with git_dir works in a real submodule` の直後へ追加）
- Test: 同ファイル内 `test {}` ブロック

- [ ] **Step 1: 結合テストを書く**

`src/appcmd.zig` の末尾（最後の `test "apply_patch with git_dir works in a real submodule" { ... }` の直後）へ追加。既存の `stagedDiff` ヘルパ（`fn stagedDiff(repo: *TmpRepo, a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8`）を再利用する:

```zig
test "apply_patch stages a partial hunk of an untracked file (new-file create via --cached)" {
    // spec §4.3 結合テスト: untracked ファイル（index 未登録）の部分行 stage が git apply --cached で通る。
    // 実証実験 1 で成功した経路そのものを回帰テスト化する。実装は変更しない（テストのみ）。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // untracked の 10 行ファイルを作る。
    try repo.writeFile(io, "new.txt", "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n");
    // untracked の diff（--no-index）を取得。
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{
        .path = try a.dupe(u8, "new.txt"), .orig_path = null, .section = .untracked,
    } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    // L4-L6（3 行）だけ選択して buildLinePatch。+L4 と +L6 の絶対行を splitScalar で探す。
    var plus_l4: usize = 0;
    var plus_l6: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) {
            if (std.mem.eql(u8, ln, "+L4")) plus_l4 = i;
            if (std.mem.eql(u8, ln, "+L6")) plus_l6 = i;
        }
    }
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_l4, plus_l6, false);
    try std.testing.expect(maybe != null);
    // git apply --cached を実行。git_dir は指定しない（既存のフォールバック cwd 相対 .git/ 経路を使う）。
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{
        .patch = maybe.?, .reverse = false,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error でないこと
    // status が 1 AM（staged + unstaged 混合）になることを確認。
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "new.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
    // index には L4-L6 のみ入ったことを確認。
    const sd = try stagedDiff(&repo, a, io, "new.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L10\n") == null);
}
```

- [ ] **Step 2: テストを実行して green を確認**

Run: `zig build test --summary all`
Expected: PASS。実 git を叩くため数秒かかるが、実証実験と同一経路のため通るはず。

- [ ] **Step 3: Commit**

```bash
git add src/appcmd.zig
git commit -m "$(cat <<'EOF'
test(appcmd): add untracked partial stage integration test

Validates git apply --cached accepts the new-file partial insert patch
(@@ -0,0 +1,N @@) and produces 1 AM status (staged + unstaged mixed),
with only the selected L4-L6 lines entering the index. appcmd
implementation is unchanged.

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>
EOF
)"
```

---

## Task 4: `TODO.md` の該当チェックボックス `[x]` 化 + 留意点追記

`CLAUDE.md`「将来 TODO」の規約に従い、実装完了後に `TODO.md` を更新する（TODO 項目に影響/完了する変更を入れたら該当チェックボックスや記述を更新すること）。

**Files:**
- Modify: `TODO.md`（TODO 1「Sub Tasks」と「留意点」セクション）

- [ ] **Step 1: TODO 1「Sub Tasks」のチェックボックスを `[x]` 化**

現状の行（`TODO.md` 内 TODO 1 の Sub Tasks セクション）:

```
- [ ] untracked ファイルのハンク stage（intent-to-add `git add -N`）（phase 2）
```

これを以下へ置換:

```
- [x] untracked ファイルのハンク stage（phase 2）
  - **方式**: `git add -N`（intent-to-add）ではなく `git apply --cached` 単体で新規作成ハンクを
    直接 apply する（実証実験で受理を確認）。`buildLinePatch(reverse=false)` が `--no-index`
    形式の全行挿入 diff を自然に処理するため、`update.stage_lines` の untracked ガードを削除する
    だけ（`hunk.zig`/`appcmd.zig`/`messages.zig` は一切変更不要）。部分 stage 後は status が `1 AM`
    となり `replaceFiles` が staged+unstaged 2 エントリへ展開する（既存挙動で吸収）。
```

- [ ] **Step 2: TODO 1「留意点」セクションの冒頭へ untracked 方式の記述を追記**

`TODO.md` の TODO 1「留意点」セクションの先頭（`- パッチのコンテキスト行...` の行の直前）へ挿入:

```
- **untracked の部分 stage は `--no-index` 形式の diff が前提**。`git apply --cached` は index 未登録
  パスでも `--- /dev/null` / `+++ b/<file>` 形式の新規作成ハンクを受理する（実証実験 2026-06-17）。
  `git add -N`（intent-to-add）は不要。`buildLinePatch` の変換ルールが全行挿入 diff でそのまま成立つ。
```

- [ ] **Step 3: `zig build test --summary all` で全体 green を最終確認**

Run: `zig build test --summary all`
Expected: PASS（全テスト green・リーク検出クリア）。`TODO.md` 変更自体はテストへ影響しないが、最終確認として全テストを一発回す。

- [ ] **Step 4: Commit**

```bash
git add TODO.md
git commit -m "$(cat <<'EOF'
docs(todo): mark untracked hunk stage as resolved

Updates TODO 1: untracked hunk stage is now implemented via git apply --cached
direct (not git add -N). Notes the --no-index diff prerequisite in the
caveats section.

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>
EOF
)"
```

---

## 完了後の手動検証（オプション・非ブロッキング）

`CLAUDE.md`「TUI の手動検証」に従い tmux pty で untracked ファイルの部分 stage を目視:

1. 作業用 git リポジトリへ untracked の 10 行ファイルを置く。
2. `tmux new-session -x 120 -y 40 -s gttui` → `send-keys "zig build && zig-out/bin/git-tui" Enter`。
3. Changes ペインで untracked ファイルへ `j/k` で移動 → `tab` で diff ペインへ。
4. diff ペインで `j` でハンク本文行へ → `v` で選択開始 → `j` で範囲拡張 → `s` で stage。
5. busy スピナが一瞬出て、status が `1 AM`（staged + unstaged 混合）へ遷移することを `capture-pane -p` で確認。
6. `q` で終了後、`git status` と `git diff --cached` で期待通り（選択行のみ index）を確認。

この手動検証は受け入れ基準 1（部分行 stage）の最終確認だが、結合テスト（Task 3）が同等を自動検証しているため、実機で挙動を観察したい場合のみ実施する。
