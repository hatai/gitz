# TODO 2 phase 3b #1 ブランチフィルタ 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ブランチ/revspec フィルタを log view へ追加し、phase 3b を完遂する（TODO.md:195）。

**Architecture:** branch 条件を argv の付加オプションではなく **revision（snapshot_tip）の選択**として扱う。`git rev-parse --verify --end-of-options <rev>^{commit}` で branch を単一 commit hash へ解決し、それ自体を snapshot_tip とする。これにより phase3b #2 の substrate/投影/paging tip 照合が**全て不変**で動き、B3 和集合問題を回避する。logArgv は branch を無視（revision 側で消費済み）。

**Tech Stack:** Zig 0.16.0 + zigzag v0.1.5（固定・昇格しない）。テストは実装 `.zig` 内 `test {}`・`std.testing.allocator` 必須。

**Spec:** `docs/superpowers/specs/2026-06-29-todo2-log-view-phase3b-branch-filter-design.md`（rev.1・codex レビュー MAJOR1/MINOR1/advisory2 全面反映）。各 Task の実装詳細（構造体 field・reducer ステップ・argv 形・テスト計画）は **spec の該当節** を正として参照すること。

**Plan review:** codex 独立レビュー（read-only・実コード検証）結果: **Issues Found → BLOCKER 3 / MAJOR 3 / MINOR 1**。全反映（rev.1）:

| 指摘 | 重要度 | Task | 内容 → 対応 |
|---|---|---|---|
| B1 | BLOCKER | 8 | `syncFocus`/`focusTextInput` の `switch` が u3(0-7) 非網羅 → コンパイルエラー → `else => unreachable` 追加（invariant: focus は常に 0..4） |
| B2 | BLOCKER | 8 | `g_app = .{...}` リテラル 2 箇所（main.zig:687 runtime init・:763 makeTestApp）が field 追加で壊れる → 両方へ `.filter_branch_input` 追加（Step 7b 新設） |
| B3 | BLOCKER | 6 | blob テストで `defer a.free(blob)` + addCondition 所有権移譲 → double free → defer 削除・dupe を addCondition へ直接移譲 |
| M1 | MAJOR | 6 | compose テストが全コミット同 author で compose 未実証 → c1 を異 author で作成し期待 1 件へ（`git -c user.name=other commit`） |
| M2 | MAJOR | 6 | spec §8.3 の annotated tag テスト抜け → `^{commit}` peel の実 git 検証テスト追加 |
| M3 | MAJOR | 8 | tmux 検証が `dev` branch の存在を前提 → 再現可能な repo セットアップ付きへ全面書き換え |
| m1 | MINOR | 1 | spec §8.1 の branch OOM テスト抜け → `addConditionBranchOomHelper` + `checkAllAllocationFailures` 追加 |

## Global Constraints

- `zig build test --summary all`（**Debug 既定維持**・実行時安全チェックを保つ）。**lint/format/typecheck/migration は存在しない**（`zig build test` が型検査も兼ねる）。
- 新規 `.zig` は無し（既存ファイルへ追加）。`src/root_test.zig` の import 変更不要。
- 所有権規約: Msg/AppCmd ペイロードは複製所有・消費者が deinit。Model 文字列は persistent allocator 所有・置換時に旧 free。
- `std.ArrayList(T)` は unmanaged（`.empty` / `append(a, x)` / `toOwnedSlice(a)`）。OOM 教訓: `toOwnedSlice` 後は元 ArrayList の errdefer が無害化するため新 slice 用 errdefer を再登録。
- commit メッセージ規約: review ID（spec 節/codex ID）は commit subject 末尾へ括弧付き（例 `(§3.3/codex MAJOR)`）。
- **実行開始時に `main` から feature ブランチ `feat/branch-filter` を切る**（#2/#4 と同じ no-ff flow）。

## File Structure

変更は既存ファイルのみ（新規ファイル無し）。層ごと（純粋→UI）:

| ファイル | 責務 | 変更 |
|---|---|---|
| `src/filter.zig` | FilterSpec データモデル | branch variant 追加 |
| `src/git/commands.zig` | git argv 生成 | revParseVerifyArgv + revParseVerify 追加 |
| `src/messages.zig` | Msg/AppCmd 定義 | ApplyFilter.branch 追加 |
| `src/model.zig` | Model 状態 | filter_modal_focus u2→u3 |
| `src/update.zig` | 純粋 reducer | focus wrap・apply_filter branch 検証 |
| `src/appcmd.zig` | AppCmd 解釈器 | runLogInt branch 解決・branchLoadFailed |
| `src/view.zig` | 描画 | filterReasonText branch |
| `src/main.zig` | UI 配線 | 5 欄 TextInput |
| `TODO.md` / `README.md` | ドキュメント | チェックボックス・キーマップ |

---

## Task 1: filter.zig — branch variant（純粋層）

**Files:**
- Modify: `src/filter.zig:6-18`（定数・FilterCondition）, `:60-90`（accessor）, `:119-163`（deinit/clone/eql helpers）
- Test: `src/filter.zig`（同ファイル `test {}`）

**Interfaces:**
- Produces: `FilterCondition.branch: []u8`, `FilterSpec.getBranch() ?[]const u8`, `max_branch_runes: usize = 256`。既存 `addCondition`/`removeVariant`/`clone`/`eql`/`deinit` は branch variant を既存仕組み（`std.meta.activeTag` dedup・OOM 時 payload 自動 deinit）で処理。

- [ ] **Step 1: 定数と union variant を追加**

`src/filter.zig:6-9` の定数群へ `max_branch_runes` を追加:
```zig
pub const max_author_runes: usize = 256;
pub const max_branch_runes: usize = 256; // ★phase 3b #1: branch/revspec
pub const max_date_runes: usize = 16;
pub const max_path_runes: usize = 1024;
pub const max_path_count: usize = 16;
```

`src/filter.zig:13-18` の `FilterCondition` union へ `branch` を追加（author の直後）:
```zig
pub const FilterCondition = union(enum) {
    author: []u8,
    branch: []u8, // ★phase 3b #1: branch/revspec（runLogInt が snapshot_tip 解決に使用・logArgv は無視）
    since: []u8,
    until: []u8,
    paths: [][]u8,
};
```

- [ ] **Step 2: accessor `getBranch` を追加**

