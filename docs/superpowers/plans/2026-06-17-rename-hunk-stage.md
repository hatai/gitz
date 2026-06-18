# rename ファイルのハンク stage 実装計画（TODO 1 phase 2 完了）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rename + modify の頻出パターン（porcelain `2 RM`）の部分 stage が現状で動くことを、回帰テストで固定化し、TODO.md の最後の未対応サブタスクを完了させる。

**Architecture:** ソースコード変更なし（`2 RM` は `status.parse` が展開した unstaged エントリの `orig_path == null` により、現行ガード `if (f.orig_path != null)` を通過する）。実装は純粋層（`status.zig`）・reducer（`update.zig`）・結合（`appcmd.zig`）への回帰テスト追加と TODO.md 更新のみ。

**Tech Stack:** Zig 0.16.0 + zigzag v0.1.5 固定。テストは実装 `.zig` 内 `test {}` ブロック・`std.testing.allocator` 必須（CLAUDE.md「テスト規約」）。

**Spec:** `docs/superpowers/specs/2026-06-17-rename-hunk-stage-design.md`

**前提知識（CLAUDE.md から）:**
- ビルド: `zig build`、テスト: `zig build test --summary all`（Debug 既定維持）
- 単一テストフィルタは `build.zig` 未配線。全テストは `zig build test` で一括実行。
- `std.ArrayList(T)` は unmanaged（`.empty` / `append(a, x)`）。
- 既存 `addFile(m, path, section)` ヘルパは `orig_path = null` 固定。rename エントリは `m.files.append(a, .{ .path = ..., .orig_path = try a.dupe(u8, "old.txt"), .section = ... })` で直接構築する。

---

## File Structure

- **Modify:** `src/git/status.zig` — 新規テスト1件追加（`2 RM` の orig_path 不一致不変条件）。実装ロジック（`appendOrdinary`）は触らない。
- **Modify:** `src/update.zig` — 新規テスト3件追加（`2 RM` unstaged → apply_patch / staged rename → ガード / `2 .R` unstaged → ガード）。`stage_lines` reducer 本体は触らない。
- **Modify:** `src/appcmd.zig` — 新規テスト1件追加（実 git で `git mv` + unstaged 変更の部分 stage が `2 RM` → `2 R.` へ遷移）。
- **Modify:** `TODO.md` — サブタスク `[ ] rename ファイルのハンク stage` を `[x]` へ。留意点へ実証結果と既知の制約2件を追記。

---

### Task 1: status.zig に `2 RM` の orig_path 不一致テストを追加

**Files:**
- Modify: `src/git/status.zig`（ファイル末尾・既存 `unstaged-side rename (XY=.R)` テストの直後）
- Test: 同ファイル内 `test {}` ブロック

**背景:** これが本タスクの核心不変条件。`status.parse` が porcelain `2 RM` を展開したとき、
staged 側は `orig_path = old.txt` を持ち、unstaged 側は `orig_path = null` になる。
この不一致により、`update.stage_lines` の現行ガード（`f.orig_path != null`）は
unstaged 側を通す。既存テスト `parses rename (type 2)` は `2 R.`（X='R', Y='.'）のみで
`2 RM` をカバーしていないため必須。

- [ ] **Step 1: テストを追加する（実装は既に存在・TDD の RED ではなく不変条件の固定化）**

`src/git/status.zig` の末尾（`test "unstaged-side rename (XY=.R) puts orig_path on the unstaged entry"` の直後・ファイル末尾の `}` の前）へ、以下のテストを追記する:

```zig

test "rename+modify (XY=RM): staged keeps orig_path, unstaged has null orig_path" {
    // spec 2026-06-17-rename-hunk-stage-design.md §2 実験1 の核心不変条件。
    // X='R'(rename) は staged 側へ orig_path を付き、Y='M'(modify) は is_y_rename=false
    // なので unstaged 側へは orig_path が付かない（null）。この不一致により、
    // update.stage_lines の現行ガード (f.orig_path != null) は unstaged 側を通過させる。
    const a = std.testing.allocator;
    const raw = "2 RM N... 100644 100644 100644 9405325 9405325 R100 new.txt\x00old.txt\x00";
    const entries = try parse(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    // staged 側: path=new.txt, orig_path=old.txt
    try std.testing.expectEqual(Section.staged, entries[0].section);
    try std.testing.expectEqualStrings("new.txt", entries[0].path);
    try std.testing.expect(entries[0].orig_path != null);
    try std.testing.expectEqualStrings("old.txt", entries[0].orig_path.?);
    // unstaged 側: path=new.txt, orig_path=null（Y='M' は rename ではない）
    try std.testing.expectEqual(Section.unstaged, entries[1].section);
    try std.testing.expectEqualStrings("new.txt", entries[1].path);
    try std.testing.expect(entries[1].orig_path == null);
}
```

