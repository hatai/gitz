# TODO 1 既知の制約の解消（phase 1 留意点 3-5）— 設計

- 日付: 2026-06-17
- 対象: `TODO.md` TODO 1「部分ステージング」の「phase 1 の既知の制約（phase 2 で対応）」に列挙された
  下記 3 項目の解消。
  1. linked worktree / submodule でハンク stage が失敗する（一時パッチ書込先問題）
  2. changes フォーカスで `Ctrl+d/u` を多用すると `diff_scroll` が diff 行数を超え得る
  3. `input.fromZigzagMouse` の MouseEvent リテラルが分岐ごとに重複している
- **対象外（別タスク）**: TODO 1 の未対応機能サブタスク（untracked / rename ファイルのハンク stage）。
  本 spec は上記 3 制約の解消のみを扱う。
- 親 spec:
  - `docs/superpowers/specs/2026-06-14-git-tui-design.md`（全体アーキテクチャ）
  - `docs/superpowers/specs/2026-06-15-partial-staging-hunk-design.md`（phase 1: apply_patch の導入）
  - `docs/superpowers/specs/2026-06-16-line-staging-design.md`（行単位: diff_cursor/anchor）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（食い違う場合はノート優先）

## 1. スコープと前提

3 つの制約は互いに**独立**（依存関係なし）。同じファイル `update.zig` / `appcmd.zig` に触れるが、
変更箇所は分離しており、実装・テストも各制約ごとに完結する。実装順は制約 3 → 4 → 5（純粋層 → 配線の順、
影響範囲の大きい順）。3 制約とも既存テスト（通常リポジトリ・通常 diff）を**変更なしで green 保持**する
ことをフォールバック方針とする。

### 共通の前提（既存コードから確認済み）

- `appcmd.zig` の `apply_patch` は cwd 相対 `.git/git-tui-stage.patch` に書込み。`Cwd` ユニオン
  （`.dir` / `.path` / `.inherit`）から `base: std.Io.Dir` を解決している。
- `view.zig` の `renderDiff` は `clampScroll(model.diff_scroll, total_lines)` で**表示時**にクランプ。
  `total_lines` は `std.mem.splitScalar(u8, diff_text, '\n')` のトークン数（後述の trailing newline に注意）。
- `view.zig` の `clampScroll` は `pub`（既存テストあり）。`ensureVisible` は `focus==.diff` のとき
  `model.diff_scroll` を唯一書き換える（diff_scroll の writer は update と renderDiff の 2 箇所）。
- `input.zig` の `MouseEvent` は純粋な struct（`kind` enum + `pane`/`file_row`/`on_diff`/`diff_line`
  のスカラ/optional フィールドのみ。ポインタ/スライス無し）。
- 既存の `apply_patch` リテラル呼出は **8 箇所**: `messages.zig` テスト 1 件 + `appcmd.zig` テスト 6 件 +
  `update.zig` の `stage_lines`（本番）。全て `.{ .apply_patch = .{ .patch = ..., .reverse = ... } }` の
  named-field 形式。

## 2. 制約 3 — worktree / submodule で apply_patch を動くようにする

### 問題

`appcmd.zig` の `.apply_patch` が cwd 相対 `const rel = ".git/git-tui-stage.patch"` に書込。
linked worktree（`git worktree add`）と submodule では `.git` が**ファイル**（`gitdir: <path>` の
ポインタ）でディレクトリが存在せず、`writeFile` が失敗する。

### 解決方針（採用: A — git-dir 解決）

起動時に `git rev-parse --absolute-git-dir` で絶対 git-dir パスを取得して Model に保持し、
`apply_patch` は `<git-dir>/git-tui-stage.patch` の**絶対パス**へ書込む。`--absolute-git-dir` は
worktree（`.git/worktrees/<name>`）、submodule（superproject の `.git/modules/<name>`）、
通常リポジトリ（`.git`）のいずれでも実ディレクトリを返すため、3 ケース全てを単一経路で扱える。