`src/filter.zig:60-66`（`getAuthor` の直後）へ追加:
```zig
    pub fn getBranch(self: FilterSpec) ?[]const u8 {
        for (self.conditions.items) |c| switch (c) {
            .branch => |t| return t,
            else => {},
        };
        return null;
    }
```

- [ ] **Step 3: helper switch へ branch arm を追加**

`deinitCondition`（`:119-127`）・`cloneCondition`（`:129-148`）・`conditionEql`（`:150-163`）は `switch (cond)` で網羅的。branch variant 追加で**コンパイルエラー**が出るので arm を追加:

`deinitCondition`:
```zig
fn deinitCondition(a: std.mem.Allocator, cond: FilterCondition) void {
    switch (cond) {
        .author, .branch, .since, .until => |t| a.free(t),
        .paths => |list| {
            for (list) |p| a.free(p);
            a.free(list);
        },
    }
}
```

`cloneCondition`（author の直後に branch）:
```zig
        .author => |t| .{ .author = try a.dupe(u8, t) },
        .branch => |t| .{ .branch = try a.dupe(u8, t) },
        .since => |t| .{ .since = try a.dupe(u8, t) },
```

`conditionEql`（author の直後に branch）:
```zig
        .author => |t| std.mem.eql(u8, t, b_cond.author),
        .branch => |t| std.mem.eql(u8, t, b_cond.branch),
        .since => |t| std.mem.eql(u8, t, b_cond.since),
```

- [ ] **Step 4: テストを追加**

`src/filter.zig` のテストセクション（`test "FilterSpec: UTF-8 author preserved through clone"` の直後等）へ追加:
```zig
test "FilterSpec: branch variant addCondition/getBranch/clone/eql/deinit (phase 3b #1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getBranch());
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try std.testing.expect(!spec.isEmpty());
    try std.testing.expectEqualStrings("dev", spec.getBranch().?);
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("dev", cloned.getBranch().?);
    try std.testing.expect(spec.getBranch().?.ptr != cloned.getBranch().?.ptr);
    spec.removeVariant(a, .branch);
    try std.testing.expectEqual(@as(?[]const u8, null), spec.getBranch());
    try std.testing.expect(spec.isEmpty());
}

test "FilterSpec: duplicate branch overwrites (codex m1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try std.testing.expectEqual(@as(usize, 1), spec.conditions.items.len);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "main") });
    try std.testing.expectEqual(@as(usize, 1), spec.conditions.items.len);
    try std.testing.expectEqualStrings("main", spec.getBranch().?);
}

test "FilterSpec: branch + author + paths multi-variant clone no leak (phase 3b #1)" {
    const a = std.testing.allocator;
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    const paths = try a.alloc([]u8, 1);
    paths[0] = try a.dupe(u8, "src/");
    try spec.addCondition(a, .{ .paths = paths });
    var cloned = try spec.clone(a);
    defer cloned.deinit(a);
    try std.testing.expect(spec.eql(cloned));
    try std.testing.expectEqualStrings("dev", cloned.getBranch().?);
    try std.testing.expectEqualStrings("foo", cloned.getAuthor().?);
    try std.testing.expectEqual(@as(usize, 1), cloned.getPaths().len);
}

test "FilterSpec: max_branch_runes constant preserved" {
    try std.testing.expectEqual(@as(usize, 256), max_branch_runes);
}

test "FilterSpec: addCondition branch OOM frees payload (M3, phase 3b #1)" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, addConditionBranchOomHelper, .{});
}

fn addConditionBranchOomHelper(a: std.mem.Allocator) !void {
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "first") });
    // branch payload（dupe 済み "dev"）は addCondition の append が OOM すると list へ入らず
    // 呼出側へも戻らない → addCondition が内部で deinit する（M3・spec §8.1）。
    const branch = try a.dupe(u8, "dev");
    spec.addCondition(a, .{ .branch = branch }) catch |err| switch (err) {
        error.OutOfMemory => return,
    };
}
```

- [ ] **Step 5: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（既存 + 新規 4 テスト。branch variant が `refAllDecls` で型検査される）。

- [ ] **Step 6: commit**

```bash
git add src/filter.zig
git commit -m "feat(filter): add branch variant to FilterCondition (phase 3b #1 §3.1)"
```

---

## Task 2: git/commands.zig — revParseVerifyArgv + revParseVerify

**Files:**
- Modify: `src/git/commands.zig:255-277`（`revParseHeadArgv`/`revParseHead` の近傍へ追加）
- Test: `src/git/commands.zig`（同ファイル `test {}`）

**Interfaces:**
- Produces: `pub fn revParseVerifyArgv(a: std.mem.Allocator, revspec: []const u8) !OwnedArgv`（`"<rev>^{commit}"` を owned へ 1 文字列追跡）・`pub fn revParseVerify(a: std.mem.Allocator, io: std.Io, cwd: Cwd, revspec: []const u8) !?[]u8`（exit≠0 は null）。後続 Task 6 が `cmds.revParseVerify` を消費。

- [ ] **Step 1: テストを追加（fail 期待）**

`src/git/commands.zig` のテストセクション（`test "revParseHeadArgv returns git rev-parse --verify HEAD"` の直後・`:566` 付近）へ追加:
```zig
test "revParseVerifyArgv: git rev-parse --verify --end-of-options <rev>^{commit} (phase 3b #1)" {
    const a = std.testing.allocator;
    var argv = try revParseVerifyArgv(a, "dev");
    defer argv.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), argv.args.len);
    try std.testing.expectEqualStrings("git", argv.args[0]);
    try std.testing.expectEqualStrings("rev-parse", argv.args[1]);
    try std.testing.expectEqualStrings("--verify", argv.args[2]);
    try std.testing.expectEqualStrings("--end-of-options", argv.args[3]);
    try std.testing.expectEqualStrings("dev^{commit}", argv.args[4]);
    try std.testing.expectEqual(@as(usize, 1), argv.owned.items.len);
    try std.testing.expectEqualStrings("dev^{commit}", argv.owned.items[0]);
}

test "revParseVerifyArgv: UTF-8 revspec preserved in peel suffix" {
    const a = std.testing.allocator;
    var argv = try revParseVerifyArgv(a, "feature/日本語");
    defer argv.deinit(a);
    try std.testing.expectEqualStrings("feature/日本語^{commit}", argv.args[4]);
}
```

- [ ] **Step 2: テストを実行して fail を確認**

Run: `zig build test --summary all 2>&1 | rg -A3 revParseVerifyArgv`
Expected: FAIL（`revParseVerifyArgv` 未定義・コンパイルエラー）。

