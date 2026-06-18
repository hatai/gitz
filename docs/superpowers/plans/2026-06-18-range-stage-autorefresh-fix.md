# TODO 1 Blocker Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two 2026-06-18 QA-discovered bugs in TODO 1 partial staging (range-selection destroyed by auto-refresh; selection not following after partial stage).

**Architecture:** Two pure-layer fixes in `update.zig` and `model.zig`. Bug 1 uses a two-layer defense: Layer 1 (file-identity gate in `diff_loaded` arm, via new `model.diff_owner` field + `isDiffOwnerCurrent`) prevents stale anchors when an external process changes the selected file; Layer 2 (`validateAnchor` replacing `clampCursor`'s unconditional clear) keeps anchors across same-file re-renders. Bug 2 extends `replaceFiles` selection restoration with a path-only fallback (priority unstaged>staged>untracked) via `selectByPathPriority`. No UI/input/main wiring changes.

**Tech Stack:** Zig 0.16.0, unmanaged `std.ArrayList`, `std.testing.allocator`. Tests are `test {}` blocks in the same `.zig` file; whole suite runs via `zig build test --summary all` (Debug default; no `--test-filter`).

**Spec:** `docs/superpowers/specs/2026-06-18-range-stage-autorefresh-fix-design.md`
**Conventions:** `CLAUDE.md`, `AGENTS.md` (read before editing).

---

## File Structure

- **Modify** `src/model.zig`: add `DiffOwner` struct, `diff_owner` field, `setDiffOwner`/`clearDiffOwner`, update `init`/`deinit`, add `selectByPathPriority`, extend `replaceFiles` selection restoration. Add tests.
- **Modify** `src/update.zig`: add `isDiffOwnerCurrent` and `validateAnchor` helpers; rewrite `clampCursor` to validate (not unconditionally clear) anchor; update `loadDiffCmd` to record owner; update `diff_loaded` arm with Layer-1 gate; add explicit anchor clear to `select_line_at` arm; rename existing "resets anchor" test; add new tests.
- **Modify** `TODO.md`: mark the two blocker subtasks `[x]` with resolution notes.
- **No new files.** Both helpers are private functions inside existing modules; `root_test.zig` already imports both modules.

## Key References (verify before each task)

- `seedTwoHunkDiff` layout: file_header rows 0-2 / `@@h0`=3 / ` a`=4 / `-b`=5 / `+B`=6 / `@@h1`=7 / ` x`=8 / `+Y`=9 / ` z`=10.
- `addFile` helper in `update.zig`: `fn addFile(m: *Model, path: []const u8, section: status.Section) !void` (appends `.{ .path = dupe, .orig_path = null, .section = section }`).
- `hunk.hunkIndexForLine(parsed, abs) ?usize` (public): returns null for file_header / out-of-range; returns `i` for any row in `[start_line, start_line+line_count)` (includes `@@` header row).
- `isBodyLine` (private in `update.zig`): `abs != parsed.hunks[i].start_line` for the hunk `i` returned by `hunkIndexForLine`. Rejects `@@` headers.
- Build/test: `zig build test --summary all` from repo root.

---

### Task 1: Add `DiffOwner` struct and `diff_owner` field to Model

**Files:**
- Modify: `src/model.zig:1-3` (add `DiffOwner` after imports), `src/model.zig:14` (add field), `src/model.zig:34-50` (update `init`), `src/model.zig:54-67` (update `deinit`)
- Test: `src/model.zig` (new test near existing init/deinit test)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/model.zig` (before the final `test { std.testing.refAllDecls(@This()); }` if present, else after the last test):

```zig
test "Model.diff_owner starts null and survives init/deinit (Layer 1 field)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expectEqual(@as(?DiffOwner, null), m.diff_owner);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL with `no field or member function named 'diff_owner'` (or `DiffOwner` undeclared).

- [ ] **Step 3: Add `DiffOwner` struct**

In `src/model.zig`, after the `status` import (top of file), add:

```zig
/// 最後に load_diff を発行したファイル識別子（層 1: codex B1 対策）。path のみで追跡すると
/// partial stage で `? f` → `1 AM` 展開時の section 変化を取り逃がすため、section も持つ。
/// `orig_path` は含めない（section 変化検出を優先）。
pub const DiffOwner = struct { path: []u8, section: status.Section };
```

- [ ] **Step 4: Add `diff_owner` field to `Model`**

Add inside `pub const Model = struct { ... }`, after the existing `diff_anchor: ?usize,` field:

```zig
    diff_owner: ?DiffOwner, // 最後に load_diff を発行したファイル。null = 未発行（初回）。
```

- [ ] **Step 5: Initialize in `init`**

In `Model.init`, after `.diff_anchor = null,` add:

```zig
            .diff_owner = null,
```

- [ ] **Step 6: Free in `deinit`**

In `Model.deinit`, after `a.free(self.diff_text);` add:

```zig
        if (self.diff_owner) |o| a.free(o.path);
```

- [ ] **Step 7: Run tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS (all existing tests still green; new test passes).

- [ ] **Step 8: Commit**

```bash
git add src/model.zig
git commit -m "feat(model): add diff_owner field for Layer 1 file-identity gate"
```

---

### Task 2: Add `setDiffOwner` / `clearDiffOwner` helpers

**Files:**
- Modify: `src/model.zig` (add methods after `setStr`, around line 105)
- Test: `src/model.zig` (new test)

- [ ] **Step 1: Write the failing test**

Add in `src/model.zig`:

```zig
test "setDiffOwner replaces and clearDiffOwner frees (Layer 1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setDiffOwner("f.txt", .unstaged);
    try std.testing.expectEqualStrings("f.txt", m.diff_owner.?.path);
    try std.testing.expectEqual(status.Section.unstaged, m.diff_owner.?.section);
    // 上書き（旧を free して新へ）
    try m.setDiffOwner("g.txt", .staged);
    try std.testing.expectEqualStrings("g.txt", m.diff_owner.?.path);
    try std.testing.expectEqual(status.Section.staged, m.diff_owner.?.section);
    // クリア
    m.clearDiffOwner();
    try std.testing.expectEqual(@as(?DiffOwner, null), m.diff_owner);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL with `no member function named 'setDiffOwner'`.

- [ ] **Step 3: Add helpers**

In `src/model.zig`, after the `setStr` method (around line 105), add:

```zig
    /// diff_owner を置換する（旧を free して dup）。loadDiffCmd が呼ぶ（層 1）。
    pub fn setDiffOwner(self: *Model, path: []const u8, section: status.Section) !void {
        const a = self.allocator;
        const new_path = try a.dupe(u8, path);
        if (self.diff_owner) |old| a.free(old.path);
        self.diff_owner = .{ .path = new_path, .section = section };
    }

    /// diff_owner をクリアする（ファイル一覧が空になった等）。純粋。
    pub fn clearDiffOwner(self: *Model) void {
        const a = self.allocator;
        if (self.diff_owner) |old| a.free(old.path);
        self.diff_owner = null;
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/model.zig
git commit -m "feat(model): add setDiffOwner/clearDiffOwner helpers"
```

---

### Task 3: Wire `setDiffOwner`/`clearDiffOwner` into `loadDiffCmd`

**Files:**
- Modify: `src/update.zig:282-295` (`loadDiffCmd` body)
- Test: `src/update.zig` (new test)

- [ ] **Step 1: Write the failing test**

Add in `src/update.zig`:

```zig
test "loadDiffCmd records diff_owner for selected file (Layer 1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    var cmd = try update(&m, .key_down); // key_down は loadDiffCmd を発行するが selected は動かない(1件)
    cmd.deinit(a);
    // key_down で loadDiffCmd が走り、diff_owner が selected ファイルへ記録される
    try std.testing.expect(m.diff_owner != null);
    try std.testing.expectEqualStrings("f.txt", m.diff_owner.?.path);
    try std.testing.expectEqual(status.Section.unstaged, m.diff_owner.?.section);
}

test "loadDiffCmd clears diff_owner when files empty (Layer 1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 手動で diff_owner を設定（ファイル無しの状態）
    try m.setDiffOwner("stale.txt", .unstaged);
    // status_loaded で空エントリ → replaceFiles で files 空 → loadDiffCmd で diff_owner クリア
    var cmd = try update(&m, .{ .status_loaded = &.{} });
    cmd.deinit(a);
    try std.testing.expectEqual(@as(?model_mod.DiffOwner, null), m.diff_owner);
}
```

Note: `model_mod` is already imported at top of `update.zig` as `const model_mod = @import("model.zig");` — verify this. If not, add it.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL (diff_owner stays null because loadDiffCmd doesn't set it yet).

- [ ] **Step 3: Update `loadDiffCmd`**

In `src/update.zig`, replace the `loadDiffCmd` function body:

```zig
fn loadDiffCmd(model: *Model) !AppCmd {
    if (model.files.items.len == 0) {
        try model.setStr(&model.diff_text, "");
        model.clearDiffOwner(); // ファイル無し → diff_owner も無し（層 1）
        return .none;
    }
    const f = model.files.items[model.selected];
    try model.setDiffOwner(f.path, f.section); // ★層 1: 発行時にオーナーを記録
    return .{ .load_diff = .{
        .path = try model.allocator.dupe(u8, f.path),
        .orig_path = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null,
        .section = f.section,
    } };
}
```

- [ ] **Step 4: Ensure `model_mod` is imported at top of `update.zig`**

Check the top of `src/update.zig`. If `const model_mod = @import("model.zig");` is absent, add it after `const Model = @import("model.zig").Model;`. If the test uses `model_mod.DiffOwner`, this import is needed. (Currently `update.zig` only has `const Model = ...Model;` and `const Focus = ...Focus;`. Add the module import.)

Actually, to avoid changing imports, change the test assertion to use the struct field directly without naming the type:

```zig
    try std.testing.expectEqual(@as(@TypeOf(m.diff_owner), null), m.diff_owner);