- [ ] **Step 2: テストを実行して PASS を確認**

Run: `zig build test --summary all`
Expected: PASS（全テスト成功・新テスト `rename+modify (XY=RM)...` が含まれる）。
実装は既に正しいため RED にはならず、いきなり GREEN になることがこのタスクの成功の証。

- [ ] **Step 3: コミット**

```bash
git add src/git/status.zig
git commit -m "test(status): pin 2 RM orig_path asymmetry (staged keeps, unstaged null)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 2: update.zig に `2 RM` unstaged → apply_patch テストを追加

**Files:**
- Modify: `src/update.zig`（既存 `stage_lines on untracked builds apply_patch` テストの直後）
- Test: 同ファイル内 `test {}` ブロック

**背景:** `2 RM` を展開した unstaged エントリ（`orig_path == null && section == .unstaged`）上で
`stage_lines` を実行したとき、現行ガードを通過して `apply_patch`（`reverse=false`）が発行されることを固定化する。
diff は `new.txt` 単体の content-only diff（rename ヘッダ無し）を想定。
モデルの `files` へは `orig_path = null` で直接 append する（`2 RM` 由来の unstaged エントリを再現）。

- [ ] **Step 1: テストを追記する**

`src/update.zig` の `test "stage_lines on untracked builds apply_patch (reverse=false) for partial stage"` の直後へ、以下のテストを追記する:

```zig

test "stage_lines on 2 RM unstaged entry (orig_path=null) builds apply_patch (reverse=false)" {
    // spec 2026-06-17-rename-hunk-stage-design.md §3.4: 2 RM の unstaged 側は
    // orig_path == null なので現行ガードを通過し、buildLinePatch(reverse=false) へ進む。
    // これが本タスクの核心「2 RM の部分 stage は現状で動く」の回帰保護。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 RM 展開後の unstaged エントリ: path=new.txt, orig_path=null, section=.unstaged
    // （addFile ヘルパは orig_path=null 固定なのでそのまま使える）
    try addFile(&m, "new.txt", .unstaged);
    // git mv 済み状態の unstaged 側 diff（rename ヘッダ無し・content-only）
    try m.setStr(&m.diff_text,
        "diff --git a/new.txt b/new.txt\n" ++
        "index 9405325..6fe8acc 100644\n" ++
        "--- a/new.txt\n" ++
        "+++ b/new.txt\n" ++
        "@@ -1,5 +1,5 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+X\n" ++
        " c\n" ++
        " d\n" ++
        " e\n");
    m.diff_cursor = 7; // +X の絶対行（file_header 4 行 + @@ が行4, ' a'=5, '-b'=6, '+X'=7）
    m.diff_anchor = 7;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse); // unstaged → forward
    // 選択行 +X のみ保持。未選択 -b は文脈化（' b'）され、元の -b としては残らない。
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+X\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "-b\n") == null);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // 選択消費
    try std.testing.expect(m.error_text.len == 0); // ガードメッセージ無し
}
```

- [ ] **Step 2: テストを実行して PASS を確認**

Run: `zig build test --summary all`
Expected: PASS（新テスト `stage_lines on 2 RM unstaged entry...` 含む全テスト成功）。

- [ ] **Step 3: コミット**

```bash
git add src/update.zig
git commit -m "test(update): pin 2 RM unstaged partial stage via apply_patch

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 3: update.zig に staged rename ガード維持テストを追加

**Files:**
- Modify: `src/update.zig`（Task 2 で追記したテストの直後）
- Test: 同ファイル内 `test {}` ブロック

**背景:** staged rename エントリ（`orig_path != null && section == .staged`）上で `stage_lines` を実行したとき、
現行ガードが発火して `.none` を返し、`error_text` に「rename はファイル単位で stage してください」が設定されることを固定化する。
これは「staged rename+modify の部分 unstage は git が安定しないためガード維持」（spec §2 実験3・§3.1）の回帰保護。
`files` へは `orig_path = "old.txt"` 付きで直接 append する（staged rename エントリを再現）。