- [ ] **Step 3: 実装を追加**

`src/git/commands.zig:257`（`revParseHeadArgv` の直後）へ追加:
```zig
/// `git rev-parse --verify --end-of-options <rev>^{commit}` argv（branch/revspec 解決用・phase 3b #1）。
/// ★--end-of-options: 先頭 `-` の入力を option ではなく revspec として扱い injection を防ぐ（真の安全境界・実証済み）。
/// ★^{commit}: blob/tree hash を弾き commit のみ受理（peel 失敗は exit≠0 → null・実証済み）。
/// revspec から "<rev>^{commit}" を生成し owned へ追跡（logArgv の --author 文字列と同型・OwnedArgv.deinit が free・二重 free 無し）。
pub fn revParseVerifyArgv(a: std.mem.Allocator, revspec: []const u8) !OwnedArgv {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| a.free(s);
        owned.deinit(a);
    }
    try list.appendSlice(a, &.{ "git", "rev-parse", "--verify", "--end-of-options" });
    const rev_with_peel = std.fmt.allocPrint(a, "{s}^{{commit}}", .{revspec}) catch return error.OutOfMemory;
    owned.append(a, rev_with_peel) catch {
        a.free(rev_with_peel);
        return error.OutOfMemory;
    };
    try list.append(a, rev_with_peel);
    return .{ .args = try list.toOwnedSlice(a), .owned = owned };
}
```

`src/git/commands.zig:277`（`revParseHead` の直後）へ高レベル関数を追加:
```zig
/// revspec を commit hash へ解決（呼出側 free）。exit≠0（不明 branch/rev・blob/tree・peel 失敗）は null。
/// ★phase 3b #1: branch フィルタの snapshot_tip 解決に使用（revParseHead の汎化版）。
pub fn revParseVerify(a: std.mem.Allocator, io: std.Io, cwd: Cwd, revspec: []const u8) !?[]u8 {
    var argv = try revParseVerifyArgv(a, revspec);
    defer argv.deinit(a);
    var res = try process.run(a, io, argv.args, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    return try a.dupe(u8, trimmed);
}
```

- [ ] **Step 4: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（argv 形式 + UTF-8 保存。`revParseVerify` は `refAllDecls` で型検査・実行は Task 6 の統合テスト）。

- [ ] **Step 5: commit**

```bash
git add src/git/commands.zig
git commit -m "feat(git): add revParseVerify for branch/revspec resolution (phase 3b #1 §3.3/codex MAJOR)"
```

---

## Task 3: messages.zig — ApplyFilter.branch

**Files:**
- Modify: `src/messages.zig:87-99`（`ApplyFilter` 構造体）
- Test: `src/messages.zig`（同ファイル `test {}`）

**Interfaces:**
- Produces: `Msg.ApplyFilter.branch: ?[]u8`（**default `= null`**・既存リテラルが branch 省略でもコンパイル通るように）。`deinit` が branch を free。

> ★**default `= null` の理由**: 5 ファイルの既存 `Msg{ .apply_filter = .{ .author=..., .since=..., .until=..., .paths=... } }` リテラル（main.zig・messages.zig・update.zig テスト）が branch 省略でコンパイルエラーになるのを防ぐ。Task 8 で main.zig の実リテラルのみ branch を明示設定する。

- [ ] **Step 1: 構造体へ branch field を追加**

`src/messages.zig:87-99`（`ApplyFilter`）を編集。branch を先頭へ・default null:
```zig
    pub const ApplyFilter = struct {
        branch: ?[]u8 = null, // ★phase 3b #1: branch/revspec（空なら null）
        author: ?[]u8,
        since: ?[]u8,
        until: ?[]u8,
        paths: [][]u8,
        pub fn deinit(self: *ApplyFilter, a: std.mem.Allocator) void {
            if (self.branch) |x| a.free(x); // ★phase 3b #1
            if (self.author) |x| a.free(x);
            if (self.since) |x| a.free(x);
            if (self.until) |x| a.free(x);
            for (self.paths) |p| a.free(p);
            a.free(self.paths);
        }
    };
```

- [ ] **Step 2: テストを追加**

`src/messages.zig`（`test "Msg.apply_filter (ApplyFilter) deinit with nulls and empty paths"` の直後）へ追加:
```zig
test "Msg.apply_filter (ApplyFilter) deinit frees branch field (phase 3b #1)" {
    const a = std.testing.allocator;
    var msg = Msg{ .apply_filter = .{
        .branch = try a.dupe(u8, "dev"),
        .author = null,
        .since = null,
        .until = null,
        .paths = try a.alloc([]u8, 0),
    } };
    msg.deinit(a);
}
```

- [ ] **Step 3: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（既存 ApplyFilter リテラルは branch=default null でコンパイル・新規 deinit テストで branch free を検証）。

- [ ] **Step 4: commit**

```bash
git add src/messages.zig
git commit -m "feat(msg): add branch field to ApplyFilter with default null (phase 3b #1 §3.2)"
```

---

## Task 4: model.zig + update.zig — filter_modal_focus u3 + focus wrap

**Files:**
- Modify: `src/model.zig:77`（field 型）, `:1013`（テスト）, `src/update.zig:893-903`（focus handlers）, `:3655-3683`（テスト群）
- Test: 同ファイル `test {}`

**Interfaces:**
- Produces: `Model.filter_modal_focus: u3`（0-4・5 欄）・file-scope `const filter_field_count: u3 = 5`。`handleFilterFocusNext`/`Prev` は明示的 bound（`filter_field_count - 1`）で wrap。後続 Task 8 の main.zig switch が 0-4 を使う。

> ★**核心 gotcha（codex/§4.1）**: 現状 `handleFilterFocusNext` は `model.filter_modal_focus +%= 1`（u2 wrapping・`3+%=1==0`）。u3 では `4+%=1==5` で wrap しない（5 は空欄へ飛ぶバグ）。**明示的 bound へ変更必須**。

- [ ] **Step 1: model.zig の型を u2→u3 へ**

`src/model.zig:77`:
```zig
    filter_modal_focus: u3,
```

`src/model.zig:1013`（テストの `@as`）:
```zig
    try std.testing.expectEqual(@as(u3, 0), m.filter_modal_focus);
```

- [ ] **Step 2: update.zig の focus handler を明示的 bound へ**