```

Or simpler — just check nullity without type:

```zig
    try std.testing.expect(m.diff_owner == null);
```

Use the simpler form in the test to avoid import churn.

- [ ] **Step 5: Run tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/update.zig
git commit -m "feat(update): loadDiffCmd records diff_owner (Layer 1)"
```

---

### Task 4: Add `isDiffOwnerCurrent` helper and Layer-1 gate in `diff_loaded`

**Files:**
- Modify: `src/update.zig:197-201` (`diff_loaded` arm), add `isDiffOwnerCurrent` helper near `clampCursor`
- Test: `src/update.zig` (new tests)

- [ ] **Step 1: Write the failing tests**

Add in `src/update.zig`:

```zig
test "isDiffOwnerCurrent: null owner returns false (first load)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    // diff_owner 未設定
    try std.testing.expect(!isDiffOwnerCurrent(&m));
}

test "isDiffOwnerCurrent: matching section+path returns true" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try m.setDiffOwner("f.txt", .unstaged);
    try std.testing.expect(isDiffOwnerCurrent(&m));
}

test "isDiffOwnerCurrent: section change (partial stage) returns false" {
    // ? f → 1 AM で section が untracked → staged+unstaged へ。owner が古い section なら false。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .staged); // 部分 stage 後の staged エントリ
    try m.setDiffOwner("f.txt", .untracked); // 発行時は untracked だった
    try std.testing.expect(!isDiffOwnerCurrent(&m));
}

test "isDiffOwnerCurrent: path change returns false" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "g.txt", .unstaged);
    try m.setDiffOwner("f.txt", .unstaged); // 別ファイル
    try std.testing.expect(!isDiffOwnerCurrent(&m));
}

test "Bug 1 Layer 1: diff_loaded clears anchor when selected file changed (codex B1)" {
    // f.txt 選択中に anchor=5 → 外部プロセスで f.txt が commit され g.txt へ切替 →
    // loadDiffCmd が diff_owner=g.txt へ更新 → g.txt の diff_loaded が届く。
    // このとき層 1 は isDiffOwnerCurrent=true（loadDiffCmd が既に owner を更新済み）なので
    // 層 2 が効く。g.txt の diff が異なれば validateAnchor が anchor を消す。
    // ここでは「loadDiffCmd を呼ぶ前に selected が変わった」レースを直接シミュレート:
    // owner=f.txt のまま selected が g.txt に変わった状態で diff_loaded を送る。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try addFile(&m, "g.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    m.diff_anchor = 5;
    // owner を f.txt のまま記録（loadDiffCmd 相当）
    try m.setDiffOwner("f.txt", .unstaged);
    // selected を g.txt(1) へ（外部プロセスで f.txt が消えた等）。owner は更新しない。
    m.selected = 1;
    // g.txt の diff_loaded が届いたとする（テストでは同じ diff_text を再利用）
    const diff_copy = try a.dupe(u8, m.diff_text);
    defer a.free(diff_copy);
    var cmd = try update(&m, .{ .diff_loaded = diff_copy });
    cmd.deinit(a);
    // ★層 1: owner(f.txt) != selected(g.txt) → anchor clear
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor);
}
```

