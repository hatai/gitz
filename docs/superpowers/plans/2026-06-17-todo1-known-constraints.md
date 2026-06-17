# TODO 1 既知制約 3-5 解消 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TODO 1 の phase 1 で知られていた 3 つの制約（worktree/submodule での apply_patch 失敗、diff_scroll の行数超過、MouseEvent リテラル重複）を解消し、既存テストを全て green に保つ。

**Architecture:** 3 制約は互いに独立。Elm 風・副作用隔離アーキテクチャ（純粋層 model/messages/update/appcmd/git/* + UI 層 input/view/main）を踏襲し、純粋層から TDD → 配線の順で実装する。制約 3 は git-dir 解決で絶対パス化、制約 4 は reducer 側の行数クランプ、制約 5 は MouseEvent の base factoring。

**Tech Stack:** Zig 0.16.0 + zigzag v0.1.5（固定）、`std.process.run(gpa, io, opts)` API、`std.Io.Dir` API、`std.testing.allocator`（リーク検出）。

**Spec:** `docs/superpowers/specs/2026-06-17-todo1-known-constraints-design.md`
**関連規約:** `CLAUDE.md` / `AGENTS.md`（テストは実装 `.zig` 内 `test {}`、`std.testing.allocator` 必須、`zig build test --summary all` が唯一の検証ゲート）

**実装順:** 制約 3（Tasks 1-8）→ 制約 4（Tasks 9-12）→ 制約 5（Tasks 13-15）。各 Task は commit 単位。

---

## 制約 3: worktree / submodule で apply_patch を動くようにする

### Task 1: `gitDirArgv` 純粋関数の TDD（commands.zig）

**Files:**
- Modify: `src/git/commands.zig`（`applyPatchArgv` のテスト直後に argv 生成関数を追加）
- Test: 同ファイル内 `test {}` ブロック

- [ ] **Step 1: 失敗テストを書く**

`src/git/commands.zig` の `test "applyPatchArgv: reverse inserts --reverse before file_path"` の直後に追加:

```zig
test "gitDirArgv builds rev-parse --absolute-git-dir" {
    const a = std.testing.allocator;
    const argv = try gitDirArgv(a);
    defer a.free(argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("rev-parse", argv[1]);
    try std.testing.expectEqualStrings("--absolute-git-dir", argv[2]);
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: FAIL／コンパイルエラー `undefined symbol 'gitDirArgv'`

- [ ] **Step 3: 最小実装を書く**

`src/git/commands.zig` の `applyPatchArgv` 関数の直後（高レベル関数郡の前）に追加:

```zig
/// `["git", "rev-parse", "--absolute-git-dir"]` を生成（純粋・呼出側 free）。
/// worktree / submodule でも実 git-dir へ解決するため apply_patch の書込先特定に使う。
pub fn gitDirArgv(a: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "rev-parse", "--absolute-git-dir" });
    return list.toOwnedSlice(a);
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（全テスト green）

- [ ] **Step 5: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/git/commands.zig && git commit -m "feat(git): add gitDirArgv for absolute git-dir resolution

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 2: `gitDir` 副作用関数の TDD（commands.zig）

**Files:**
- Modify: `src/git/commands.zig`（`repoRoot` の直後に高レベル関数を追加）
- Test: 同ファイル末尾の `test { std.testing.refAllDecls(@This()); }` が型検査を担う（実行系テストは appcmd.zig の結合テストで担保）

- [ ] **Step 1: 実装を書く**

`src/git/commands.zig` の `repoRoot` 関数の直後に追加（`repoRoot` と同型: `process.run` → exit_code 判定 → stdout の dup）:

```zig
/// cwd を起点に絶対 git-dir パスを返す（worktree/submodule の .git ファイルも解決）。
/// 失敗（非リポジトリ・exit!=0）は null、spawn 失敗は RunError 伝播（repoRoot と同型）。
/// 呼出側が free（成功時のみ確保）。
pub fn gitDir(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !?[]u8 {
    const argv = try gitDirArgv(a);
    defer a.free(argv);
    var res = try process.run(a, io, argv, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    return try a.dupe(u8, trimmed);
}
```

- [ ] **Step 2: コンパイル＆型検査を実行**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（`refAllDecls(@This())` が `gitDir` の型を検査。既存テストは全て green）

- [ ] **Step 3: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/git/commands.zig && git commit -m "feat(git): add gitDir effectful fn mirroring repoRoot

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 3: `Model.git_dir` フィールド追加（model.zig）

**Files:**
- Modify: `src/model.zig`（Model struct のフィールド定義 + init + deinit）

- [ ] **Step 1: フィールドと init にデフォルト null を追加**

`src/model.zig` の Model struct のフィールド定義で、`mouse_enabled: bool,` の直前に追加:

```zig
    git_dir: ?[]u8, // 絶対 git-dir パス。null = 解決失敗（フォールバック用）。起動時のみ設定。
```

`Model.init` の戻り値リテラルの `.mouse_enabled = true,` の直前に追加:

```zig
            .git_dir = null,
```

- [ ] **Step 2: deinit で git_dir を free**

`src/model.zig` の `pub fn deinit(self: *Model) void` の `a.free(self.repo_root);` の直後に追加:

```zig
        if (self.git_dir) |g| a.free(g);
```

- [ ] **Step 3: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（既存の `Model.init(a, "/r")` テストモデルは `git_dir = null` のまま動く）

- [ ] **Step 4: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/model.zig && git commit -m "feat(model): add git_dir field (nullable, startup-only)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 4: `AppCmd.ApplyPatch.git_dir` フィールド追加（messages.zig）

**Files:**
- Modify: `src/messages.zig`（`ApplyPatch` struct 定義 + `AppCmd.deinit` の `.apply_patch` arm）

- [ ] **Step 1: ApplyPatch struct に git_dir を追加（デフォルト null 必須）**

`src/messages.zig` の `pub const ApplyPatch = struct { patch: []u8, reverse: bool };` を以下に置換:

```zig
    /// 部分ステージング: 単一ハンクのパッチ（所有）と適用方向。
    /// reverse=false: stage（git apply --cached）。reverse=true: unstage（--reverse）。
    /// git_dir: 絶対 git-dir（worktree/submodule 対応）。null = フォールバック（cwd 相対 .git/...）。
    /// デフォルト null 必須: 既存の8箇所の `.{ .patch=..., .reverse=... }` リテラル呼出を壊さないため。
    pub const ApplyPatch = struct { patch: []u8, reverse: bool, git_dir: ?[]const u8 = null };
```

- [ ] **Step 2: AppCmd.deinit の apply_patch arm で git_dir を free**

`src/messages.zig` の `AppCmd.deinit` 内の `.apply_patch => |ap| a.free(ap.patch),` を以下に置換:

```zig
            .apply_patch => |ap| {
                a.free(ap.patch);
                if (ap.git_dir) |g| a.free(g);
            },
```

- [ ] **Step 3: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（`git_dir` デフォルト null により、既存8箇所のリテラル呼出は変更なしでコンパイル＆green）

- [ ] **Step 4: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/messages.zig && git commit -m "feat(messages): add git_dir to ApplyPatch (default null)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 5: `update.stage_lines` で git_dir を dupe（update.zig）

**Files:**
- Modify: `src/update.zig`（`stage_lines` arm 内の `if (maybe) |patch|` ブロック）

- [ ] **Step 1: stage_lines の apply_patch 構築を errdefer 二重ガード付きで更新**

`src/update.zig` の `stage_lines` arm 内の `if (maybe) |patch| { ... }` ブロックを見つけ、
以下に置換（レビュー B2: `patch` の OOM リークを errdefer で保護）:

```zig
            if (maybe) |patch| {
                // ★レビュー B2: buildLinePatch 所有の patch を git_dir dupe OOM で漏らさないよう
                //   errdefer 二重ガード。両 dupe 成功後に AppCmd リテラルへ所有権移譲。
                errdefer model.allocator.free(patch);
                const gd: ?[]u8 = if (model.git_dir) |g| try model.allocator.dupe(u8, g) else null;
                errdefer if (gd) |x| model.allocator.free(x);
                return .{ .apply_patch = .{
                    .patch = patch,
                    .reverse = (f.section == .staged),
                    .git_dir = gd,
                } };
            }
```

- [ ] **Step 2: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（`model.git_dir` はテストでは null のままのため `gd = null`、既存の `stage_lines` テストは不変）

- [ ] **Step 3: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/update.zig && git commit -m "feat(update): stage_lines dupes git_dir with errdefer guards

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 6: `appcmd.apply_patch` の 2 経路分岐（appcmd.zig）

**Files:**
- Modify: `src/appcmd.zig`（`.apply_patch => |ap|` arm の本体を 2 経路に再構成）

- [ ] **Step 1: apply_patch arm を git_dir 有無で 2 経路に分岐**

`src/appcmd.zig` の `switch (cmd)` 内の `.apply_patch => |ap| { ... }` arm を見つけ（現在は cwd 相対のみ）、
以下に**完全に置換**（`ap.git_dir` の有無で絶対パス経路とフォールバック経路に分岐し、status 再読込は共通末尾へ）:

```zig
        .apply_patch => |ap| {
            // git_dir 有無で 2 経路。成功/失敗に関わらず temp を削除してから status を読む。
            // bare repo では apply --cached 自体が意味を持たないが本 TUI 対象外（コメントのみ）。
            if (ap.git_dir) |git_dir| {
                // 絶対パス経路: worktree / submodule / 通常の全ケース対応。
                const tmp_abs = try std.fmt.allocPrint(a, "{s}/git-tui-stage.patch", .{git_dir});
                defer a.free(tmp_abs);
                var dir = try std.Io.Dir.openDirAbsolute(io, git_dir, .{});
                defer dir.close(io);
                try dir.writeFile(io, .{ .sub_path = "git-tui-stage.patch", .data = ap.patch });
                errdefer dir.deleteFile(io, "git-tui-stage.patch") catch {};
                const argv = try cmds.applyPatchArgv(a, ap.reverse, tmp_abs);
                defer a.free(argv);
                var res = try process.run(a, io, argv, cwd);
                defer res.deinit(a);
                dir.deleteFile(io, "git-tui-stage.patch") catch {};
                if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            } else {
                // フォールバック: 従来の cwd 相対 .git/git-tui-stage.patch（既存テスト・通常リポジトリ）。
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
                const rel = ".git/git-tui-stage.patch";
                try base.writeFile(io, .{ .sub_path = rel, .data = ap.patch });
                errdefer base.deleteFile(io, rel) catch {};
                const argv = try cmds.applyPatchArgv(a, ap.reverse, rel);
                defer a.free(argv);
                var res = try process.run(a, io, argv, cwd);
                defer res.deinit(a);
                base.deleteFile(io, rel) catch {};
                if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            }
            // 共通: status 再読込。
            var sres = try cmds.statusRaw(a, io, cwd);
            defer sres.deinit(a);
            if (sres.exit_code != 0) return .{ .git_error = try a.dupe(u8, sres.stderr) };
            return .{ .status_loaded = try statusmod.parse(a, sres.stdout) };
        },
```

- [ ] **Step 2: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（既存6件の apply_patch テストは `git_dir = null` でフォールバック経路へ。assertion 変更不要）

- [ ] **Step 3: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/appcmd.zig && git commit -m "feat(appcmd): apply_patch supports absolute git-dir + fallback

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 7: main.zig 起動時の gitDir 呼出（main.zig）

**Files:**
- Modify: `src/main.zig`（`main()` の `errdefer if (!handed_off) g_app.model.deinit();` の直後、`seedInitialStatus(&g_app)` の前）

- [ ] **Step 1: errdefer インストール直後に gitDir 解決を追加**

`src/main.zig` の `main()` 内で、`var handed_off = false;` と `errdefer if (!handed_off) g_app.model.deinit();`
の**直後**（`seedInitialStatus(&g_app);` の前）に追加。

**★重要（レビュー B1）**: `m.git_dir` ではなく **`g_app.model.git_dir`** を設定すること。
`main.zig:419-423` の不変条件「`Model.init` 成功から `g_app` ハンドオフの間に `try` を挟まない」
を守るため、`errdefer` インストール後のこの位置で `g_app.model.git_dir` に対して dupe する。
OOM 時は errdefer が `g_app.model.deinit()` を発動し、`g_app.model.repo_root` 等も含めて
正しく解放される（`m` を触らない＝stale エイリアス問題を回避）。

```zig
    // git-dir 解決（worktree/submodule の .git ファイルも解決）。失敗は null へ退化し appcmd の
    // フォールバック経路（cwd 相対 .git/...）へ。起動クラッシュしない（branchName と同型）。
    // ★レビュー B1: cmds.gitDir は repoRoot/branchName と同型=caller owned の []u8 を返す。
    //   dupe 後に必ず free すること（main.zig の branchName パターンどおり）。
    //   ★配置位置（レビュー B1）: `g_app` ハンドオフ後かつ上記 errdefer インストール後。
    //   これより前（m に対する try）は main.zig:419-423 の no-try 不変条件に違反し OOM で m がリークする。
    if (cmds.gitDir(gpa, io, cwd_root)) |maybe_gd| {
        if (maybe_gd) |g| {
            defer gpa.free(g); // ★ gitDir 戻り値は caller owned
            g_app.model.git_dir = try g_app.model.allocator.dupe(u8, g);
        }
        // maybe_gd == null（非リポジトリ等）は何もしない（git_dir は null のまま）
    } else |_| {} // RunError（spawn 失敗等）も握りつぶす
```

注意: `g_app.model.git_dir = try ...` の OOM は上の `errdefer if (!handed_off) g_app.model.deinit();` 
で捕捉される（`g_app.model` の全フィールドが解放される）。`cwd_root` は `g_app` ハンドオフの前の
`const cwd_root: Cwd = .{ .path = m.repo_root };` で定義済みで、ハンドオフ後も `m.repo_root` と
`g_app.model.repo_root` は同一ヒープを指すため、`cwd_root` をそのまま使える。

- [ ] **Step 2: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（main.zig はテストから参照されないため型検査のみ。既存テストは全て green）

- [ ] **Step 3: バイナリがビルドできることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build 2>&1 | tail -10`
Expected: ビルド成功（exit 0）、`zig-out/bin/git-tui` が生成される

- [ ] **Step 4: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/main.zig && git commit -m "feat(main): resolve git-dir at startup with fallback on failure

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 8: linked worktree + submodule 結合テスト（appcmd.zig）

**Files:**
- Modify: `src/appcmd.zig`（既存の `test "apply_patch (line unstage reverse)..."` の直後に結合テストを追加）

- [ ] **Step 1: linked worktree 結合テストを書く**

`src/appcmd.zig` の末尾の既存 apply_patch テスト群の直後に追加。`git worktree add` は HEAD を要求するため
初回 commit を入れる。**オプション順序に注意（レビュー B3）**: `git worktree add -q -b <branch> <path>` 
（`-b` をパスの前に置く。`-q <path> -b <branch>` だと git が `-b` を path 引数の後に来るオプションとして
誤解析する場合がある）。

```zig
test "apply_patch with git_dir works in a linked worktree" {
    // spec §2 結合テスト: linked worktree で .git がファイルでも git_dir 経路で apply が成功する。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // worktree add は HEAD を要求するため初回 commit を入れる。
    try repo.writeFile(io, "f.txt", "1\n2\n3\n4\n5\n");
    try repo.git(a, io, &.{ "git", "add", "f.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });

    // 副ワークツリーを repo 配下の worktree-tmp へ作る。
    // ★オプション順序（レビュー B3）: -q -b <branch> <path> の順（path の後に -b を置かない）。
    try repo.git(a, io, &.{ "git", "worktree", "add", "-q", "-b", "wt", "worktree-tmp" });

    // 副ワークツリーを開く。.git はファイル（gitdir ポインタ）のはず。
    var wt = try repo.dir.dir.openDir(io, "worktree-tmp", .{});
    defer wt.close(io);
    const wt_cwd: Cwd = .{ .dir = wt };

    // --absolute-git-dir で実 git-dir を解決（.git ファイルを透過して repo/.git/worktrees/wt へ）。
    const maybe_gd = try cmds.gitDir(a, io, wt_cwd);
    try std.testing.expect(maybe_gd != null);
    const gd = maybe_gd.?;
    defer a.free(gd);
    try std.testing.expect(std.mem.indexOf(u8, gd, "worktrees") != null);

    // 副ワークツリーで f.txt を変更 → unstaged diff を取得。
    try wt.writeFile(io, .{ .sub_path = "f.txt", .data = "1x\n2\n3\n4\n5\n" });
    var dmsg = try runOwned(a, io, wt_cwd, .{ .load_diff = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    const patch = try hunk.buildPatch(a, parsed, 0);

    // git_dir != null で apply_patch を実行（絶対パス経路）。
    var msg = try runOwned(a, io, wt_cwd, .{ .apply_patch = .{ .patch = patch, .reverse = false, .git_dir = try a.dupe(u8, gd) } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    // index に入ったことを確認。
    var has_staged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "f.txt") and e.section == .staged) has_staged = true;
    }
    try std.testing.expect(has_staged);
}
```

- [ ] **Step 2: テストを実行して通過を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -30`
Expected: PASS（worktree で apply が成功し staged エントリが返る）

- [ ] **Step 3: 本物の submodule 結合テストを書く**

worktree テストの直後に追加。**レビュー B2 対策**: 通常リポジトリではなく**本物の submodule** 
（`.git` がファイルで `gitdir: ../.git/modules/<name>` を指す）を作る。`git submodule add` は
ローカルパスだと `protocol.file.allow` 制限（git 2.38+ 既定）に掛かるため `-c protocol.file.allow=always` で回避:

```zig
test "apply_patch with git_dir works in a real submodule" {
    // spec §2 結合テスト: 本物の submodule（.git ファイル=相対 gitdir:）で git_dir 経路が動く。
    // ★レビュー B2: 通常リポジトリではなく実際の submodule を作る。submodule の .git は
    //   `gitdir: ../.git/modules/<name>` の相対形式（worktree とは別経路）であり、
    //   --absolute-git-dir がこれを実ディレクトリへ解決することを検証する。
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");

    // superproject 用 tmp リポジトリ（初回 commit 済み＝submodule add の前提）。
    var super = try TmpRepo.init(a, io);
    defer super.deinit();
    try super.writeFile(io, "root.txt", "x\n");
    try super.git(a, io, &.{ "git", "add", "root.txt" });
    try super.git(a, io, &.{ "git", "commit", "-q", "-m", "init" });

    // submodule 用独立 tmp リポジトリ（初回 commit 済み＝add 可能にするため）。
    var sub_repo = try TmpRepo.init(a, io);
    defer sub_repo.deinit();
    try sub_repo.writeFile(io, "sub.txt", "1\n2\n3\n");
    try sub_repo.git(a, io, &.{ "git", "add", "sub.txt" });
    try sub_repo.git(a, io, &.{ "git", "commit", "-q", "-m", "sub init" });

    // super へ sub_repo を submodule として追加。
    // ★protocol.file.allow=always 必須（git 2.38+ は file:// を既定で拒否）。
    //   sub_repo の絶対パスは tmpDir の内部パスを取る必要があるが、TmpRepo.dir.dir は
    //   tmpDir の sub_path を隠すため、ここでは super 内の相対パス経由では追加できない。
    //   代わりに sub_repo の絶対パスを std.Io.Dir.realpath で得て渡す。
    var sub_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sub_abs = sub_repo.dir.dir.realpath(io, ".", &sub_abs_buf) catch return;
    try super.git(a, io, &.{ "git", "-c", "protocol.file.allow=always", "submodule", "add", sub_abs, "sub" });
    // submodule 作業ツリー内のファイルを commit して super 側へ反映。
    try super.git(a, io, &.{ "git", "commit", "-q", "-m", "add sub" });

    // super/sub を開く。.git はファイルのはず（`gitdir: ../.git/modules/sub`）。
    var sub_wt = try super.dir.dir.openDir(io, "sub", .{});
    defer sub_wt.close(io);
    const sub_cwd: Cwd = .{ .dir = sub_wt };

    // --absolute-git-dir で実 git-dir を解決（相対 gitdir: を透過して super/.git/modules/sub へ）。
    const maybe_gd = try cmds.gitDir(a, io, sub_cwd);
    try std.testing.expect(maybe_gd != null);
    const gd = maybe_gd.?;
    defer a.free(gd);
    // gd は .git/modules/sub を指す実ディレクトリであること（worktree とは別経路の検証）。
    try std.testing.expect(std.mem.indexOf(u8, gd, "modules") != null);

    // submodule 内で sub.txt を変更 → unstaged diff を取得。
    try sub_wt.writeFile(io, .{ .sub_path = "sub.txt", .data = "1x\n2\n3\n" });
    var dmsg = try runOwned(a, io, sub_cwd, .{ .load_diff = .{ .path = try a.dupe(u8, "sub.txt"), .orig_path = null, .section = .unstaged } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    const patch = try hunk.buildPatch(a, parsed, 0);

    // git_dir != null で apply_patch を実行（絶対パス経路）。
    var msg = try runOwned(a, io, sub_cwd, .{ .apply_patch = .{ .patch = patch, .reverse = false, .git_dir = try a.dupe(u8, gd) } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    // index に入ったことを確認。
    var has_staged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "sub.txt") and e.section == .staged) has_staged = true;
    }
    try std.testing.expect(has_staged);
}
```

注意: `sub_repo.dir.dir.realpath(io, ".", &sub_abs_buf)` は `std.Io.Dir` の API（api-notes で確認）。
`std.fs.max_path_bytes` はパス長上限の定数。実装時に `zig build test` が通ることを確認し、
`realpath` のシグネチャが異なる場合は api-notes を再確認して調整すること。

- [ ] **Step 4: テストを実行して通過を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -30`
Expected: PASS（両テスト green、リーク検出無し）

- [ ] **Step 5: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/appcmd.zig && git commit -m "test(appcmd): apply_patch via git_dir in real worktree + submodule

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## 制約 4: diff_scroll の行数クランプ根治

### Task 9: `diffLineCount` 純粋関数の TDD（update.zig）

**Files:**
- Modify: `src/update.zig`（`clampCursor` 等のプライベートヘルパ郡の近くに追加 + テスト）

- [ ] **Step 1: 失敗テストを書く**

`src/update.zig` の `fn clampCursor` 関数の定義の直前（または他のプライベートヘルパの近く）に追加:

```zig
test "diffLineCount counts splitScalar tokens (trailing newline yields extra empty)" {
    // 空文字列: splitScalar は空トークン1つを返す。Task10 の no-op テストが依存する挙動。
    try std.testing.expectEqual(@as(usize, 1), diffLineCount(""));
    // "a\nb\nc\n": splitScalar は a, b, c, "" の4トークン。
    try std.testing.expectEqual(@as(usize, 4), diffLineCount("a\nb\nc\n"));
    // "a\nb\nc": 末尾改行無し → 3 トークン。
    try std.testing.expectEqual(@as(usize, 3), diffLineCount("a\nb\nc"));
    // 単一行: 1 トークン。
    try std.testing.expectEqual(@as(usize, 1), diffLineCount("(no diff)"));
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: FAIL／コンパイルエラー `undefined symbol 'diffLineCount'`

- [ ] **Step 3: 最小実装を書く**

`src/update.zig` のプライベートヘルパ郡（`fn clampCursor` や `fn isBodyLine` 等）の近くに追加:

```zig
/// diff_text の行数を数える純粋関数。
/// ★MUST match view.zig renderDiff total_lines counting: 両サイトの同期が崩れると
///   表示とスクロール上限がズレて制約4と同種のバグが再発する。変更時は両方直すこと。
/// splitScalar は trailing newline があれば空トークンを1つ追加するため、
/// 例えば "a\nb\nc\n" は4トークン（"a","b","c",""）を返す。view.zig も同じ計算なので一致する。
fn diffLineCount(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| n += 1;
    return n;
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/update.zig && git commit -m "feat(update): add diffLineCount pure helper matching renderDiff

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 10: `scroll_diff_down` に行数クランプを追加（update.zig）

**Files:**
- Modify: `src/update.zig`（`.scroll_diff_down` arm）

- [ ] **Step 1: scroll_diff_down arm を行数クランプ付きに更新**

`src/update.zig` の `.scroll_diff_down => { model.diff_scroll += 1; return .none; },` を以下に置換:

```zig
        .scroll_diff_down => {
            // ★制約4根治: diff_text 行数でクランプ。splitScalar は空でも1トークンを返すため
            //   total==0 は到達不能だが、diffLineCount が将来 trailing 空を除外すると total==0 に
            //   なり得る。前方防御的に残す（到達不能でも total-1 の underflow を防ぐ）。
            const total = diffLineCount(model.diff_text);
            if (total == 0) return .none;
            if (model.diff_scroll < total - 1) model.diff_scroll += 1;
            return .none;
        },
```

- [ ] **Step 2: 既存の scroll_diff テストを更新（diff_text をセット）**

`src/update.zig` の `test "scroll_diff adjusts offset and clamps at zero"` を見つけ、
`var m = try Model.init(a, "/r");` の直後に `diff_text` セットを追加（空 diff_text は新しいロジックで no-op になるため）:

```zig
test "scroll_diff adjusts offset and clamps at zero" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setStr(&m.diff_text, "a\nb\nc\n"); // 4トークン（trailing 含む）→ cap 3。+=1 が従来どおり起きる。
    var c1 = try update(&m, .scroll_diff_down);
    c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.diff_scroll);
    var c2 = try update(&m, .scroll_diff_up);
    c2.deinit(a);
    var c3 = try update(&m, .scroll_diff_up);
    c3.deinit(a); // 0 で止まる
    try std.testing.expectEqual(@as(usize, 0), m.diff_scroll);
}
```

- [ ] **Step 3: 新規テスト（cap 到達・空 no-op）を追加**

`test "scroll_diff adjusts offset and clamps at zero"` の直後に追加:

```zig
test "scroll_diff_down stops at diffLineCount(text) - 1 (constraint 4 root fix)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 4トークン（a,b,c,""）→ cap 3。5回叩いても 3 で止まる。
    try m.setStr(&m.diff_text, "a\nb\nc\n");
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var c = try update(&m, .scroll_diff_down);
        c.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), m.diff_scroll);
}

test "scroll_diff_down on empty diff_text is no-op (no underflow)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // diff_text 未設定（空文字列=1トークン）→ cap 0。+=1 は起きない。
    var c = try update(&m, .scroll_diff_down);
    c.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), m.diff_scroll);
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（更新した既存テスト + 新規2テスト green）

- [ ] **Step 5: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/update.zig && git commit -m "fix(update): clamp scroll_diff_down at diffLineCount (constraint 4)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 11: assert テスト追加（update.zig・存在する場合）

この Task は spec N2（任意推奨）の補強。`renderDiff` の `clampScroll` cap と `diffLineCount` の cap が一致することを検証するが、両者は異なるファイルのため直接の等価テストは困難。代わりに、既存の `view.clampScroll` テストと `update.diffLineCount` テストが**同じ入力で同じ cap を返す**ことを確認する。既存 `view.zig` の `clampScroll` テストが既に cap = total-1 を検証済みであり、`diffLineCount` テストも total を検証済み。両者が同一の `splitScalar` 計算を使うことをコメントで担保した（Task 9 Step 3）ため、**この Task は省略可能**。

**省略する理由（レビュー N2）**: `update.zig` から `view.zig` を import して直接の等価アサーションを書くと、Elm 風の純粋層（update）と UI 層（view）のレイヤー分離に違反する（現在 update.zig は view.zig を import していない）。コメントによる同期担保（Task 9 Step 3 の `★MUST match` コメント）で十分と判断。実装時に迷った場合はスキップしてよい。

---

### Task 12: stale コメントの更新（input.zig + view.zig）

**Files:**
- Modify: `src/input.zig`（`fromZigzagMouse` 内の `diff_line` 計算コメント）
- Modify: `src/view.zig`（`renderDiff` の doc コメント 2 箇所）

- [ ] **Step 1: input.zig の stale コメントを更新**

`src/input.zig` の `fromZigzagMouse` 内の `const diff_line: ?usize = ...` の直前のコメントを見つけ、
`// focus!=.diff での Ctrl+d/u 多用で行数超になった場合のクリックは範囲外 no-op（phase 1 許容の既知 seam）。`
を含むコメントブロックを以下に置換:

```zig
    // diff ペイン内クリックなら、ペイン相対行に diff_scroll を足した絶対 diff 行を作る。
    // focus==.diff のフレームでは renderDiff が選択ハンクを画面内に保つよう diff_scroll を調整する
    // ため diff_scroll はハンク範囲内に収まり、表示先頭行 == diff_scroll でクリックが描画と一致する。
    // focus!=.diff でも update.scroll_diff_down が diffLineCount でクランプするため（制約4解消）、
    // diff_scroll は diff_text 行数を超えず、クリックの diff_line は常に範囲内。
    const diff_line: ?usize = if (on_diff)
        model.diff_scroll + @as(usize, ev.y - layout.diff.y)
    else
        null;
```

- [ ] **Step 2: view.zig の renderDiff doc コメントを更新**

`src/view.zig` の `fn renderDiff` の直前の doc コメントを見つけ、
`/// focus==.diff のとき選択ハンクの @@ ヘッダ行を反転＋マーカー強調し、選択ハンクが画面`
`/// 掛かるよう model.diff_scroll を調整する（diff_scroll の唯一 writer）。`
を以下に置換（制約4解消で update も writer になったため）:

```zig
/// Diff ペイン: `model.diff_text` を `model.diff_scroll` を先頭行として描画。`+`/`-` を色分け。
/// focus==.diff のとき選択ハンクの @@ ヘッダ行を反転＋マーカー強調し、選択ハンクが画面
/// 掛かるよう model.diff_scroll を調整する（diff_scroll の writer は2箇所:
/// update.scroll_diff_down/up の行数クランプと、focus==.diff 時の renderDiff の ensureVisible）。
fn renderDiff(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
```

- [ ] **Step 3: renderDiff 内の「唯一 writer」コメントも更新**

`src/view.zig` の `renderDiff` 内の `// focus==.diff のときカーソル行を可視範囲に収める（diff_scroll の唯一 writer）。`
を含むコメントを見つけ、以下に置換:

```zig
    // focus==.diff のときカーソル行を可視範囲に収める（diff_scroll writer のうち renderDiff 側。
    // もう一方は update.scroll_diff_down/up の行数クランプ。ensureVisible はカーソルが窓の外なら
    // scroll を最小限ずらす（マウス当たり判定と一致）。
```

- [ ] **Step 4: コンパイル＆テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（コメントのみの変更のため全テスト green）

- [ ] **Step 5: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/input.zig src/view.zig && git commit -m "docs: update stale diff_scroll writer comments (constraint 4 resolved)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## 制約 5: MouseEvent リテラルの factoring

### Task 13: MouseEvent.kind にデフォルト追加（input.zig）

**Files:**
- Modify: `src/input.zig`（`MouseEvent` struct 定義）

- [ ] **Step 1: MouseEvent.kind にデフォルト .ignore を追加**

`src/input.zig` の `pub const MouseEvent = struct {` の直後の `kind` フィールドを見つけ、
現在の `kind: enum { left_click, left_double, wheel_up, wheel_down, ignore },` を以下に置換:

```zig
    /// `ignore` = アクション無し（reducer に渡さない）。zigzag は mouse mode 1003 で
    /// press/release/drag/move を全部報告するため（zig-pkg .../terminal.zig:336 が
    /// "\x1b[?1003h\x1b[?1006h" を書く）、左クリックの release や bare motion を
    /// `left_click` に潰すと select_index/set_focus が誤爆する。これらは `ignore` にする。
    /// デフォルト .ignore 必須（制約5: base リテラルが kind 省略で組めるようにするため）。
    kind: enum { left_click, left_double, wheel_up, wheel_down, ignore } = .ignore,
```

- [ ] **Step 2: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（既存の MouseEvent リテラルは全て `.kind` を明示しているため、デフォルト追加は影響しない）

- [ ] **Step 3: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/input.zig && git commit -m "refactor(input): add default .ignore to MouseEvent.kind

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 14: fromZigzagMouse の base factoring（input.zig）

**Files:**
- Modify: `src/input.zig`（`fromZigzagMouse` 関数の return switch ブロック）

- [ ] **Step 1: fromZigzagMouse の return switch を base 構築に factoring**

`src/input.zig` の `fromZigzagMouse` 関数の return 文を見つけ（現在は 5 つの分岐で各フィールドを
リテラル再記述）、`return switch (ev.button) { ... };` ブロック全体を以下に置換:

```zig
    // 共通ベースを一度組む。kind は全分岐で上書きされるためデフォルト .ignore は漏れない（制約5）。
    const base = MouseEvent{
        .pane = pane,
        .file_row = file_row,
        .on_diff = on_diff,
        .diff_line = diff_line,
        // .kind は MouseEvent.kind のデフォルト .ignore を使う（各分岐で必ず上書き）
    };
    return switch (ev.button) {
        // ホイールは event_type に関係なく honor する（SGR では wheel も press 扱いで来る）。
        .wheel_up => blk: {
            var m = base;
            m.kind = .wheel_up;
            break :blk m;
        },
        .wheel_down => blk: {
            var m = base;
            m.kind = .wheel_down;
            break :blk m;
        },
        .left => blk: {
            // press のみ click/double として扱う。release/drag/move は `ignore`（select_index/set_focus を誤爆させない）。
            // mode 1003 では単一の物理クリックでも press と release が来るため、両方を click にすると 2 回選択される。
            if (ev.event_type != .press) {
                var m = base;
                m.kind = .ignore;
                break :blk m;
            }
            const kind: @FieldType(MouseEvent, "kind") = switch (classifyClick(cs, now_ms, file_row)) {
                .double => .left_double,
                .single => .left_click,
            };
            var m = base;
            m.kind = kind;
            break :blk m;
        },
        // 中/右/wheel_left/wheel_right/button_8..11/none と bare motion は何もしない。
        else => blk: {
            var m = base;
            m.kind = .ignore;
            break :blk m;
        },
    };
```

- [ ] **Step 2: コンパイル＆既存テストが通ることを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（純粋リファクタ・振る舞い不変のため既存の全 behavioral テストが green）

- [ ] **Step 3: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/input.zig && git commit -m "refactor(input): factor MouseEvent base in fromZigzagMouse (constraint 5)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

### Task 15: base 伝播 invariant テスト追加（input.zig）

**Files:**
- Modify: `src/input.zig`（既存の `fromZigzagMouse` テスト郡の末尾）

- [ ] **Step 1: base 伝播 invariant テストを書く**

`src/input.zig` の既存の `fromZigzagMouse` テスト郡の末尾（`test "fromZigzagMouse: wheel_over diff pane scrolls down"` 等の直後、`// zigzag 依存の pub 関数...` の `test { std.testing.refAllDecls(@This()); }` の前）に追加:

```zig
test "fromZigzagMouse: base fields propagate to all branches (factoring invariant)" {
    // 制約5の factoring 不変条件: ignore 系分岐（右クリック等）でも base フィールドが伝播することを検証。
    // これが壊れると将来のフィールド追加で特定分岐だけ取り残される（本制約の再発）。
    var m = try buildMouseTestModel(std.testing.allocator);
    defer m.deinit();
    var scratch: [16]view.ChangesRow = undefined;
    var cs = ClickState{};
    m.diff_scroll = 2; // diff_line 計算に影響するようオフセットを設定
    // diff ペイン上で右クリック（else 分岐 = ignore）。kind は ignore だが、
    // pane/on_diff/diff_line は base から伝播しているはず。
    const ev = zz.MouseEvent{ .x = 50, .y = 2, .button = .right, .event_type = .press };
    const me = fromZigzagMouse(ev, &m, mouse_test_layout, &cs, 1000, &scratch);
    try std.testing.expectEqual(@as(@FieldType(MouseEvent, "kind"), .ignore), me.kind);
    try std.testing.expectEqual(Focus.diff, me.pane.?); // base から伝播
    try std.testing.expect(me.on_diff); // base から伝播
    try std.testing.expectEqual(@as(usize, 4), me.diff_line.?); // 2 + 2 = 4（base から伝播）
}
```

注意: `buildMouseTestModel` と `mouse_test_layout` は `input.zig` 内の既存テストヘルパ。テスト追加前に
`grep -n "buildMouseTestModel\|mouse_test_layout" src/input.zig` で存在を確認すること。
`Focus` は `@import("model.zig").Focus` で既に import 済み。

- [ ] **Step 2: テストを実行して通過を確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -20`
Expected: PASS（新規テスト green、既存テストも全て green）

- [ ] **Step 3: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add src/input.zig && git commit -m "test(input): pin MouseEvent base propagation invariant

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## 仕上げ: TODO.md 更新

### Task 16: TODO.md の制約3-5を解消済みに更新

**Files:**
- Modify: `TODO.md`（「phase 1 の既知の制約（phase 2 で対応）」セクション）

- [ ] **Step 1: 解消した3項目を更新**

`TODO.md` の「phase 1 の既知の制約（phase 2 で対応）」セクションを見つけ、3つの制約バレットを
解消済みとして書き換え。各項目の先頭に `[x]` マーカ（または解消文言）を付け、1行で対応内容をメモ:

対象3項目（現在の記述）:
```
  - 一時パッチを `<repo_root>/.git/` に書くため、linked worktree / submodule（`.git` がファイル）ではハンク stage が失敗する。実 git-dir 解決（`git rev-parse --absolute-git-dir`）またはシステム tmpdir 絶対パス書込で対応予定。
  - `focus!=.diff`（changes フォーカス）で `Ctrl+d/u` を多用すると `diff_scroll` が diff 行数を超え得る。その状態の diff ペインクリックは範囲外で no-op（誤選択にはならない）。根治は reducer の `scroll_diff_down` で diff 行数クランプ。
  - `input.fromZigzagMouse` の戻り値 MouseEvent リテラルが分岐ごとに重複しており、フィールド追加時に漏れやすい。ベースを 1 度組んで `.kind` だけ差し替える factoring を検討。
```

これらを以下に置換（`[x]` マーカと解消メモ付き）:

```
  - [x] ~~一時パッチを `<repo_root>/.git/` に書くため、linked worktree / submodule ではハンク stage が失敗する。~~
    **解消**（2026-06-17）: `git rev-parse --absolute-git-dir` で絶対 git-dir を解決し `<git-dir>/git-tui-stage.patch` へ書込（`ApplyPatch.git_dir`・フォールバック付き）。
  - [x] ~~`focus!=.diff` で `Ctrl+d/u` を多用すると `diff_scroll` が diff 行数を超え得る。~~
    **解消**（2026-06-17）: `update.scroll_diff_down` で `diffLineCount(text)` 上限クランプ。
  - [x] ~~`input.fromZigzagMouse` の戻り値 MouseEvent リテラルが分岐ごとに重複。~~
    **解消**（2026-06-17）: `base` 構築の factoring（`MouseEvent.kind` にデフォルト `.ignore` 追加）。
```

- [ ] **Step 2: コミット**

```bash
cd /home/hatai/repos/hatai/git-tui && git add TODO.md && git commit -m "docs(todo): mark phase 1 constraints 3-5 as resolved

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## 最終検証

### Task 17: 全テスト実行 + ビルド確認

- [ ] **Step 1: 全テストを実行**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build test --summary all 2>&1 | tail -30`
Expected: PASS・リーク検出無し・全テスト green

- [ ] **Step 2: Release ビルドが成功することを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && zig build -Doptimize=ReleaseFast 2>&1 | tail -10`
Expected: ビルド成功（exit 0）

- [ ] **Step 3: git log で全コミットが積まれたことを確認**

Run: `cd /home/hatai/repos/hatai/git-tui && git log --oneline -18`
Expected: 本計画のコミットが時系列に並ぶ

- [ ] **Step 4: spec と TODO.md が整合していることを最終確認**

Run: `cd /home/hatai/repos/hatai/git-tui && grep -c "解消" TODO.md`
Expected: 3 以上（制約3-5の3項目が全て「解消」表記）

---

## 受け入れ基準（spec §2/§3/§4 の全項目）

制約3:
1. ✓ linked worktree でハンク stage が成功し index に入る（Task 8 の worktree テスト）。
2. ✓ 本物の submodule（`.git` ファイル=`gitdir: ../.git/modules/<name>` 相対形式）で `git_dir` 経路が動き、`gd` が `.git/modules/<name>` を指す（Task 8 の submodule テスト）。
3. ✓ 通常リポジトリで既存のハンク stage 挙動が不変（既存6件の統合テストがフォールバック経路で green）。
4. ✓ `git rev-parse --absolute-git-dir` 失敗時はフォールバックへ退化（`ApplyPatch.git_dir = null` デフォルト）。

制約4:
5. ✓ `focus != .diff` で Ctrl+d 連打でも `diff_scroll` が `diff_text` 行数を超えない（Task 10 の新規テスト）。
6. ✓ diff ペインクリックの `diff_line` が範囲内に収まる（クランプ本体で担保・stale コメントも更新）。
7. ✓ 既存の scroll_diff 挙動は `diff_text` セット下で不変（Task 10 で既存テストを更新）。

制約5:
8. ✓ 既存の `fromZigzagMouse` 全 behavioral テストが変更なしで green（Task 14 の pure refactor）。
9. ✓ `MouseEvent` にフィールド追加時の変更箇所が `base` 構築の1箇所だけになる（Task 14 の構造的担保）。
10. ✓ base 伝播 invariant テストが green（Task 15）。

全体:
11. ✓ `zig build test --summary all` が green（リーク検出無し）。
12. ✓ `zig build -Doptimize=ReleaseFast` が成功。
13. ✓ TODO.md の制約3-5が解消済みとして更新される（Task 16）。