`src/update.zig:893-903` を以下へ全面置換（`const filter_field_count` を直上へ追加）:
```zig
/// phase 3b #1: フィルタモーダルの欄数（Branch/Author/Since/Until/Path = 5）。
/// u3（0-4）の wrap 上限。`+%= 1` は u2 専用（u3 では wrap しない）なので明示的 bound を使う。
const filter_field_count: u3 = 5;

/// §4.3: `filter_focus_next` arm。明示的 bound で 4→0 へ wrap（u3・codex §4.1）。
fn handleFilterFocusNext(model: *Model) !AppCmd {
    model.filter_modal_focus =
        if (model.filter_modal_focus == filter_field_count - 1) 0
        else model.filter_modal_focus + 1;
    return .none;
}

/// §4.3: `filter_focus_prev` arm。0→4 へ wrap。
fn handleFilterFocusPrev(model: *Model) !AppCmd {
    model.filter_modal_focus =
        if (model.filter_modal_focus == 0) filter_field_count - 1
        else model.filter_modal_focus - 1;
    return .none;
}
```

- [ ] **Step 3: 既存 focus テストを 5 欄（4→0 / 0→4）へ更新**

`src/update.zig:3655-3673` の 2 テストを更新:
```zig
test "filter_focus_next: wraps 4→0 (u3, 5 fields, phase 3b #1)" {
    var m = try Model.init(std.testing.allocator, "/r");
    defer m.deinit();
    m.filter_modal_focus = 4;
    var cmd = try update(&m, .filter_focus_next);
    try std.testing.expectEqual(@as(u3, 0), m.filter_modal_focus);
    try std.testing.expect(cmd == .none);
}

test "filter_focus_prev: wraps 0→4 (phase 3b #1)" {
    var m = try Model.init(std.testing.allocator, "/r");
    defer m.deinit();
    m.filter_modal_focus = 0;
    var cmd = try update(&m, .filter_focus_prev);
    try std.testing.expectEqual(@as(u3, 4), m.filter_modal_focus);
    try std.testing.expect(cmd == .none);
}
```

`src/update.zig:3683`（`open_filter_modal: resets focus to 0` テストの `@as`）のみ `u2`→`u3`:
```zig
    try std.testing.expectEqual(@as(u3, 0), m.filter_modal_focus);
```

- [ ] **Step 4: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（focus wrap 4→0/0→4・open_modal reset 0・model init u3）。

- [ ] **Step 5: commit**

```bash
git add src/model.zig src/update.zig
git commit -m "feat(update): filter_modal_focus u3 with explicit 5-field wrap (phase 3b #1 §4.1)"
```

---

## Task 5: update.zig — handleApplyFilter の branch バリデーション

**Files:**
- Modify: `src/update.zig:751-829`（`handleApplyFilter`）, テスト追加
- Test: 同ファイル `test {}`

**Interfaces:**
- Consumes: Task 1 `FilterCondition.branch`/`max_branch_runes`・Task 3 `ApplyFilter.branch`。
- Produces: `handleApplyFilter` が `af.branch` を検証し `new_spec.addCondition(.{ .branch = ... })`。失敗時モーダル維持・`log_load_error`。

- [ ] **Step 1: テストを追加（fail 期待）**

`src/update.zig`（phase 3b Task 7 テスト群の末尾・`test "apply_filter: addCondition OOM no payload leak (M3)"` の直前等）へ追加:
```zig
test "apply_filter: branch only validates and stores (phase 3b #1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var msg = Msg{ .apply_filter = .{
        .branch = try a.dupe(u8, "dev"),
        .author = null, .since = null, .until = null, .paths = try a.alloc([]u8, 0),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("dev", m.filter_state.getBranch().?);
    try std.testing.expect(cmd == .load_log);
}

test "apply_filter: branch leading dash rejected (phase 3b #1 §3.4)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var msg = Msg{ .apply_filter = .{
        .branch = try a.dupe(u8, "-all"),
        .author = null, .since = null, .until = null, .paths = try a.alloc([]u8, 0),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(m.filter_state.isEmpty());
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.filter_modal_open); // モーダル維持
    try std.testing.expect(std.mem.indexOf(u8, m.log_load_error, "先頭に - は使えません") != null);
}

test "apply_filter: branch too long rejected (phase 3b #1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const long = try a.alloc(u8, 257);
    defer a.free(long);
    @memset(long, 'x');
    var msg = Msg{ .apply_filter = .{
        .branch = try a.dupe(u8, long),
        .author = null, .since = null, .until = null, .paths = try a.alloc([]u8, 0),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(m.filter_state.isEmpty());
    try std.testing.expect(cmd == .none);
    try std.testing.expect(std.mem.indexOf(u8, m.log_load_error, "長すぎます") != null);
}

test "apply_filter: branch empty normalizes to no branch condition (phase 3b #1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var msg = Msg{ .apply_filter = .{
        .branch = try a.dupe(u8, ""),
        .author = null, .since = null, .until = null, .paths = try a.alloc([]u8, 0),
    } };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expectEqual(@as(?[]const u8, null), m.filter_state.getBranch());
    try std.testing.expect(m.filter_state.isEmpty());
    try std.testing.expect(cmd == .load_log); // 空 filter → 全件 reload (HEAD)
}
```

- [ ] **Step 2: テストを実行して fail を確認**

Run: `zig build test --summary all 2>&1 | rg -A2 'branch only validates|leading dash'`
Expected: FAIL（branch 検証が無く "dev" が格納されない・dash が通る）。

- [ ] **Step 3: バリデーションを追加**

`src/update.zig` `handleApplyFilter` の author バリデーションブロック（`:754-765`）の**直後**（since バリデーションの前）へ branch バリデーションを追加:
```zig
    if (af.branch) |text| {
        if (text.len > 0) {
            // ★codex MAJOR: argv builder（revParseVerifyArgv の --end-of-options）が真の安全境界だが、
            //   ここで弾いて「分かりやすい日本語エラー」を先に出す（defense in depth・UX 層）。
            if (text[0] == '-') {
                try model.setLogLoadError("ブランチ/リビジョン名が不正です（先頭に - は使えません）");
                return .none;
            }
            const count = std.unicode.utf8CountCodepoints(text) catch {
                try model.setLogLoadError("ブランチ/リビジョン名が長すぎます（256 Unicode scalar まで）");
                return .none;
            };
            if (count > filter_mod.max_branch_runes) {
                try model.setLogLoadError("ブランチ/リビジョン名が長すぎます（256 Unicode scalar まで）");
                return .none;
            }
        }
    }
```