- [ ] **Step 2: Run tests to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL with `no function named 'isDiffOwnerCurrent'` and the B1 test fails (anchor survives because no gate).

- [ ] **Step 3: Add `isDiffOwnerCurrent` helper**

In `src/update.zig`, add near `clampCursor` (before or after it):

```zig
/// model.diff_owner（最後に load_diff を発行したファイル）が現在の selected ファイルと一致するか。
/// 一致しない（ファイル切替・外部プロセスで selected が別へクランプ・初回ロード前）は false。
/// 純粋・allocator 不要。層 1（codex B1 対策）。
fn isDiffOwnerCurrent(model: *const Model) bool {
    const owner = model.diff_owner orelse return false;
    if (model.files.items.len == 0) return false;
    if (model.selected >= model.files.items.len) return false;
    const f = model.files.items[model.selected];
    return f.section == owner.section and std.mem.eql(u8, f.path, owner.path);
}
```

- [ ] **Step 4: Add Layer-1 gate to `diff_loaded` arm**

In `src/update.zig`, replace the `.diff_loaded` arm:

```zig
        .diff_loaded => |text| {
            model.busy = false;
            try model.setStr(&model.diff_text, text);
            // ★層 1: ファイル同一性ゲート（codex B1）。clampCursor は diff_text しか見えず
            //   「どのファイルの diff か」を知らないため、ここで selected ファイルが
            //   load_diff 発行時と同じか検証する。不一致なら stale anchor を消す。
            if (!isDiffOwnerCurrent(model)) {
                model.diff_anchor = null;
            }
            try clampCursor(model); // 層 2: validateAnchor
            return .none;
        },
```