- [ ] **Step 1: テストを追記する**

Task 2 で追記したテストの直後へ、以下のテストを追記する:

```zig

test "stage_lines on staged rename entry (orig_path!=null, section=staged) is guarded" {
    // spec 2026-06-17-rename-hunk-stage-design.md §3.4: staged rename 側はガード維持。
    // 2 R.（rename+内容変更が両方 staged）からの部分 unstage は git の apply --cached --reverse が
    // index を破綻させるため（spec §2 実験3）、ファイル単位 unstage を案内するガードを残す。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // staged rename エントリ: path=new.txt, orig_path=old.txt, section=.staged
    try m.files.append(m.allocator, .{
        .path = try m.allocator.dupe(u8, "new.txt"),
        .orig_path = try m.allocator.dupe(u8, "old.txt"),
        .section = .staged,
    });
    try m.setStr(&m.diff_text,
        "diff --git a/old.txt b/new.txt\n" ++
        "similarity index 80%\n" ++
        "rename from old.txt\n" ++
        "rename to new.txt\n" ++
        "index 92dfa21..e1da833 100644\n" ++
        "--- a/old.txt\n" ++
        "+++ b/new.txt\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+X\n" ++
        " c\n");
    m.diff_cursor = 9; // -b の絶対行（file_header 7 行 + @@ 行7, ' a'=8, '-b'=9）
    m.diff_anchor = 9;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none); // ガードでブロック
    try std.testing.expect(m.error_text.len > 0); // ガイドメッセージ
    try std.testing.expect(std.mem.indexOf(u8, m.error_text, "rename") != null);
}
```

- [ ] **Step 2: テストを実行して PASS を確認**

Run: `zig build test --summary all`
Expected: PASS（新テスト `stage_lines on staged rename entry...` 含む全テスト成功）。

- [ ] **Step 3: コミット**

```bash
git add src/update.zig
git commit -m "test(update): pin staged rename partial-unstage guard

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 4: update.zig に `2 .R` unstaged ガード維持テストを追加

**Files:**
- Modify: `src/update.zig`（Task 3 で追記したテストの直後）
- Test: 同ファイル内 `test {}` ブロック

**背景:** `2 .R`（worktree 側 rename・`orig_path != null && section == .unstaged`）上で `stage_lines` を実行したとき、
現行ガードが発火して `.none` を返すことを固定化する。これは「`2 .R`/`2 .C` の部分 stage は未検証のためガード維持」
（spec §1 対象外・§4 リスクA）の回帰保護。当初案の `f.section == .staged` 絞り込みを破棄したことで、
このパスが開放されないことを検証する。

- [ ] **Step 1: テストを追記する**

Task 3 で追記したテストの直後へ、以下のテストを追記する:

```zig

test "stage_lines on 2 .R unstaged entry (orig_path!=null, section=unstaged) is guarded" {
    // spec 2026-06-17-rename-hunk-stage-design.md §3.4・§4 リスクA:
    // 2 .R（worktree rename・orig_path != null）の部分 stage は diff が rename ヘッダを含み
    // 部分パッチ生成が未検証のためガード維持。当初案の section==.staged 絞り込みを破棄したことで
    // このパスが開放されないことを固定化する。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 2 .R の unstaged エントリ: path=new.txt, orig_path=old.txt, section=.unstaged
    try m.files.append(m.allocator, .{
        .path = try m.allocator.dupe(u8, "new.txt"),
        .orig_path = try m.allocator.dupe(u8, "old.txt"),
        .section = .unstaged,
    });
    try m.setStr(&m.diff_text,
        "diff --git a/old.txt b/new.txt\n" ++
        "similarity index 80%\n" ++
        "rename from old.txt\n" ++
        "rename to new.txt\n" ++
        "index 92dfa21..e1da833 100644\n" ++
        "--- a/old.txt\n" ++
        "+++ b/new.txt\n" ++
        "@@ -1,3 +1,3 @@\n" ++
        " a\n" ++
        "-b\n" ++
        "+X\n" ++
        " c\n");
    m.diff_cursor = 9;
    m.diff_anchor = 9;
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none); // ガードでブロック
    try std.testing.expect(m.error_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, m.error_text, "rename") != null);
}
```

- [ ] **Step 2: テストを実行して PASS を確認**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 3: コミット**

```bash
git add src/update.zig
git commit -m "test(update): pin 2 .R unstaged rename guard (rejects untested path)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 5: appcmd.zig に rename+modify 部分 stage の結合テストを追加