- [ ] **Step 4: addCondition を追加**

`src/update.zig` `handleApplyFilter` の FilterSpec 構築フェーズ（author addCondition `:808-812` の直後・since の前）へ:
```zig
    if (af.branch) |text| {
        if (text.len > 0) {
            try new_spec.addCondition(a, .{ .branch = try a.dupe(u8, text) });
        }
    }
```

- [ ] **Step 5: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（branch 検証 4 ケース・既存 apply_filter テスト不変）。

- [ ] **Step 6: commit**

```bash
git add src/update.zig
git commit -m "feat(update): validate and store branch condition in apply_filter (phase 3b #1 §3.4/codex MAJOR)"
```

---

## Task 6: appcmd.zig — runLogInt branch 解決 + branchLoadFailed

**Files:**
- Modify: `src/appcmd.zig:197-201`（`runLogInt` snapshot_tip 解決）, `:265` 付近（`branchLoadFailed` ヘルパ追加）, テスト追加
- Test: 同ファイル（`TmpRepo` 使用の実 git 統合テスト）

**Interfaces:**
- Consumes: Task 1 `FilterSpec.getBranch`・Task 2 `cmds.revParseVerify`・既存 `mkLoadFailedOrSilent`/`mkLoadFailedSilent`。
- Produces: `runLogInt` が branch 有りなら `revParseVerify` で snapshot_tip 解決・失敗時 `branchLoadFailed` → `LogLoadFailed`。

- [ ] **Step 1: テストを追加（fail 期待）**

`src/appcmd.zig`（`test "load_log with author filter returns LogLoaded with substrate"` の直後・`:1002` 付近）へ追加:
```zig
test "load_log with branch filter returns branch tip's log + substrate (phase 3b #1)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.git(a, io, &.{ "git", "add", "b.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c2" });
    try repo.git(a, io, &.{ "git", "branch", "dev" }); // dev -> c2
    try repo.writeFile(io, "c.txt", "c\n");
    try repo.git(a, io, &.{ "git", "add", "c.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c3" }); // default 進む (HEAD=c3)
    var spec = FilterSpec.init();
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    // dev tip = c2 → c3 は到達不能 → c1, c2 のみ（HEAD なら c1,c2,c3）。
    try std.testing.expectEqual(@as(usize, 2), msg.log_loaded.entries.len);
    try std.testing.expectEqualStrings("c2", msg.log_loaded.entries[0].subject);
    try std.testing.expectEqualStrings("c1", msg.log_loaded.entries[1].subject);
    try std.testing.expect(msg.log_loaded.substrate != null); // filter 活性 -> substrate
}

test "load_log with non-existent branch returns LogLoadFailed (phase 3b #1)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    var spec = FilterSpec.init();
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "no-such-branch") });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_load_failed);
    try std.testing.expect(std.mem.indexOf(u8, msg.log_load_failed.error_text, "no-such-branch") != null);
}

test "load_log with blob hash returns LogLoadFailed (^{commit} peel, phase 3b #1)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    var r = try process.run(a, io, &.{ "git", "rev-parse", "HEAD:a.txt" }, repo.cwd());
    defer r.deinit(a);
    // ★所有権: blob の dupe は addCondition へ移譲（runOwned → filter.deinit が解放）。
    //   defer a.free(blob) を置くと filter.deinit と二重 free になる（codex BLOCKER3）。
    var spec = FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, std.mem.trimEnd(u8, r.stdout, "\n")) });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_load_failed);
}

test "load_log with annotated tag resolves to commit (^{commit} peel, phase 3b #1 spec §8.3)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    // annotated tag（tag object → ^{commit} で commit へ peel）。
    try repo.git(a, io, &.{ "git", "tag", "-a", "v1", "-m", "release" });
    var spec = FilterSpec.init();
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "v1") });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 1), msg.log_loaded.entries.len); // c1 のみ
    try std.testing.expect(msg.log_loaded.substrate != null);
}

test "load_log with branch + author composes (phase 3b #1)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // c1 を author "other" で作成（compose 実証のため・codex MAJOR）。
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "-c", "user.name=other", "-c", "user.email=o@o", "commit", "-q", "-m", "c1" });
    // c2 をデフォルト author "t" で作成。
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.git(a, io, &.{ "git", "add", "b.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c2" });
    try repo.git(a, io, &.{ "git", "branch", "dev" }); // dev -> c2 (c1, c2 到達可能)
    // branch=dev (c1,c2) + author=t → c1 は author 不一致で除外 → c2 のみ（compose 実証）。
    var spec = FilterSpec.init();
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "t") });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(usize, 1), msg.log_loaded.entries.len); // c2 のみ（c1 は author 除外）
    try std.testing.expectEqualStrings("c2", msg.log_loaded.entries[0].subject);
    try std.testing.expect(msg.log_loaded.substrate != null);
}
```

- [ ] **Step 2: テストを実行して fail を確認**

Run: `zig build test --summary all 2>&1 | rg -A3 'branch filter returns|non-existent branch'`
Expected: FAIL（branch 有りでも HEAD の log が返る・3 commits・substrate 条件で不一致 or blob で log_loaded になる）。

- [ ] **Step 3: branchLoadFailed ヘルパを追加**

`src/appcmd.zig` `mkLoadFailedSilent`（`:265-267`）の直後へ追加:
```zig
/// phase 3b #1: branch 解決失敗（exit≠0: 不明 branch/revspec・blob/tree・peel 失敗）→ branch 名入りの LogLoadFailed。
/// メッセージ dupe の OOM は mkLoadFailedSilent へ fallback（既存 mkLoadFailedOrSilent と同型・強例外保証）。
fn branchLoadFailed(a: std.mem.Allocator, cmd: AppCmd.LoadLog, branch: []const u8) Msg {
    const text = std.fmt.allocPrint(a, "ブランチ/リビジョン '{s}' が見つかりません", .{branch}) catch
        return mkLoadFailedSilent(cmd);
    return .{ .log_load_failed = .{
        .request_generation = cmd.generation,
        .request_tip = null,
        .error_text = text,
    } };
}
```

- [ ] **Step 4: runLogInt の snapshot_tip 解決を分岐化**