### 変更箇所

#### 2.1 `src/git/commands.zig`（純粋 + 副作用、TDD）

`repoRoot` / `hasHead` と同型の関数を 2 つ追加:

```zig
/// `["git", "rev-parse", "--absolute-git-dir"]` を生成（純粋・呼出側 free）。
pub fn gitDirArgv(a: std.mem.Allocator) ![]const []const u8

/// `git rev-parse --absolute-git-dir` を実行し、stdout を trim して返す。
/// 失敗（非リポジトリ・exit!=0）は null、spawn 失敗は RunError 伝播（repoRoot と同型）。
pub fn gitDir(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !?[]u8
```

- `gitDir` は `repoRoot`（`commands.zig` 既存）と同じ構造: `process.run` → exit_code 判定 →
  stdout の dup（trailing whitespace は `std.mem.trim` で除去）。
- `--absolute-git-dir` は末尾スラッシュ無しを保証するため、argv のパス結合は呼出側で `/` を明示挿入（後述）。

#### 2.2 `src/model.zig`（フィールド追加）

```zig
git_dir: ?[]u8, // 絶対 git-dir パス。null = 解決失敗（フォールバック用）。起動時のみ設定。
```

- **`init` シグネチャは不変**（既存テストモデル `Model.init(a, "/r")` 等が壊れないよう）。`.git_dir = null` 
  で初期化。
- **setter は `setStr` を使わない**（`setStr` は `*[]u8`（非 optional）専用で `?[]u8` にはコンパイル不可）。
  代わりに `main.zig` が直接:
  ```zig
  if (g_app.model.git_dir) |old| g_app.model.allocator.free(old);
  g_app.model.git_dir = try g_app.model.allocator.dupe(u8, g);
  ```
  と書く（起動時 1 回だけなのでヘルパ化不要）。`gitDir` が `null` を返したときは `git_dir` を触らない（`null` のまま）。
  `RunError` のときも触らない（`if ... else |_| {}` で握りつぶす）。
- `deinit`: `if (self.git_dir) |g| a.free(g);`（`repo_root` の free の直後に追加）。
- `replaceFiles` / `diff_loaded` 等では更新しない（起動時のみ設定・以降 read-only）。
- テストモデル（`Model.init(a, "/r")`）は `git_dir = null` のままで OK（既存テストはフォールバック経路）。

#### 2.3 `src/messages.zig`（AppCmd.ApplyPatch 拡張）

```zig
pub const ApplyPatch = struct {
    patch: []u8,
    reverse: bool,
    git_dir: ?[]const u8 = null, // ★デフォルト null（レビュー B1 対策: 既存8箇所の呼出を変更不要にする）
};
```

- **デフォルト `= null` 必須**（レビュー B1）: これにより既存の `.{ .apply_patch = .{ .patch = p, .reverse = r } }`
  リテラル 8 箇所が**コンパイルエラーなくそのまま動く**。
- `AppCmd.deinit` の `.apply_patch` arm を更新:
  ```zig
  .apply_patch => |ap| {
      a.free(ap.patch);
      if (ap.git_dir) |g| a.free(g); // null は解放しない
  },
  ```
- `Msg.deinit` は変更不要（`apply_patch` は `AppCmd` のバリアントで `Msg` 側には無い）。
- 所有権: `git_dir` は消費者（解釈器）が deinit で解放。reducer 側は `try model.allocator.dupe(u8, model.git_dir.?)` 
  で複製所有（CLAUDE.md「Msg/AppCmd ペイロードは Model を借用せず複製所有」に準拠）。

#### 2.4 `src/update.zig`（stage_lines のみ）

`stage_lines` が `.apply_patch` を構築する箇所で `model.git_dir` を dupe:

```zig
if (maybe) |patch| {
    // ★レビュー指摘 B2: buildLinePatch が所有する patch を、git_dir dupe の OOM で漏らさないよう
    //   errdefer で保護する（dupe 成功後に所有権を AppCmd へ移譲）。
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

- `null` も許容（フォールバック経路）。dupe しないと worker スレッドが解放時に model の文字列を指す
  stale エイリアスになる（所有権規約）。
- **errdefer 二重ガード必須**（レビュー B2）: `patch` は `buildLinePatch` から所有権移譲済みの `[]u8`。
  従来コードは `patch` 生成後に fallible な処理が無かったが、`git_dir` の dupe は OOM を投げ得るため、
  `errdefer model.allocator.free(patch)` と `errdefer if (gd) |x| ...` の 2 段で保護しないと
  `patch`（と dupe 済みの `gd`）がリークする。両 dupe が成功した時点で AppCmd リテラルへ所有権移譲。

#### 2.5 `src/appcmd.zig`（apply_patch 解釈）

`.apply_patch` arm を更新。`ap.git_dir` の有無で 2 経路に分岐:

```zig
.apply_patch => |ap| {
    if (ap.git_dir) |git_dir| {
        // 絶対パス経路（worktree / submodule / 通常の全ケース対応）
        // std.fmt.allocPrint で明示的に '/' を挿入（レビュー N2: 連結ではなく）。
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
        dir.deleteFile(io, "git-tui-stage.patch") catch {}; // status 読込前に削除
        if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
    } else {
        // フォールバック: 従来の cwd 相対 .git/git-tui-stage.patch（既存テスト・通常リポジトリ）
        // ★この経路は既存コードそのまま（既存6件の統合テストが通る本体）
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
    // 共通: status 再読込
    var sres = try cmds.statusRaw(a, io, cwd);
    defer sres.deinit(a);
    if (sres.exit_code != 0) return .{ .git_error = try a.dupe(u8, sres.stderr) };
    return .{ .status_loaded = try statusmod.parse(a, sres.stdout) };
},
```

- **絶対パス + cwd の安全性**（レビュー N3 確認済み）: `process.run` は argv を verbatim で渡し、
  cwd は相対パス解決にのみ影響。argv の絶対パス要素は cwd 非依存で git が処理する。
- **bare repo コメント**（レビュー N5）: bare repo では `--absolute-git-dir` が repo root 自身を返すが、
  `git apply --cached` 自体が worktree 無しでは意味を持たず、本 TUI の対象外。実装に 1 行コメントで明記。

#### 2.6 `src/main.zig`（起動時 1 回呼出・フォールバック）

`seedInitialStatus` の前後で `gitDir` を 1 回呼び、失敗は握りつぶして `model.git_dir = null` へ退化
（レビュー N1: `branchName` の既存パターン `if (...) |bn| {...} else |_| {}` と同型）:

```zig
// 起動時 1 回のみ。失敗（非リポジトリ・spawn エラー）は null へ退化し、
// appcmd のフォールバック経路（cwd 相対 .git/...）へ。起動クラッシュしない。
// setStr は *[]u8 専用で ?[]u8 には使えないため直接 dupe（起動時 1 回だけなのでヘルパ化不要）。
// ★レビュー指摘 B1: cmds.gitDir は repoRoot/branchName と同型=caller owned の []u8 を返す。
//   branchName の既存パターン（main.zig:428 `defer gpa.free(bn)`）どおり、dupe 後に g を free すること。
//   これを忘れると成功時毎回リークし std.testing.allocator が検出する。
if (cmds.gitDir(gpa, io, cwd)) |maybe_gd| {
    if (maybe_gd) |g| {
        defer gpa.free(g); // ★ gitDir 戻り値は caller owned（branchName と同型）
        g_app.model.git_dir = try g_app.model.allocator.dupe(u8, g);
    }
    // maybe_gd == null（非リポジトリ等）は何もしない（git_dir は null のまま）
} else |_| {} // RunError（spawn 失敗等）も握りつぶす
```

- `try` ではなく `if ... else |_| {}` で `RunError` を握りつぶす。
- **`defer gpa.free(g)` 必須**（レビュー B1）: `gitDir` は `repoRoot`/`branchName` と同じく
  caller owned の `[]u8` を返す（`try a.dupe(u8, trimmed)`）。`g_app.model.allocator.dupe(u8, g)` で
  Model 側へ複製した後、`g` 自体は解放しないとリーク。`main.zig:428` の `branchName` ハンドリング
  （`defer gpa.free(bn)`）と同じ形。
- `repoRoot` が null のとき（非リポジトリ）は早期 `std.process.exit(1)` しているため、
  `gitDir` の呼出は「確認済みリポジトリ内」でのみ走る（レビュー確認事項）。
- **配置位置**（レビュー N1）: `g_app` 初期化後かつ `g_app.model.deinit()` の errdefer インストール後に
  配置（main.zig の `Model.init` → `g_app` ハンドオフ間の no-`try` 不変条件を守る）。
- `seedInitialStatus` の網羅 switch（`.none, .quit, .apply_patch => {}`）は**変更不要**（apply_patch arm は既存）。

### テスト

#### 純粋（commands.zig 内）

- `gitDirArgv` の argv 配列が `["git", "rev-parse", "--absolute-git-dir"]` であること。

#### 結合（appcmd.zig 内、`TmpRepo` パターン拡張）

- **linked worktree**（レビュー N4 推奨）: **初回 commit 済みの** TmpRepo から
  `git worktree add <tmp2> <branch>` で副 worktree を作り（worktree add は HEAD を要求するため
  TmpRepo.init 直後に空 commit を1つ入れる）、そこから `apply_patch` を `git_dir != null` で実行 →
  成功して index に入ることを `git diff --cached` で assert。
- **submodule**（レビュー N4 推奨）: submodule を作り、submodule 内で `apply_patch` を `git_dir != null` 
  で実行 → 成功を assert。**`git submodule add` はローカルパスだと `protocol.file.allow` 制限に掛かるため**
  （git 2.38+ の既定）、`git -c protocol.file.allow=always submodule add <path> <name>` で渡すか、
  `git init` + `.gitmodules` 手動登録で構築（レビュー N1/N3）。submodule の `.git` ファイルは
  `gitdir: ../.git/modules/<name>` の**相対**形式（worktree とは別経路）であり、`--absolute-git-dir` 
  が実ディレクトリへ解決することを検証。
- **フォールバック回帰**: `git_dir = null` で既存 6 件の統合テスト（`TmpRepo` + `runOwned`）が
  **一切変更なしで green** であることを確認（`ApplyPatch.git_dir` のデフォルト `= null` で成立）。

#### テストヘルパの拡張

- `runOwned` は inline `AppCmd` を deinit する既存ヘルパ。`apply_patch` リテラルに `git_dir` を
  指定するテストのみ、明示的に `.git_dir = try a.dupe(u8, <abs path>)` を渡す。
- 既存テスト（`git_dir` 省略）はデフォルト `null` でフォールバック経路へ。

### 受け入れ基準（制約 3）

1. linked worktree でハンク stage が成功し、index に入る。
2. submodule 内でハンク stage が成功し、index に入る。
3. 通常リポジトリで既存のハンク stage 挙動が不変（既存 6 件の統合テスト green）。
4. `git rev-parse --absolute-git-dir` が失敗する環境ではフォールバック（cwd 相対）へ退化し、
   通常リポジトリと同等に動く。

## 3. 制約 4 — diff_scroll の行数クランプ根治

### 問題

`update.zig` の `scroll_diff_down` が無条件 `model.diff_scroll += 1;`。上限チェックがないため、
`focus != .diff` で `Ctrl+d/u` を連打すると `diff_scroll` が diff 総行数を超え得る。

### 現状の影響（TODO 記述どおり）

- `view.zig` `renderDiff` が `clampScroll` で**表示時**にクランプするため画面は壊れない。
- `input.zig` `fromZigzagMouse` が `diff_line = model.diff_scroll + (ev.y - layout.diff.y)` で
  **クランプされていない生の `diff_scroll`** を読むため範囲外値になる。
- `select_line_at` → `clampCursor` が本文へクランプするため**誤選択にはならず** no-op に退化。
  根治は reducer 側でのクランプ（TODO 記述どおり）。

### 変更箇所

#### 3.1 `src/update.zig`（プライベート純粋ヘルパ + reducer arm）

**アプローチ: SIMPLE（新モジュール作らない）**。理由: `clampScroll` の意味論は `view` の描画文脈
（`limit` / `total_lines` の関係）に密着しており、reducer 用途（「1 進める、ただし上限まで」）とは
微妙に異なる。reducer 側は「`diff_text` の行数 `N` に対し `diff_scroll < saturating(N, -1)` の間だけ `+1`」
を直接書くほうが意図が明確。

```zig
/// diff_text の行数を数える純粋関数。
/// ★MUST match view.zig renderDiff total_lines counting（レビュー N3: 両サイトの同期が崩れると
///   表示とスクロール上限がズレて本制約と同種のバグが再発する。変更時は両方直すこと）。
/// splitScalar は trailing newline があれば空トークンを 1 つ追加するため、
/// 例えば "a\nb\nc\n" は 4 トークン（"a","b","c",""）を返す。view.zig も同じ計算なので一致する。
fn diffLineCount(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| n += 1;
    return n;
}
```

reducer arm:

```zig
.scroll_diff_down => {
    const total = diffLineCount(model.diff_text);
    // splitScalar は空文字列でも 1 トークンを返すため total==0 は到達不能だが、
    // 前方防御的に残す（diffLineCount が将来 trailing 空を除外すると total==0 になり得る）。
    if (total == 0) return .none;
    if (model.diff_scroll < total - 1) model.diff_scroll += 1;
    return .none;
},
.scroll_diff_up => {
    if (model.diff_scroll > 0) model.diff_scroll -= 1;
    return .none;
},
```

- **`total == 0` guard は実質 dead code**（レビュー N2 確認: `splitScalar` は常に >=1 トークンを返す）。
  ただし将来の `diffLineCount` 変更（trailing 空除外等）で `total==0` が起き得るため前方防御的に残し、
  コメントで「実質 dead だが forward-defensive」と明記。
- **off-by-one 整合**（レビュー N1）: `diffLineCount("a\nb\nc\n")` は **4** を返す（trailing 空 token 含む）。
  よって cap は `total - 1 = 3`。`view.zig` `renderDiff` の `total_lines` も同じ 4 を数え、
  `clampScroll` も `total - 1 = 3` で cap する。両者が**同一計算**なので表示とスクロール上限は一致する。

#### 3.2 既存テストの更新

`test "scroll_diff adjusts offset and clamps at zero"`（`update.zig` 既存）は `diff_text` 未設定
（空文字列 = total 1, cap 0）で `scroll_diff_down` 後 `m.diff_scroll == 1` を assert している。
新しいロジック（空は no-op）ではこの assert が壊れるため、**テスト側に `diff_text` を 3 行セットする**:

```zig
test "scroll_diff adjusts offset and clamps at zero" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setStr(&m.diff_text, "a\nb\nc\n"); // 4 トークン（レビュー N1）→ cap 3。従来どおり +=1 が起きる。
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

### テスト（新規、`update.zig` 内）

- `scroll_diff_down` が `diffLineCount(text) - 1` で止まる（それ以上 `+1` しない）。
  例: `diff_text = "a\nb\nc\n"`（total 4, cap 3）で `scroll_diff_down` を 5 回叩いても
  `m.diff_scroll == 3` で止まる。
- `scroll_diff_down` on empty `diff_text` は no-op（`m.diff_scroll` 不変、underflow しない）。
- `scroll_diff_up` の既存挙動（0 で止まる）は不変（回帰）。

### 二重 writer の相互作用（レビュー確認事項）

- `renderDiff` は `focus == .diff` のときだけ `model.diff_scroll = ensureVisible(...)` を書く。
- 新しい update 側クランプは `focus` に依存せず全ケースで効く（`input.zig` で `Ctrl+d/u` は
  `.changes`/`.diff` 両フォーカスで `scroll_diff_*` に写るため）。
- 元のバグは `focus != .diff` で `renderDiff` が `diff_scroll` を書かないため無上限で増えたこと。
  新しいクランプはこのケースを正しく根治する。
- `focus == .diff` では render の `ensureVisible` が勝ち（カーソル可視化）、update のクランプは
  無害な二次上限。UX を損なう競合は無い。

### 受け入れ基準（制約 4）

1. `focus != .diff` で `Ctrl+d` を連打しても `diff_scroll` が `diff_text` の行数を超えない。
2. その後の diff ペインクリックの `diff_line` が範囲内に収まる（`clampCursor` に頼らず本体で安全）。
3. 既存の `scroll_diff_*` 挙動（0 クランプ・`+=1` 自体）は `diff_text` セット下で不変。

## 4. 制約 5 — MouseEvent リテラルの factoring

### 問題

`input.zig` `fromZigzagMouse` の return switch（レビュー N5 訂正: **5 箇所**のリテラル構築）で、
`.pane`/`.file_row`/`.on_diff`/`.diff_line` の 4 フィールドが**全構築サイトでリテラル再記述**されている。
フィールド追加時に全サイト書き換えが必要で漏れやすい（TODO 記述どおり）。

### 変更箇所

#### 4.1 `src/input.zig` MouseEvent.kind にデフォルト追加（レビュー B1）

```zig
pub const MouseEvent = struct {
    kind: enum { left_click, left_double, wheel_up, wheel_down, ignore } = .ignore, // ★デフォールト追加
    pane: ?Focus = null,
    file_row: ?usize = null,
    on_diff: bool = false,
    diff_line: ?usize = null,
};
```

- `kind` に `= .ignore` デフォルトを追加。全分岐で `m.kind = ...` と上書きされるためデフォルトは漏れない。
- **必須**（レビュー B1）: これが無いと次項の `base` リテラルが `kind` フィールド不足でコンパイルエラー。

#### 4.2 `src/input.zig` fromZigzagMouse の factoring

```zig
pub fn fromZigzagMouse(...) MouseEvent {
    const on_diff = pointInRect(ev.x, ev.y, layout.diff);
    const pane: ?Focus = ...;
    const file_row: ?usize = ...;
    const diff_line: ?usize = ...;

    // 共通ベースを一度組む。kind は全分岐で上書きされるためデフォルト（.ignore）は漏れない。
    const base = MouseEvent{
        .pane = pane,
        .file_row = file_row,
        .on_diff = on_diff,
        .diff_line = diff_line,
        // .kind はデフォルト .ignore（各分岐で必ず上書き）
    };
    return switch (ev.button) {
        .wheel_up   => blk: { var m = base; m.kind = .wheel_up; break :blk m; },
        .wheel_down => blk: { var m = base; m.kind = .wheel_down; break :blk m; },
        .left => blk: {
            if (ev.event_type != .press) { var m = base; m.kind = .ignore; break :blk m; }
            const kind: @FieldType(MouseEvent, "kind") = switch (classifyClick(cs, now_ms, file_row)) {
                .double => .left_double,
                .single => .left_click,
            };
            var m = base; m.kind = kind; break :blk m;
        },
        else => blk: { var m = base; m.kind = .ignore; break :blk m; },
    };
}
```

- **5 構築サイト**（レビュー N5）: `.wheel_up` / `.wheel_down` / `.left` 内 release-drag-ignore /
  `.left` 内 press-kind / `else`。全て `base` を copy して `.kind` を差し替える形に統一。
- **copy 安全性**（レビュー確認事項）: `MouseEvent` は全フィールドがスカラ/optional（enum, ?Focus, ?usize, bool）で
  ポインタ/スライス無し。`var m = base` は bitwise copy で安全。
- **`@FieldType(MouseEvent, "kind")` は有効**（レビュー確認事項）: `input.zig:254` で既に使用済み。
- **振る舞い不変**: 既存の `fromZigzagMouse` の多数の behavioral test（press/release/drag/move/
  右・中クリック/ホイール/ダブルクリック/スクロールオフセット合算等）は全て変更なしで green。

### テスト（新規 1 件、レビュー N4 推奨）

純粋リファクタだが、factoring の**不変条件**（base フィールドが全分岐へ伝播する）を pinned する
テストを 1 件追加し、将来のリバートを検出する:

```zig
test "fromZigzagMouse: base fields propagate to all branches (factoring invariant)" {
    // ignore 系分岐（右クリック）でも base フィールドが伝播することを検証。
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

### 受け入れ基準（制約 5）

1. 既存の `fromZigzagMouse` 全 behavioral test が変更なしで green。
2. `MouseEvent` にフィールドを 1 つ追加したとき、`fromZigzagMouse` の変更箇所が `base` 構築の
   1 箇所だけになる（本 spec の目的。レビューで構造的に担保）。
3. 上記新規テスト（base 伝播 invariant）が green。

## 5. 実装順（純粋層 TDD → 配線）

3 制約は独立。影響範囲の大きい順に実装する。

1. **制約 3（git-dir 解決）**:
   1. `git/commands.zig`: `gitDirArgv`/`gitDir`（純粋 + 結合 TDD）。
   2. `model.zig`: `git_dir` フィールド・`deinit` 追加。
   3. `messages.zig`: `ApplyPatch.git_dir`（デフォルト `= null`）・`AppCmd.deinit` arm 更新。
   4. `update.zig`: `stage_lines` で `model.git_dir` を dupe。
   5. `appcmd.zig`: `apply_patch` の 2 経路分岐（絶対 / フォールバック）。
   6. `main.zig`: 起動時 1 回 `gitDir` 呼出・`catch {}` で null 許容。
   7. 結合テスト: linked worktree / submodule の 2 件追加。
2. **制約 4（diff_scroll クランプ）**:
   1. `update.zig`: `diffLineCount`（プライベート純粋）+ `scroll_diff_down` arm にクランプ。
   2. 既存テスト `scroll_diff adjusts offset...` に `diff_text` セット追加。
   3. 新規テスト: 行数 cap・空 no-op。
3. **制約 5（MouseEvent factoring）**:
   1. `input.zig`: `MouseEvent.kind` に `= .ignore` デフォルト追加。
   2. `input.zig`: `fromZigzagMouse` の base 構築化（5 サイト → 1 base + `.kind` 差替）。
   3. 新規テスト: base 伝播 invariant 1 件。

## 6. TODO.md 更新

`TODO.md` の「phase 1 の既知の制約（phase 2 で対応）」から下記 3 項目を**削除**し、
「phase 1 の既知の制約（解消済み）」セクションへ移動（または各行を `[x]` 化して 1 行メモを追記）:

- ~~一時パッチを `<repo_root>/.git/` に書くため、linked worktree / submodule ではハンク stage が失敗する。~~
  → 解消: `git rev-parse --absolute-git-dir` で絶対 git-dir を解決し、`<git-dir>/git-tui-stage.patch` へ書込。
- ~~`focus!=.diff` で `Ctrl+d/u` を多用すると `diff_scroll` が diff 行数を超え得る。~~
  → 解消: `update.scroll_diff_down` で `diffLineCount` 上限クランプ。
- ~~`input.fromZigzagMouse` の戻り値 MouseEvent リテラルが分岐ごとに重複。~~
  → 解消: `base` 構築の factoring（`kind` にデフォルト追加）。

「行単位 stage の phase 2 で未対応」セクション（飛び飛び選択・ドラッグ範囲拡張・No-newline 境界）
は本 spec の対象外のため**変更しない**。

## 6.1 既存コメントの更新（レビュー N4）

制約 4 の実装時に、関連する既存コードのコメントが stale になるため併せて更新する:

- `src/input.zig` の `fromZigzagMouse` 内 `diff_line` 計算コメント（現状: 「phase 1 許容の既知 seam」と
  範囲外クリックを許容する旨）→ 制約 4 根治後は「reducer 側で diff_scroll を行数クランプするため
  範囲外にならない」へ書き換え。
- `src/view.zig` の `renderDiff` コメント（現状: 「diff_scroll の唯一 writer」と `ensureVisible` を指す）→
  update.zig の `scroll_diff_down` も writer になったため、「writer は update（クランプ）と renderDiff
  （focus==.diff 時の ensureVisible）の 2 箇所」と訂正。

## 7. レビュー経緯（設計の妥当性裏付け）

本設計は 2 段階の subagent レビューを経て確定した:

- **制約 3**: APPROVE-WITH-NITS。ブロッカー B1（`ApplyPatch.git_dir` にデフォルト `= null` 必須）
  と N1（起動時 `catch {}`）・N2（`allocPrint` で `/` 挿入）・N4（submodule テスト追加）を反映。
  所有権・スレッド安全・フォールバック・網羅 switch は確認済み。
- **制約 4**: APPROVE-WITH-NITS。ブロッカー無し。N1（`splitScalar` の trailing token で cap は
  `total - 1 = 3`、"3 行" ではない）・N2（`total == 0` guard は実質 dead だが forward-defensive に保持）・
  N3（`diffLineCount` と `renderDiff` の同期コメント必須）を反映。二重 writer 相互作用・既存テスト更新を確認。
- **制約 5**: NEEDS-CHANGES → 修正で APPROVE。ブロッカー B1（`MouseEvent.kind` にデフォルト `= .ignore`
  必須）を反映。N4（base 伝播 invariant テスト 1 件追加）・N5（5 構築サイトの正しい数）を反映。

### 第 3 回レビュー（spec 全体: subagent + codex 並行）

spec 全体を subagent と codex CLI で並行レビューし、両者から所有権リーク指摘:

- **B1（両者共通）**: `main.zig` 起動時 `gitDir` snippet が `cmds.gitDir` の戻り値（caller owned の `[]u8`、
  `repoRoot`/`branchName` と同型）を dupe 後に free していなかった。`main.zig:428` の `branchName` 
  パターン（`defer gpa.free(bn)`）どおり `defer gpa.free(g)` を追加して反映。
- **B2（codex のみ）**: `update.zig` `stage_lines` で `buildLinePatch` 所有の `patch` を `git_dir` dupe の
  OOM で漏らす経路があった。`errdefer model.allocator.free(patch)` と `errdefer if (gd) |x| ...` の
  二重ガードを追加して反映。
- **N1（codex）**: 起動時 `gitDir` 呼出の配置位置（`g_app` 初期化後・`errdefer` インストール後）を明記。
- **N2（codex）**: linked worktree テストは初回 commit 済み前提（`worktree add` が HEAD を要求）を明記。
- **N3（両者共通）**: submodule テストは `git -c protocol.file.allow=always submodule add` を使う旨を明記。
- **N4（codex）**: 制約 4 実装時に `input.zig` と `view.zig` の stale コメントを併せて更新する§6.1 を追加。
- **N5（codex）**: typo 修正（`末尾スラッチ` → `末尾スラッシュ`）。

## 8. テスト規約（既存に従う）

- 実装と同じ `.zig` 内の `test {}` ブロック。
- `std.testing.allocator` 必須（リーク検出）。view の arena 関数は `ArenaAllocator`。
- 各ファイル `test { std.testing.refAllDecls(@This()); }`。
- 新規 `.zig` モジュールは作らない（制約 4 は `update.zig` 内プライベート関数で済ませるため）。
- 結合テスト（appcmd.zig）は既存 `TmpRepo` パターンを拡張。linked worktree / submodule 作成は
  `git worktree add` / `git submodule add` サブコマンド実行で準備。