**Files:**
- Modify: `src/appcmd.zig`（既存 `apply_patch stages a partial hunk of an untracked file` テストの直後）
- Test: 同ファイル内 `test {}` ブロック

**背景:** 実 git サブプロセスで `git mv old.txt new.txt` + unstaged 内容変更を再現し、
`apply_patch` が部分パッチ（`new.txt` 単体・rename 行無し）を forward 適用して exit 0 で成功し、
porcelain v2 が `2 RM` → `2 R.` へ遷移することを検証する（spec §2 実験2・§3.4）。
`TmpRepo`・`runOwned`・`stagedDiff` は appcmd.zig 既存ヘルパ。

- [ ] **Step 1: テストを追記する**

`src/appcmd.zig` の `test "apply_patch stages a partial hunk of an untracked file (new-file create via --cached)"` の直後へ、以下のテストを追記する:

```zig

test "apply_patch stages a partial hunk of a renamed file (git mv + unstaged modify)" {
    // spec 2026-06-17-rename-hunk-stage-design.md §2 実験2・§3.4 結合テスト。
    // git mv で rename が staged、内容変更が unstaged な 2 RM 状態で、unstaged 側 diff
    // （new.txt 単体・rename ヘッダ無し）の部分パッチを forward 適用 → 2 R. へ遷移する。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "old.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n");
    try repo.git(a, io, &.{ "git", "add", "old.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });
    // rename を staged にし、その後内容を変更（unstaged）→ 2 RM 状態。
    try repo.git(a, io, &.{ "git", "mv", "old.txt", "new.txt" });
    try repo.writeFile(io, "new.txt", "a\nX\nc\nd\ne\nf\ng\nh\ni\nj\n");
    // unstaged 側 diff を取得: orig_path == null で load_diff を呼ぶ（2 RM 展開後の unstaged エントリ相当）。
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{
        .path = try a.dupe(u8, "new.txt"), .orig_path = null, .section = .unstaged,
    } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    // diff は rename ヘッダを含まない content-only 形式（spec §2 実験1 の検証）。
    try std.testing.expect(std.mem.indexOf(u8, dmsg.diff_loaded, "rename from") == null);
    try std.testing.expect(std.mem.indexOf(u8, dmsg.diff_loaded, "--- a/new.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, dmsg.diff_loaded, "+++ b/new.txt") != null);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    // (b->X) 置換を部分 stage する。-b と +X の両方の絶対行を splitScalar で探し、
    // 両方を覆うレンジ [minus_b, plus_X] を選択する（前方 stage で - と + を対で残す必要がある）。
    // ★注意: buildLinePatch(reverse=false) で未選択の + は削除・未選択の - は文脈化される。
    //   よって -b だけを選ぶと「b の削除」だけが stage され +X が落ちる。必ず +X まで含めること。
    var minus_b: usize = 0;
    var plus_X: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) {
            if (std.mem.eql(u8, ln, "-b")) minus_b = i;
            if (std.mem.eql(u8, ln, "+X")) plus_X = i;
        }
    }
    try std.testing.expect(minus_b != 0);
    try std.testing.expect(plus_X != 0);
    try std.testing.expect(minus_b < plus_X); // -b の直後に +X が来る前提
    const maybe = try hunk.buildLinePatch(a, parsed, 0, minus_b, plus_X, false);
    try std.testing.expect(maybe != null);
    // forward 適用: git apply --cached が index の new.txt へ部分パッチを受理する。
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{
        .patch = maybe.?, .reverse = false,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded); // git_error でないこと
    // 遷移後: staged rename + staged 内容変更 = 2 R.（staged エントリのみ、unstaged は無し）。
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "new.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged); // 2 R. の staged 側
    try std.testing.expect(!has_unstaged); // 内容変更は全て staged へ吸収された
    // index に (b->X) のみ入ったことを確認。
    const sd = try stagedDiff(&repo, a, io, "new.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+X\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "-b\n") != null);
}
```

- [ ] **Step 2: テストを実行して PASS を確認**

Run: `zig build test --summary all`
Expected: PASS（新テスト `apply_patch stages a partial hunk of a renamed file...` 含む全テスト成功）。