- [ ] **Step 5: Run tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/update.zig
git commit -m "feat(update): Layer 1 file-identity gate in diff_loaded (codex B1)"
```

---

### Task 5: Rewrite `clampCursor` to validate anchor (Layer 2: `validateAnchor`)

**Files:**
- Modify: `src/update.zig:226-239` (`clampCursor` body), add `validateAnchor` helper
- Test: `src/update.zig` (new tests)

- [ ] **Step 1: Write the failing tests**

Add in `src/update.zig`:

```zig
test "validateAnchor: null anchor stays null" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4-6, h1 body 8-10
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, null));
}

test "validateAnchor: anchor on @@ header is cleared (cond-a fail)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // @@h0 = 行3
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, 3));
}

test "validateAnchor: anchor on file_header is cleared (cond-a fail)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // file_header = 行0-2
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, 1));
}

test "validateAnchor: anchor on different hunk from cursor is cleared (cond-b fail)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4-6, h1 body 8-10
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    // cursor=h0(行5), anchor=h1(行9) → 異ハンク → null
    try std.testing.expectEqual(@as(?usize, null), validateAnchor(parsed, 5, 9));
}

test "validateAnchor: anchor on body line in same hunk as cursor is kept (both pass)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m); // h0 body 4-6
    var parsed = try hunk.parse(a, m.diff_text);
    defer parsed.deinit(a);
    // cursor=行5, anchor=行6 → 同 h0 本文 → 保持
    try std.testing.expectEqual(@as(?usize, 6), validateAnchor(parsed, 5, 6));
    // cursor=行6, anchor=行5 → 同 h0 本文 → 保持
    try std.testing.expectEqual(@as(?usize, 5), validateAnchor(parsed, 6, 5));
}
```

- [ ] **Step 2: Run tests to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL with `no function named 'validateAnchor'`.

- [ ] **Step 3: Add `validateAnchor` helper**

In `src/update.zig`, add after `clampCursor` (or before it):

```zig
/// anchor が「(a) 本文行」「(b) cursor と同じハンク」を両方満たすかを検証し、満たすならそのまま
/// 返し、満たさない（または anchor==null）なら null を返す。純粋・allocator 不要。層 2。
///
/// cond-a の 2 段チェックは非冗長: `isBodyLine` は @@ ヘッダ行（start_line に等しい行）を拒否するが、
/// `hunkIndexForLine` は @@ ヘッダ行に対して non-null（[start_line, start_line+line_count) に含まれる）
/// を返す。よって isBodyLine=true を通過した anchor は必ずハンク内本文行であり、後続の
/// hunkIndexForLine は non-null になることが保証される。2 つめの orelse return null は到達不能だが、
/// isBodyLine と hunkIndexForLine の契約が独立しているため防御的に残す（subagent N1 訂正）。
fn validateAnchor(parsed: hunk.ParsedDiff, cursor: usize, anchor: ?usize) ?usize {
    const a = anchor orelse return null;
    if (!isBodyLine(parsed, a)) return null; // (a) 本文行でない（@@ ヘッダ/file_header/範囲外）
    const a_hunk = hunk.hunkIndexForLine(parsed, a) orelse return null; // isBodyLine=true なら必ず non-null（到達不能ガード）
    const c_hunk = hunk.hunkIndexForLine(parsed, cursor) orelse return null; // cursor が本文でない（clampCursor で本文へ正規化済みだが念のため）
    if (a_hunk != c_hunk) return null; // (b) 異ハンク
    return a;
}
```

- [ ] **Step 4: Run validateAnchor unit tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS (validateAnchor tests pass; clampCursor still unconditionally clears but those tests don't exercise it).

- [ ] **Step 5: Rewrite `clampCursor` body**

In `src/update.zig`, replace the `clampCursor` function:

```zig
/// diff 再読込/カーソル移動後にカーソルを本文行へ正規化し、anchor を**検証**する（純粋）。
/// - ハンク 0 個: cursor=0, anchor=null。
/// - カーソルが本文行でない（file_header / @@ ヘッダ行 / 範囲外）: 先頭ハンク本文先頭へ。
/// - 既にいずれかのハンク本文内: そのまま維持（リフレッシュ時のジャンプ防止）。
/// anchor は「(a) 本文行、(b) cursor と同じハンク」を両方満たすときだけ保持。それ以外は null。
/// ★層 2（Bug 1 修正）: 無条件 clear すると v → j → s の間に auto-refresh が走っただけで
///   選択が消える（TODO 1 ブロッカー）。ユーザー能動的なファイル切替（key_down/up/select_index/
///   diff_hunk_next/prev）は各 arm が明示的に anchor を clear するため、ここでの clear は
///   それら経路では冗長だった。層 1（isDiffOwnerCurrent）でファイル同一性を確認した上で呼ばれる。
fn clampCursor(model: *Model) !void {
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    if (parsed.hunks.len == 0) {
        model.diff_cursor = 0;
        model.diff_anchor = null; // ハンク無しでは選択は無意味
        return;
    }
    // カーソルが本文行でない（@@ ヘッダ/file_header/範囲外）なら先頭ハンク本文先頭へ再配置。
    // 本文内ならジャンプ防止で維持。
    if (!isBodyLine(parsed, model.diff_cursor)) {
        model.diff_cursor = hunkBodyTop(parsed.hunks[0]);
    }
    // 層 2: anchor 検証。cursor 再配置後に検証するので、新しい cursor ハンクと anchor ハンクが
    // 一致すれば保持（ユーザが v で作った選択を cursor ズレだけで消さない）。
    model.diff_anchor = validateAnchor(parsed, model.diff_cursor, model.diff_anchor);
}
```

- [ ] **Step 6: Run full suite to check for regressions**

Run: `zig build test --summary all`
Expected: Most tests PASS. The existing test "diff_loaded clamps cursor into a hunk body and resets anchor" may need its name updated (Task 6). If it fails, proceed to Task 6 to fix it.

- [ ] **Step 7: Commit**

```bash
git add src/update.zig
git commit -m "feat(update): Layer 2 validateAnchor replaces unconditional clear in clampCursor"
```

---

### Task 6: Add explicit anchor clear to `select_line_at` arm + update existing test name

**Files:**
- Modify: `src/update.zig:155-159` (`select_line_at` arm)
- Modify: `src/update.zig` existing test "diff_loaded clamps cursor into a hunk body and resets anchor" (rename only, assertions unchanged)

- [ ] **Step 1: Write the failing regression test**

Add in `src/update.zig`:

```zig
test "select_line_at still clears anchor after Bug 1 fix (regression)" {
    // マウスクリックは明示的選択解除。clampCursor が anchor を保持するようになっても
    // select_line_at 単独で anchor を clear する（Bug 1 層 2 修正後の回帰保護）。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try seedTwoHunkDiff(&m);
    m.diff_anchor = 4; // 選択あり
    var cmd = try update(&m, .{ .select_line_at = 9 }); // h1 '+Y' へクリック
    cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 9), m.diff_cursor);
    try std.testing.expect(m.focus == .diff);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // ★明示的 clear
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test --summary all`
Expected: FAIL (select_line_at no longer clears anchor because clampCursor no longer does unconditionally; the regression test catches this).

- [ ] **Step 3: Add explicit clear to `select_line_at` arm**

In `src/update.zig`, replace the `.select_line_at` arm:

```zig
        .select_line_at => |line| {
            model.focus = .diff;
            model.diff_cursor = line;
            // ★マウスクリックは「明示的な選択解除」のセマンティクス。clampCursor が anchor を
            //   保持するようになった（Bug 1 層 2 修正）ため、ここで明示的に clear しないと
            //   クリックで選択が残る。ユーザー能動操作経路はここだけ clampCursor 経由で anchor を
            //   clear する必要がある（key_down/up/select_index/diff_hunk_next/prev は arm 内で
            //   直接 clear するため非依存）。
            model.diff_anchor = null;
            try clampCursor(model); // 本文外クリックはハンク本文へクランプ
            return .none;
        },