`src/appcmd.zig:197-201`（現状 `revParseHead` のみ）を以下へ置換:
```zig
    // ★B1/phase 3b #1: branch 有りなら rev-parse --verify <branch>^{commit}、無ければ HEAD。
    //   branch 解決失敗（RunError/exit≠0）は既存 LogLoadFailed ファミリへ正規化。
    const branch = cmd.filter.getBranch();
    const snapshot_tip: ?[]u8 = if (branch) |b| blk: {
        const resolved = cmds.revParseVerify(a, io, cwd, b) catch
            return mkLoadFailedOrSilent(a, cmd, "ブランチ/リビジョンの解決に失敗", null);
        if (resolved == null) return branchLoadFailed(a, cmd, b); // 不明/非 commit
        break :blk resolved;
    } else cmds.revParseHead(a, io, cwd) catch
        return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
    if (snapshot_tip == null) return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
    defer a.free(snapshot_tip.?);
```

> 以降（logArgv・runWithLimit・parse・substrate）は**不変**。snapshot_tip = branch hash で logArgv/substrate/fetchSubstrate が従来通り動く。

- [ ] **Step 5: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（branch tip log + substrate・非存在 branch → LogLoadFailed・blob → LogLoadFailed・annotated tag → peel で log_loaded・branch+author compose（c2 のみ）・既存 HEAD 系テスト不変）。

- [ ] **Step 6: commit**

```bash
git add src/appcmd.zig
git commit -m "feat(appcmd): resolve branch to snapshot_tip in runLogInt (phase 3b #1 §3.5/codex BLOCKER3/MAJOR)"
```

---

## Task 7: view.zig — filterReasonText へ branch セグメント

**Files:**
- Modify: `src/view.zig:33-62`（`filterReasonText`）, テスト追加
- Test: 同ファイル `test {}`

**Interfaces:**
- Consumes: Task 1 `FilterSpec.getBranch`。
- Produces: `filterReasonText` が `Filter: branch="..." ...` 形式（branch 先頭）を返す。

- [ ] **Step 1: テストを追加（fail 期待）**

`src/view.zig:1149`（`test "filterReasonText: author only"` の直前）へ追加。既存 `test "filterReasonText: all variants"`（`:1170`）も branch を含む期待へ更新するため先に新規テストを追加:
```zig
test "filterReasonText: branch only (phase 3b #1)" {
    const a = std.testing.allocator;
    var spec = @import("filter.zig").FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    const out = filterReasonText(a, spec);
    try std.testing.expectEqualStrings("Filter: branch=\"dev\"", out);
}
```

- [ ] **Step 2: テストを実行して fail を確認**

Run: `zig build test --summary all 2>&1 | rg -A2 'branch only'`
Expected: FAIL（branch セグメント未実装・`"Filter:"` のみ返る）。

- [ ] **Step 3: branch セグメントを実装**

`src/view.zig:38-42`（`buf.appendSlice(a, "Filter:")` の直後・author の前）へ branch セグメントを挿入:
```zig
    buf.appendSlice(a, "Filter:") catch return "Filter:";
    if (filter.getBranch()) |text| {
        const part = std.fmt.allocPrint(a, " branch=\"{s}\"", .{text}) catch return "Filter:";
        defer a.free(part);
        buf.appendSlice(a, part) catch return "Filter:";
    }
    if (filter.getAuthor()) |text| {
```

- [ ] **Step 4: 既存 all-variants テストへ branch を追加**

`src/view.zig:1170`（`test "filterReasonText: all variants"`）の spec 構築へ branch addCondition を追加し、期待文字列の先頭へ `branch="dev"` を入れる:
```zig
test "filterReasonText: all variants (phase 3b #1)" {
    const a = std.testing.allocator;
    var spec = @import("filter.zig").FilterSpec.init();
    defer spec.deinit(a);
    try spec.addCondition(a, .{ .branch = try a.dupe(u8, "dev") });
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "foo") });
    try spec.addCondition(a, .{ .since = try a.dupe(u8, "2026-06-01") });
    try spec.addCondition(a, .{ .until = try a.dupe(u8, "2026-06-30") });
    const paths = try a.alloc([]u8, 1);
    paths[0] = try a.dupe(u8, "src/");
    try spec.addCondition(a, .{ .paths = paths });
    const out = filterReasonText(a, spec);
    try std.testing.expectEqualStrings("Filter: branch=\"dev\" author=\"foo\" since=2026-06-01 until=2026-06-30 paths=src/", out);
}
```

- [ ] **Step 5: テストを実行して pass を確認**

Run: `zig build test --summary all`
Expected: PASS（branch only・all variants・既存 author/empty テスト不変）。

- [ ] **Step 6: commit**

```bash
git add src/view.zig
git commit -m "feat(view): add branch segment to filterReasonText (phase 3b #1 §4.3)"
```

---

## Task 8: main.zig 5 欄 UI + README/TODO + tmux 検証

**Files:**
- Modify: `src/main.zig:107-111`（App 構造体）, `:302-320`（init）, `:369-373`（deinit）, `:409-430`（syncFilterModal）, `:432-443`（syncFocus）, `:445-452`（buildModalBody）, `:502-509`（focusTextInput）, `:511-565`（applyFilterFromModal）
- Modify: `TODO.md:195`, `README.md`（フィルタ説明）
- Test: 単体テスト無し（zigzag UI・`zig build` 型検査 + tmux pty 目視）

**Interfaces:**
- Consumes: Task 1 `getBranch`・Task 3 `ApplyFilter.branch`・Task 4 `filter_modal_focus: u3`。

- [ ] **Step 1: App 構造体へ filter_branch_input を追加**

`src/main.zig:107`（`filter_author_input` の直前）へ:
```zig
    filter_branch_input: zz.TextInput,
    filter_author_input: zz.TextInput,
```

- [ ] **Step 2: init で filter_branch_input を生成**

`src/main.zig:305`（`filter_author_input = zz.TextInput.init(...)` の直前）へ:
```zig
        g_app.filter_branch_input = zz.TextInput.init(ctx.persistent_allocator);
        g_app.filter_branch_input.setCharLimit(256);
        g_app.filter_branch_input.setPlaceholder("branch or rev");
        g_app.filter_author_input = zz.TextInput.init(ctx.persistent_allocator);
```

- [ ] **Step 3: deinit へ追加**

`src/main.zig:369`（`filter_author_input.deinit()` の直前）へ:
```zig
        app.filter_branch_input.deinit();
        app.filter_author_input.deinit();
```

- [ ] **Step 4: syncFilterModal へ branch プレフィルを追加**