もし RED になった場合は spec の実証実験（§2 実験2）を見直し、diff 形式・絶対行計算・load_diff の
`orig_path = null` 指定が正しいかを確認する。実装側（`appcmd.zig` 本体・`commands.diffArgv`）の変更は不要なはず。

- [ ] **Step 3: コミット**

```bash
git add src/appcmd.zig
git commit -m "test(appcmd): pin rename+modify partial stage (2 RM -> 2 R.)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 6: TODO.md を更新してタスク完了

**Files:**
- Modify: `TODO.md`（TODO 1 のサブタスク `[ ] rename ファイルのハンク stage` と「留意点」セクション）

- [ ] **Step 1: サブタスクのチェックボックスを `[x]` にする**

`TODO.md` 内の以下の行を変更する:

変更前:
```
- [ ] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）
```

変更後:
```
- [x] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）
```

- [ ] **Step 2: 「留意点」セクションへ実証結果と既知の制約を追記する**

`TODO.md` の TODO 1「留意点」セクション（`- **phase 1 の既知の制約...**` ブロックの末尾）へ、以下を追記する:

```
- **rename + modify の部分 stage（2026-06-17 完了）**:
  - **方式**: `2 RM`（rename staged + 内容変更 unstaged）は `git mv` 時点で rename が index 済みのため、
    unstaged 側 diff は `new.txt` 単体の content-only diff になる。`status.parse` が `2 RM` を展開した
    unstaged エントリは `Y='M'` なので `orig_path == null` になり、`update.stage_lines` の現行ガード
    （`f.orig_path != null`）を通過する。既存の `buildLinePatch`/`buildPatch` が tracked と同形で処理する。
    **コード変更不要**・回帰テスト追加のみで完了（`docs/superpowers/specs/2026-06-17-rename-hunk-stage-design.md`）。
  - **既知の制約1（`2 .R` / `2 .C` worktree rename の部分 stage）**: porcelain `Y='R'/'C'` に対応する
    unstaged エントリは `orig_path != null` でガードブロック。diff が rename ヘッダを含むため未検証。
    将来 spec で実証してから対応。ファイル単位 stage で回避可能。
  - **既知の制約2（staged rename+modify の部分行 unstage）**: `2 R.`（rename + 内容変更が両方 staged）
    からの行/ハンク単位 unstage は、git 自体の `apply --cached --reverse` が index の old 側パス解決で
    破綻するため本ツールでもサポートしない（ガードでファイル単位 unstage を案内）。
    ファイル単位 unstage 後に再 stage で回避すること。
```

- [ ] **Step 3: TODO.md を読み返して整合性を確認**

Run: `Read TODO.md`
Expected:
- TODO 1 の全サブタスクが `[x]` になっている（rename チェックボックス以外は既に `[x]` 済みのはず）。
- 「phase 2 で未対応（さらに将来）」の discontiguous・ドラッグ・Shift クリック項目はそのまま残っている（本タスクの対象外）。
- 留意点に「rename + modify の部分 stage」ブロックが追記され、既知の制約1・2が明記されている。

- [ ] **Step 4: コミット**

```bash
git add TODO.md
git commit -m "docs(todo): mark rename hunk stage as resolved (TODO 1 complete)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 7: 最終検証

**Files:** なし（検証のみ）

- [ ] **Step 1: 全テストを再実行**

Run: `zig build test --summary all`
Expected: PASS（全テスト成功・リーク検出無し・新規5テスト含む）。

- [ ] **Step 2: ビルドが通ることを確認**

Run: `zig build`
Expected: exit 0（エラー無し）。

- [ ] **Step 3: git log でコミット履歴を確認**

Run: `git log --oneline -8`
Expected: Task 1-6 の6コミットが時系列で並ぶ。各コミットメッセージの Conventional Commits 形式
（`test(scope): ...`, `docs(todo): ...`）が一貫している。

- [ ] **Step 4: 変更がソースロジックに触れていないことを確認**

Run: `git diff main~6 main -- src/diff/hunk.zig src/git/commands.zig src/git/status.zig src/messages.zig src/appcmd.zig src/update.zig src/model.zig src/view.zig src/input.zig src/main.zig`
Expected: **差分無し、または `test {}` ブロック内のみ**。
もし `src/*.zig` のロジック（非テストコード）に差分があれば、本計画の前提（コード変更不要）が崩れている。
直ちに戻して該当タスクを見直すこと。