```

- [ ] **Step 4: Update existing test name (assertions unchanged)**

In `src/update.zig`, rename the existing test (currently at the end of the file):

From:
```zig
test "diff_loaded clamps cursor into a hunk body and resets anchor" {
```

To:
```zig
test "diff_loaded clamps cursor into a hunk body and validates anchor" {
```

And update the setup comment inside to make the cond-a intent explicit. Find the line `m.diff_anchor = 3;` and add a comment:

```zig
    m.diff_anchor = 3; // @@ ヘッダ行 (start_line==3) → isBodyLine=false → cond-a fail → null 化
```

Assertions (`m.diff_cursor == 4`, `m.diff_anchor == null`) stay unchanged.

- [ ] **Step 5: Run full suite to verify pass**

Run: `zig build test --summary all`
Expected: PASS (all tests green, including the renamed test and the new regression test).

- [ ] **Step 6: Commit**

```bash
git add src/update.zig
git commit -m "feat(update): explicit anchor clear in select_line_at (regression guard)"
```

---

### Task 7: End-to-end Bug 1 reproduction test (Layer 1 + Layer 2 full path)

**Files:**
- Modify: `src/update.zig` (add one comprehensive test)

- [ ] **Step 1: Write the test**

Add in `src/update.zig`:

```zig
test "Bug 1 e2e: range selection survives diff_loaded (auto-refresh simulation)" {
    // v → j → (auto-refresh が diff_loaded を発火) → s で範囲 stage されること。
    // ★層 1（diff_owner 一致）+ 層 2（validateAnchor 通過）の両方を検証。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6 (' a'/-b/+B)

    // 層 1 セットアップ: diff_owner を "f.txt"/.unstaged へ設定。
    // 実機では loadDiffCmd（status_loaded → load_diff）がこれを行う。テストでは直接 setup。
    try m.setDiffOwner("f.txt", .unstaged);

    // 1) v で選択開始 (cursor=5 → anchor=5)
    m.diff_cursor = 5;
    var c1 = try update(&m, .toggle_line_selection);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor);

    // 2) j で選択拡張 (cursor=5 → 6)
    var c2 = try update(&m, .diff_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor); // 選択維持

    // 3) auto-refresh シミュレーション: 同じ diff_text で diff_loaded を再送
    //    （main.zig の maybeAutoRefresh → status_loaded → load_diff → diff_loaded と同効果）
    //    ★層 1: diff_owner("f.txt"/.unstaged) == selected ファイル → 一致 → anchor 保持へ進む
    //    ★層 2: validateAnchor が anchor=5(h0 本文) と cursor=6(同 h0) を確認 → 保持
    const same_diff = try a.dupe(u8, m.diff_text);
    defer a.free(same_diff);
    var c3 = try update(&m, .{ .diff_loaded = same_diff });
    c3.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor); // ★Bug 1 の核心: 保持される
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);

    // 4) s で stage → 選択範囲 [5,6] がパッチへ含まれること（単一行ではなく 2 行分）
    //    ★Bug 1 無修正なら anchor が diff_loaded で null 化し、selectionRange(6,null)={6,6}
    //      なので '-b' は未選択→文脈化(' b')されてパッチから消え、'+B' のみ残る。
    //      修正後は anchor=5 保持で selectionRange(6,5)={5,6} となり、'-b' も選択→保持される。
    var c4 = try update(&m, .stage_lines);
    defer c4.deinit(a);
    try std.testing.expect(c4 == .apply_patch);
    try std.testing.expect(std.mem.indexOf(u8, c4.apply_patch.patch, "+B\n") != null); // 選択された追加行
    try std.testing.expect(std.mem.indexOf(u8, c4.apply_patch.patch, "-b\n") != null); // 選択された削除行（文脈化されず保持）
}
```

- [ ] **Step 2: Run test to verify pass**

Run: `zig build test --summary all`
Expected: PASS. This is the acceptance test for Bug 1; if it fails, the fix is incomplete.

- [ ] **Step 3: Commit**

```bash
git add src/update.zig
git commit -m "test(update): Bug 1 e2e range-selection survives auto-refresh"
```

---

### Task 8: Add `selectByPathPriority` helper to Model (Bug 2)

**Files:**
- Modify: `src/model.zig` (add private helper near `sectionRank`, around line 130)
- Test: `src/model.zig` (new tests)

- [ ] **Step 1: Write the failing tests**

Add in `src/model.zig`:

```zig
test "selectByPathPriority prefers unstaged over staged and untracked" {
    const items = [_]FileItem{
        .{ .path = @constCast(@as(*const [4:0]u8, undefined)[0..0]), .orig_path = null, .section = .staged }, // dummy; will be overwritten
    };
    // ダミーを使わず直接構築するため、allocator で確保せずリテラル slice を使う
    const path_f = "f.txt";
    const test_items = [_]FileItem{
        .{ .path = @constCast(path_f), .orig_path = null, .section = .staged },
        .{ .path = @constCast(path_f), .orig_path = null, .section = .unstaged },
        .{ .path = @constCast(path_f), .orig_path = null, .section = .untracked },
    };
    // unstaged が index 1 にある → それを返す
    try std.testing.expectEqual(@as(usize, 1), selectByPathPriority(&test_items, "f.txt"));
}
```

Note: `FileItem.path` is `[]u8` (mutable). The helper takes `[]const FileItem` and compares with `std.mem.eql(u8, ...)` which accepts `[]const u8`. For the test, we need `[]u8` values. Use a small allocator-based setup or use `@constCast`. Simpler: use the testing allocator and dupe.

Replace the test with a cleaner version:

```zig
test "selectByPathPriority prefers unstaged over staged and untracked" {
    const a = std.testing.allocator;
    const path_f = try a.dupe(u8, "f.txt");
    defer a.free(path_f);
    const items = [_]FileItem{
        .{ .path = path_f, .orig_path = null, .section = .staged },
        .{ .path = path_f, .orig_path = null, .section = .unstaged },
        .{ .path = path_f, .orig_path = null, .section = .untracked },
    };
    try std.testing.expectEqual(@as(usize, 1), selectByPathPriority(&items, "f.txt"));
}