`src/main.zig:411`（`const fs = app.model.filter_state;` の直後・author の前）へ:
```zig
        const fs = app.model.filter_state;
        app.filter_branch_input.setValue(fs.getBranch() orelse "") catch {};
        app.filter_author_input.setValue(fs.getAuthor() orelse "") catch {};
```

- [ ] **Step 5: syncFocus を 5 欄（Branch=0）へ**

`src/main.zig:432-443` を以下へ置換（branch blur + focus・他欄 index 1-4 へ・★codex BLOCKER1: u3 は 0-7 なので `else => unreachable` で網羅。invariant: focus は init/focus_next/prev/open_modal で常に 0..4 に保たれる）:
```zig
fn syncFocus(app: *App) void {
    app.filter_branch_input.blur();
    app.filter_author_input.blur();
    app.filter_since_input.blur();
    app.filter_until_input.blur();
    app.filter_path_input.blur();
    switch (app.model.filter_modal_focus) {
        0 => app.filter_branch_input.focus(),
        1 => app.filter_author_input.focus(),
        2 => app.filter_since_input.focus(),
        3 => app.filter_until_input.focus(),
        4 => app.filter_path_input.focus(),
        else => unreachable, // filter_field_count=5・focus は常に 0..4
    }
}
```

- [ ] **Step 6: buildModalBody へ Branch 行（先頭）を追加**

`src/main.zig:445-451` を以下へ置換（f==0 のとき branch のみ `.view(a)`・他は getValue）:
```zig
fn buildModalBody(app: *App, a: std.mem.Allocator) ![]const u8 {
    const f = app.model.filter_modal_focus;
    const branch_view: []const u8 = if (f == 0) try app.filter_branch_input.view(a) else app.filter_branch_input.getValue();
    const author_view: []const u8 = if (f == 1) try app.filter_author_input.view(a) else app.filter_author_input.getValue();
    const since_view: []const u8 = if (f == 2) try app.filter_since_input.view(a) else app.filter_since_input.getValue();
    const until_view: []const u8 = if (f == 3) try app.filter_until_input.view(a) else app.filter_until_input.getValue();
    const path_view: []const u8 = if (f == 4) try app.filter_path_input.view(a) else app.filter_path_input.getValue();
    return std.fmt.allocPrint(a, "Branch: {s}\nAuthor: {s}\nSince:  {s}\nUntil:  {s}\nPath:   {s}", .{ branch_view, author_view, since_view, until_view, path_view });
}
```

- [ ] **Step 7: focusTextInput を 5 欄へ**

`src/main.zig:502-508` を以下へ置換（★codex BLOCKER1: `else => unreachable` で網羅）:
```zig
fn focusTextInput(app: *App) *zz.TextInput {
    return switch (app.model.filter_modal_focus) {
        0 => &app.filter_branch_input,
        1 => &app.filter_author_input,
        2 => &app.filter_since_input,
        3 => &app.filter_until_input,
        4 => &app.filter_path_input,
        else => unreachable, // filter_field_count=5・focus は常に 0..4
    };
}
```

- [ ] **Step 7b: `g_app = .{ ... }` リテラル 2 箇所へ filter_branch_input を追加（★codex BLOCKER2）**

`App` へ field を追加すると `g_app` の struct リテラル（全 field 指定）がコンパイルエラーになる。2 箇所を更新:

`src/main.zig:687`（runtime init・`g_app = .{ ... }`）へ `.textarea = undefined,` の直前に追加（他の filter_*_input と同様 `undefined`・実体は RuntimeModel.init で生成）:
```zig
        .textarea = undefined, // RuntimeModel.init で生成
        .filter_branch_input = undefined,
        .filter_author_input = undefined,
```

`src/main.zig:763`（`makeTestApp` の `g_app = .{ ... }`）へ `.textarea = zz.TextArea.init(a),` の直前に追加（テスト用に直接 init）:
```zig
        .textarea = zz.TextArea.init(a),
        .filter_branch_input = zz.TextInput.init(a),
        .filter_author_input = zz.TextInput.init(a),
```

> `freeTestApp`（`:781`）は Model/gpa の解放のみで TextInput の個別 deinit をしない既存構造（`std.testing.allocator` がリーク検出するため TextInput も解放が必要な場合は既存 4 欄と同様に扱う・実コードを確認し既存パターンに従う）。実装時に `freeTestApp` が 4 欄を deinit していれば branch も追加・deinit していなければ追加不要。

- [ ] **Step 8: applyFilterFromModal へ branch dupe を追加**

`src/main.zig` `applyFilterFromModal`（`:513-521` で `var af = Msg.ApplyFilter{...}` 初期化の直後・`author_v` 取得の前）へ branch dupe を追加（他欄と同型の OOM rollback）:
```zig
    const branch_v = app.filter_branch_input.getValue();
    if (branch_v.len > 0) {
        af.branch = gpa.dupe(u8, branch_v) catch {
            af.deinit(gpa);
            app.model.setLogLoadError("フィルタ適用に失敗（メモリ不足）") catch {};
            return;
        };
    }
    const author_v = app.filter_author_input.getValue();
```

- [ ] **Step 9: ビルドで型検査**

Run: `zig build`
Expected: 成功（main.zig の 5 欄 TextInput・switch 0-4・ApplyFilter.branch の型整合）。

- [ ] **Step 10: 全テスト green を確認**

Run: `zig build test --summary all`
Expected: PASS（既存 542 + 新規。main.zig は単体テスト無し・型検査は `zig build` で保証）。

- [ ] **Step 11: tmux pty で目視検証（再現可能な検証用 repo セットアップ付き・codex MAJOR3）**

`zig build` でバイナリを生成後、独立した検証用 repo（main に 3 commit・`dev` branch に 2 commit）を作って TUI を起動し tmux capture-pane で確認。全手順をスクリプト化し再現可能にする:
```bash
zig build
# --- 検証用 repo セットアップ（main: c1 c2 c3 / dev: c1 c2）---
WORK=/tmp/kilo/gt-verify
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
git init -q
git config user.email t@t && git config user.name t
printf 'a\n' > a.txt && git add a.txt && git commit -qm c1
printf 'b\n' > b.txt && git add b.txt && git commit -qm c2
git branch dev                       # dev -> c2
printf 'c\n' > c.txt && git add c.txt && git commit -qm c3   # main のみ進む
# --- TUI 起動（log mode へ）---
tmux new-session -d -s gt -x 120 -y 40 "cd $WORK && /home/hatai/repos/hatai/git-tui/zig-out/bin/git-tui --no-mouse; sh -c 'read'"
tmux send-keys -t gt "L"             # log mode へ（main: c1 c2 c3 が見える想定）
tmux capture-pane -p -t gt | tail -8 # ← main 全 3 commit を記録
# --- branch フィルタ適用 ---
tmux send-keys -t gt "f"             # filter modal open（Branch 欄 index 0）
tmux send-keys -t gt "dev"
tmux send-keys -t gt Enter           # apply → dev の c1 c2 のみ + graph 表示
sleep 0.3; tmux capture-pane -p -t gt | tail -8   # ← c3 が消え c1 c2 + graph lane を目視
# --- 不明 branch エラー ---
tmux send-keys -t gt "f"; tmux send-keys -t gt "no-such"; tmux send-keys -t gt Enter
sleep 0.3; tmux capture-pane -p -t gt | tail -5   # ← 「見つかりません」エラー表示
# --- clear_filter で全件復帰 ---
tmux send-keys -t gt "F"
sleep 0.3; tmux capture-pane -p -t gt | tail -8   # ← c1 c2 c3 復帰
# --- 5 欄 Tab cycle（Branch→Author→Since→Until→Path→Branch）---
tmux send-keys -t gt "f"
tmux send-keys -t gt Tab Tab Tab Tab Tab
tmux capture-pane -p -t gt | tail -8   # ← 5 欄を順にフォーカス・Branch へ戻る
tmux send-keys -t gt "q"
tmux kill-session -t gt
cd /home/hatai/repos/hatai/git-tui
```
Expected: dev 適用で c3 が消え c1 c2 + graph lane・不明 branch で「見つかりません」・`F` で c1 c2 c3 復帰・5 欄 Tab cycle が全て正しく描画される。capture-pane の出力を記録として残す。

- [ ] **Step 12: TODO.md のチェックボックスを更新**

`TODO.md:195` を `[ ]` → `[x]` へ・実装詳細を追記:
```markdown
- [x] ブランチ（`--branches`・`<snapshot_tip>` との和集合問題の解決が前提・単一 branch は hash 解決して snapshot_tip へ・複数 branch は所有集合・spec §16/B3）

  **実装詳細**: spec `docs/superpowers/specs/2026-06-29-todo2-log-view-phase3b-branch-filter-design.md`（rev.1・codex レビュー MAJOR1/MINOR1/advisory2 全面反映）。plan `docs/superpowers/plans/2026-06-29-todo2-log-view-phase3b-branch-filter.md`。核心: branch 条件を argv 付加ではなく revision（snapshot_tip）選択として扱い、`git rev-parse --verify --end-of-options <rev>^{commit}` で単一 hash へ解決 → #2 の substrate/投影/paging tip 照合が全て不変（B3 和集合回避）。純粋層（filter.zig branch variant・commands revParseVerifyArgv/revParseVerify・messages ApplyFilter.branch・model filter_modal_focus u3 + 明示的 5 欄 wrap・update handleApplyFilter branch 検証 + u2→u3 wrap・appcmd runLogInt branch 解決 + branchLoadFailed）→ UI 層（view filterReasonText branch・main 5 欄 TextInput）。codex MAJOR（--end-of-options 真の安全境界 + reducer 先頭 - reject の defense in depth）/advisory（^{commit} peel で blob/tree 弾く）対応。
```

- [ ] **Step 13: README へ Branch 欄を追記**

`README.md` のフィルタ説明（`f` モーダル・author/date/path の記載箇所）へ Branch 欄を追記:
- Branch 欄は**任意の git revspec**（branch 名・tag・`origin/main`・hash・`HEAD~5` 等）を受け付け、該当 revision の到達可能履歴に絞り込む。
- 先頭 `-` は不可（git option injection 防止）。不明な branch/revspec はエラー表示。
- 他フィルタ（author/date/path）と組み合わせ可能。

- [ ] **Step 14: commit**

```bash
git add src/main.zig TODO.md README.md
git commit -m "feat(main): 5-field filter modal with branch/revspec input (phase 3b #1 §4.4)"
```

---

## Self-Review

**1. Spec coverage:**
- §1 B3 解法（snapshot_tip 選択）→ Task 6 runLogInt ✓
- §3.1 filter.zig branch variant → Task 1 ✓
- §3.2 ApplyFilter.branch → Task 3 ✓
- §3.3 revParseVerifyArgv + revParseVerify（--end-of-options + ^{commit}）→ Task 2 ✓
- §3.4 handleApplyFilter branch 検証（defense in depth）→ Task 5 ✓
- §3.5 runLogInt 解決分岐 + branchLoadFailed → Task 6 ✓
- §4.1 filter_modal_focus u3 + 明示的 wrap（gotcha）→ Task 4 ✓
- §4.3 filterReasonText branch → Task 7 ✓
- §4.4 main 5 欄 UI → Task 8 ✓
- §8 テスト計画（各層）→ 各 Task の Step ✓
- §10 完了条件（tmux・TODO・README）→ Task 8 ✓

**2. Placeholder scan:** TBD/TODO/「適切に」等のプレースホルダ無し。全ステップに具体コード・コマンド・期待値あり。

**3. Type consistency:**
- `getBranch() ?[]const u8`（Task 1）→ Task 5/6/7/main 全て `?[]const u8` で消費 ✓
- `revParseVerify(a, io, cwd, revspec) !?[]u8`（Task 2）→ Task 6 で `!?[]u8`・null/RunError 分岐 ✓
- `ApplyFilter.branch: ?[]u8 = null`（Task 3）→ Task 5（af.branch `?[]u8`）・Task 8（af.branch = dupe）整合 ✓
- `filter_modal_focus: u3`（Task 4）→ Task 8 switch 0-4 + `else => unreachable`（★codex B1・網羅必須）✓
- `filter_field_count: u3 = 5`（Task 4）→ wrap bound ✓

**4. codex plan review 補完:** 上記 Self-Review（1-3）は plan 著者自身の事前チェック。codex 独立レビューが更に BLOCKER 3（switch 網羅・g_app リテラル・blob double free）を発見 → ヘッダ「Plan review」表の通り全面反映済み。

**層依存順序:** 1(filter) → 2(commands) → 3(messages) → 4(model+focus) → 5(update apply_filter・依存 1+3) → 6(appcmd・依存 1+2) → 7(view・依存 1) → 8(main・依存 1+3+4)。各 Task は先行 Task 完了前提で独立 review 可能 ✓