test "selectByPathPriority falls back to staged when no unstaged match" {
    const a = std.testing.allocator;
    const path_f = try a.dupe(u8, "f.txt");
    defer a.free(path_f);
    const path_g = try a.dupe(u8, "g.txt");
    defer a.free(path_g);
    const items = [_]FileItem{
        .{ .path = path_g, .orig_path = null, .section = .unstaged },
        .{ .path = path_f, .orig_path = null, .section = .staged },
        .{ .path = path_f, .orig_path = null, .section = .untracked },
    };
    try std.testing.expectEqual(@as(usize, 1), selectByPathPriority(&items, "f.txt")); // staged 優先
}

test "selectByPathPriority falls back to untracked when only untracked matches" {
    const a = std.testing.allocator;
    const path_f = try a.dupe(u8, "f.txt");
    defer a.free(path_f);
    const items = [_]FileItem{
        .{ .path = path_f, .orig_path = null, .section = .untracked },
    };
    try std.testing.expectEqual(@as(usize, 0), selectByPathPriority(&items, "f.txt"));
}

test "selectByPathPriority defensive fallback returns 0 on no match" {
    const a = std.testing.allocator;
    const path_g = try a.dupe(u8, "g.txt");
    defer a.free(path_g);
    const items = [_]FileItem{
        .{ .path = path_g, .orig_path = null, .section = .unstaged },
    };
    // "f.txt" は無いが契約違反呼出 → index 0 へ退化（クラッシュしない）
    try std.testing.expectEqual(@as(usize, 0), selectByPathPriority(&items, "f.txt"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL with `no function named 'selectByPathPriority'`.

- [ ] **Step 3: Add `selectByPathPriority` helper**

In `src/model.zig`, add after `lessThanForDisplay` (around line 155, as a private file-level function like `sectionRank`):

```zig
/// path のみが一致するエントリのうち、優先順位（unstaged > staged > untracked）で最も高いものの
/// index を返す。純粋・allocator 不要。Bug 2（部分 stage 後の選択追従）で replaceFiles が呼ぶ。
///
/// 呼び出し側は `found_path_only != null`（path に一致するエントリが少なくとも1つ存在）を保証して
/// 呼ぶため、本関数は常にヒットする。末尾の `return 0` は防御的フォールバックで、契約違反の呼出し
/// （path 一致エントリが無いのに呼んだ）時に index 0 へ退化して安全性を保つ。`unreachable` には
/// しない（一部のエッジで契約が崩れたときの安全側 / codex N3）。
///
/// 優先順位は sectionRank（staged=0 < unstaged=1 < untracked=2）とは**逆**（unstaged が先頭）。
/// sectionRank は表示順（staged が先頭）用で、選択追従の優先順位とは別物。混同しないよう個別定義。
fn selectByPathPriority(items: []const FileItem, path: []const u8) usize {
    const priorities = [_]Section{ .unstaged, .staged, .untracked };
    for (priorities) |sec| {
        for (items, 0..) |f, i| {
            if (f.section == sec and std.mem.eql(u8, f.path, path)) return i;
        }
    }
    // 防御的フォールバック（契約違反時）: index 0 へ退化。
    return 0;
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/model.zig
git commit -m "feat(model): add selectByPathPriority helper (Bug 2)"
```

---

### Task 9: Extend `replaceFiles` selection restoration with path-only fallback (Bug 2)

**Files:**
- Modify: `src/model.zig:117-131` (selection restoration block inside `replaceFiles`)
- Test: `src/model.zig` (new Bug 2 reproduction test)

- [ ] **Step 1: Write the failing test**

Add in `src/model.zig`:

```zig
test "Bug 2: partial stage of untracked follows selection to unstaged entry" {
    // untracked.txt 選択中 → 部分 stage で ? → 1 AM 展開。.unstaged 側へ追従すること。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();

    // 初回: untracked.txt のみ
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    try std.testing.expectEqualStrings("untracked.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.untracked, m.files.items[m.selected].section);

    // 部分 stage 後: 1 AM 展開で staged + unstaged の 2 エントリ + 別の untracked が残ったとする
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .staged },
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "other.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    // ★Bug 2 の核心: 同 path の .unstaged 側へ追従
    // 表示順ソート後: staged(untracked.txt) / unstaged(untracked.txt) / untracked(other.txt)
    //   → staged が先頭。完全一致 (untracked, "untracked.txt") は無し（section 変わった）。
    //   path-only フォールバック: unstaged 優先 → index 1。
    try std.testing.expectEqualStrings("untracked.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.unstaged, m.files.items[m.selected].section);
}

test "Bug 2: full stage of untracked follows selection to staged entry" {
    // untracked 完全 stage → unstaged 側は消え staged のみ残る → staged へ追従
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);

    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .staged },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    try std.testing.expectEqualStrings("f.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.staged, m.files.items[m.selected].section);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test --summary all`
Expected: FAIL (partial-stage test: selection lands on staged index 0 or wrong entry because no path-only fallback; full-stage test may pass coincidentally if index 0 is selected, verify).

- [ ] **Step 3: Extend `replaceFiles` selection restoration**

In `src/model.zig`, find the selection restoration block inside `replaceFiles` (around line 117-131):

```zig
        // 選択を (section, path) で復元（旧 files 解放前に照合）。見つからなければ index クランプにフォールバック。
        var new_selected: usize = self.selected;
        if (prev) |p| {
            for (next.items, 0..) |f, i| {
                if (f.section == p.section and std.mem.eql(u8, f.path, p.path)) {
                    new_selected = i;
                    break;
                }
            }
        }
```

Replace it with:

```zig
        // 選択を復元。2 段階: (1) (section, path) 完全一致、(2) path のみでフォールバック（unstaged>staged>untracked優先）。
        // 第 2 段階は部分 stage で section が変わったケース（? untracked.txt → 1 AM で
        // .untracked → .staged+.unstaged）へ選択を追従させる（Bug 2）。unstaged 優先は
        // 「まだ作業が残っている」側へ誘導し連続 stage を継続しやすくする。
        var new_selected: usize = self.selected;
        if (prev) |p| {
            var found_exact: ?usize = null;
            var found_path_only: ?usize = null;
            for (next.items, 0..) |f, i| {
                if (found_exact == null and f.section == p.section and std.mem.eql(u8, f.path, p.path)) {
                    found_exact = i;
                }
                if (found_path_only == null and std.mem.eql(u8, f.path, p.path)) {
                    found_path_only = i;
                }
            }
            if (found_exact) |i| {
                new_selected = i;
            } else if (found_path_only != null) {
                // 完全一致無し。path のみで一致するエントリから優先順位（unstaged>staged>untracked）で選ぶ。
                new_selected = selectByPathPriority(next.items, p.path);
            }
            // どちらも見つからなければ new_selected は self.selected のまま（下で index クランプ）。
        }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `zig build test --summary all`
Expected: PASS (new Bug 2 tests pass; existing `replaceFiles` tests unchanged and green).

- [ ] **Step 5: Commit**

```bash
git add src/model.zig
git commit -m "feat(model): replaceFiles path-only fallback (Bug 2 selection follow)"
```

---

### Task 10: Update `TODO.md` and final verification

**Files:**
- Modify: `TODO.md` (mark two blocker subtasks `[x]`)

- [ ] **Step 1: Update TODO.md**

In `TODO.md`, find the two blocker subtasks under TODO 1:

```
- [ ] **★範囲 stage が auto-refresh で破壊されるバグの修正（2026-06-18 QA で発見・ブロッカー）**
```

Change to:

```
- [x] **★範囲 stage が auto-refresh で破壊されるバグの修正（2026-06-18 QA で発見・ブロッカー）**
  - **解消**: 2 層構成。(1) `diff_loaded` arm にファイル同一性ゲート（`isDiffOwnerCurrent` + `model.diff_owner`）を追加し、外部プロセスで selected が別ファイルへ切り替わった後の stale anchor を防止（codex B1）。(2) `clampCursor` の無条件 anchor clear を `validateAnchor`（本文行 AND cursor と同ハンク）へ置換。
```

Find:

```
- [ ] **★部分 stage 後の選択ファイル追従バグの修正（2026-06-18 QA で発見・UX ノイズ）**
```

Change to:

```
- [x] **★部分 stage 後の選択ファイル追従バグの修正（2026-06-18 QA で発見・UX ノイズ）**
  - **解消**: `replaceFiles` の選択復元に path-only フォールバック（unstaged 優先）を追加（`selectByPathPriority` 新設）。
```

Also update the "未解決バグ" note at the bottom of TODO 1's 留意点 section. Find:

```
- **★未解決バグ（2026-06-18 QA で発見）**: Sub Tasks の「範囲 stage が auto-refresh で破壊されるバグの修正」
  および「部分 stage 後の選択ファイル追従バグの修正」を参照。前者は TODO 1 完了のブロッカー。
```

Replace with:

```
- **★解消済みバグ（2026-06-18 QA で発見・同日解消）**: Sub Tasks の「範囲 stage が auto-refresh で破壊されるバグの修正」
  および「部分 stage 後の選択ファイル追従バグの修正」を参照。両者とも 2 層構成（層 1: ファイル同一性ゲート、層 2: validateAnchor）+
  path-only フォールバックで解消。
```

- [ ] **Step 2: Run full test suite**

Run: `zig build test --summary all`
Expected: PASS — all tests green, no leaks.

- [ ] **Step 3: Build the binary (smoke check)**

Run: `zig build`
Expected: Success (no compile errors).

- [ ] **Step 4: Commit**

```bash
git add TODO.md
git commit -m "docs(todo): mark 2026-06-18 QA blockers resolved (TODO 1 complete)"
```

---

## Self-Review Checklist (completed by plan author)

**Spec coverage:**
- §2.0 (DiffOwner field): Task 1 ✓
- §2.0b (setDiffOwner/clearDiffOwner): Task 2 ✓
- §2.1 (loadDiffCmd records owner): Task 3 ✓
- §2.2 (diff_loaded Layer 1 gate + isDiffOwnerCurrent): Task 4 ✓
- §2.3 (clampCursor Layer 2 + validateAnchor): Task 5 ✓
- §2.4 (select_line_at explicit clear): Task 6 ✓
- Bug 1 reproduction test: Task 7 ✓
- §3.1 (replaceFiles path-only fallback): Task 9 ✓
- §3.2 (selectByPathPriority): Task 8 ✓
- TODO.md update: Task 10 ✓

**Placeholder scan:** No "TBD", "TODO", "add error handling", or codeless steps. All code blocks contain real Zig.

**Type consistency:** `DiffOwner`, `setDiffOwner`, `clearDiffOwner`, `isDiffOwnerCurrent`, `validateAnchor`, `selectByPathPriority` — signatures match across tasks.

**Ordering:** Layer 1 (Tasks 1-4) before Layer 2 (Tasks 5-7) so `validateAnchor` tests can rely on `diff_owner` being settable. Bug 2 (Tasks 8-9) is independent. TODO.md update last (Task 10).
