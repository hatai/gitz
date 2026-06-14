# git-tui MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ファイル単位の stage/unstage・diff 閲覧・コミットができる、マウスと日本語に対応した git TUI の MVP を作る。

**Architecture:** Elm 風の純粋 reducer（`Model + Msg → Model + AppCmd`）を中核に置き、副作用（git CLI 実行）は `AppCmd` 解釈器に隔離する。git は子プロセス委譲（`git status --porcelain=v2 -z` 等）。TUI 描画・入力は zigzag に委ねるが、純粋ロジックは zigzag/端末に依存させず単体テスト可能にする。

**Tech Stack:** Zig 0.16.0 / zigzag v0.1.5（TUI）/ git CLI / `std.process.Child` / `std.testing`。

> 設計の根拠と判断理由は `docs/superpowers/specs/2026-06-14-git-tui-design.md` を参照（このプランはその spec を実装に落とすもの）。

---

## Zig / テストの約束ごと（全タスク共通）

- **テストは実装と同じ `.zig` ファイル内の `test "..." {}` ブロックに書く**（Zig の慣習）。別テストファイルは作らない。
- 実行は `zig build test`（`build.zig` に test ステップを定義する。Task 1 で用意）。個別ファイルは `zig test src/foo.zig` も可。
- テストでは必ず `std.testing.allocator` を使う（リーク検出）。確保したものは `defer ... .deinit(allocator)` / `defer allocator.free(...)`。
- `std.ArrayList(T)` は Zig 0.16 の **unmanaged API**（`var list: std.ArrayList(T) = .empty;` → `try list.append(allocator, x);` → `list.deinit(allocator);`）。
- エラーは明示的エラーセット（`error{...}`）で表現し、`anyerror` を避ける。
- **各タスクの「テスト実行」ステップでコンパイルエラー（std/zigzag のシグネチャ差異）が出たら、`zig` 0.16 / Task 1 の API ノートに合わせて修正してから先へ進む。** TDD の run ステップがこの検出器を兼ねる。

---

## File Structure（責務マップ）

- `build.zig` / `build.zig.zon` — ビルド定義と依存（zigzag）固定。test ステップを含む。
- `src/git/process.zig` — git 子プロセス実行ラッパ。argv と cwd を受け取り `{ stdout, stderr, exit_code }` を返す。zigzag 非依存。
- `src/git/status.zig` — `git status --porcelain=v2 -z` 出力のパーサ。`StatusEntry` のリストを返す純粋関数。zigzag 非依存。
- `src/git/commands.zig` — 各操作の argv 生成（stage/unstage/commit/diff/HEAD有無/toplevel）と高レベル実行。zigzag 非依存。
- `src/model.zig` — `Model`（状態）と所有権・`deinit`。zigzag 非依存。
- `src/messages.zig` — `Msg` と `AppCmd` のタグ付きユニオン定義＋各 `deinit`。zigzag 非依存。
- `src/update.zig` — 純粋 reducer `update(model, msg, allocator) -> struct { model, cmd }`。zigzag 非依存。
- `src/appcmd.zig` — `AppCmd` 解釈器。`commands.zig` を呼び結果 `Msg` を返す。zigzag 非依存（端末不要）。
- `src/input.zig` — zigzag の入力イベント → `Msg` 正規化。マッピング判断は純粋関数で単体テスト。
- `src/view.zig` — zigzag を用いた描画（Task 1 の API ノートに従う）。
- `src/main.zig` — zigzag ランタイム接続・reducer↔解釈器の配線・ワーカースレッド。
- `docs/superpowers/plans/zigzag-api-notes.md` — Task 1 が生成する zigzag/std 実 API メモ（後続タスクが参照）。

---

## Task 1: プロジェクト雛形 + zigzag/std 依存スパイク ★ブロッカー

**Files:**
- Create: `build.zig.zon`, `build.zig`, `src/main.zig`（最小）, `docs/superpowers/plans/zigzag-api-notes.md`

このタスクは spec §3「着手前の必須前提」。後続タスクが依存する zigzag/std の実 API をここで確定する。

- [ ] **Step 1: `build.zig.zon` に zigzag を固定して取得**

Run:
```bash
zig fetch --save "https://github.com/meszmate/zigzag/archive/refs/tags/v0.1.5.tar.gz"
```
Expected: `build.zig.zon` が生成/更新され、`.dependencies.zigzag` に `url` と `hash`（SHA）が記録される。再現性のためこのハッシュをコミットする。

- [ ] **Step 2: `build.zig` を作成（exe + test ステップ）**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag = b.dependency("zigzag", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "git-tui",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    b.installArtifact(exe);

    const run_step = b.step("run", "Run git-tui");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // すべてのモジュールのファイル内 test を集約
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zigzag", zigzag.module("zigzag"));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```
> 注: `zigzag.module("zigzag")` のモジュール名は zigzag の `build.zig` 実体に合わせる（Step 4 で確認）。`b.path` / `addImport` のシグネチャが 0.16 で違えばコンパイルエラーに従って修正。

- [ ] **Step 3: `src/root_test.zig` と最小 `src/main.zig` を作成**

`src/root_test.zig`（テスト集約。後続タスクで `_ = @import("...")` を追加していく）:
```zig
test {
    @import("std").testing.refAllDeclsRecursive(@This());
    _ = @import("git/process.zig");
    _ = @import("git/status.zig");
    _ = @import("git/commands.zig");
    _ = @import("model.zig");
    _ = @import("messages.zig");
    _ = @import("update.zig");
    _ = @import("appcmd.zig");
    _ = @import("input.zig");
}
```
> 上記 import のファイルは後続タスクで作成する。Task 1 時点では存在するものだけ残し、各タスクで該当行を有効化する。

`src/main.zig`（最小: zigzag で "hello"＋キー入力で終了＋全角を含む TextArea を1つ表示）:
```zig
const std = @import("std");
const zz = @import("zigzag");
// 最小の Model-Update-View を 1 画面だけ実装する（API は Step 4 で確認しながら）。
// 目的: ビルド・起動・キー入力・マウス・全角表示が Zig 0.16 + zigzag v0.1.5 で動くことの確認。
pub fn main() !void {
    // zigzag の Program 起動 API に合わせて実装する（Step 4 のノート参照）。
}
```

- [ ] **Step 4: ビルド＆起動し、実 API を確認して `zigzag-api-notes.md` に記録**

Run:
```bash
zig build && zig build run
```
Expected: ビルドが通り、TUI が起動し、全角（例: 「日本語ＡＢＣ」）が桁ずれなく表示され、キー（`q`）で終了、マウスクリックが取れる。

確認して `docs/superpowers/plans/zigzag-api-notes.md` に**実ソース由来の正確なシグネチャ**を記録する（後続タスクが参照）:
- Program 起動: 関数名・`init`/`run`/`deinit` シグネチャ、Model/update/view コールバックの型
- `update` の戻り値型（`Cmd(Msg)` の有無と中身）と、外部からイベント/Msg を注入する手段（あるか/無いか）
- 非同期実行（`AsyncRunner` 等）の有無
- 入力イベント型（キー・マウス。SGR。`enable_mouse`/`disable_mouse`）
- `TextArea` の API（生成・描画・キー入力処理・`Ctrl+S` サブミット・カーソル）
- レイアウト/描画 API（パネル・ボックス・テキスト描画・スタイル）
- custom I/O（ヘッドレステスト手段）の有無
- 確認した `std.process.Child.run` と `std.ArrayList` の 0.16 シグネチャ

- [ ] **Step 5: Commit**

```bash
git add build.zig build.zig.zon src/main.zig src/root_test.zig docs/superpowers/plans/zigzag-api-notes.md
git commit -m "chore: scaffold build + pin zigzag v0.1.5 + API spike notes"
```

---

## Task 2: git 子プロセス実行ラッパ（`src/git/process.zig`）

**Files:**
- Create: `src/git/process.zig`

argv と cwd を受け取り、stdout/stderr/exit code を返す薄いラッパ。zigzag 非依存。

- [ ] **Step 1: 失敗するテストを書く**

`src/git/process.zig`:
```zig
const std = @import("std");

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8, // 異常終了(シグナル等)は 255 に正規化
    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

test "run echo returns stdout and exit 0" {
    const a = std.testing.allocator;
    var res = try run(a, &.{ "echo", "hello" }, null);
    defer res.deinit(a);
    try std.testing.expectEqualStrings("hello\n", res.stdout);
    try std.testing.expectEqual(@as(u8, 0), res.exit_code);
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig test src/git/process.zig`
Expected: FAIL（`run` 未定義）。

- [ ] **Step 3: 最小実装**

```zig
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !RunResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    const code: u8 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = code };
}
```
> `std.process.Child.run` の戻り値フィールド名（`stdout`/`stderr`/`term`）と `.Exited` タグは Task 1 のノートで確認済みのものに合わせる。

- [ ] **Step 4: テスト実行（成功確認）**

Run: `zig test src/git/process.zig`
Expected: PASS。

- [ ] **Step 5: 非0終了のテストを追加して実装確認**

```zig
test "run false returns nonzero exit" {
    const a = std.testing.allocator;
    var res = try run(a, &.{ "false" }, null);
    defer res.deinit(a);
    try std.testing.expect(res.exit_code != 0);
}
```
Run: `zig test src/git/process.zig` → PASS。

- [ ] **Step 6: Commit**

```bash
git add src/git/process.zig
git commit -m "feat(git): subprocess runner capturing stdout/stderr/exit"
```

---

## Task 3: porcelain v2 パーサ（`src/git/status.zig`）

**Files:**
- Create: `src/git/status.zig`

`git status --porcelain=v2 -z` の出力（NUL 区切り）を `StatusEntry` 配列へ。spec §3 のパーサ注意点（rename=2パス、untracked=`?`）を満たす。zigzag 非依存。

- [ ] **Step 1: 型と最初の失敗テストを書く**

`src/git/status.zig`:
```zig
const std = @import("std");

pub const Section = enum { staged, unstaged, untracked };

pub const StatusEntry = struct {
    path: []u8,
    orig_path: ?[]u8, // rename/copy のときの旧パス
    section: Section,
    pub fn deinit(self: *StatusEntry, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.orig_path) |p| a.free(p);
    }
};

pub const ParseError = error{ MalformedRecord, OutOfMemory };

/// 呼び出し側が返り値スライスと各要素を解放する。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError![]StatusEntry {
    _ = a;
    _ = raw;
    return ParseError.MalformedRecord;
}

test "parses modified-in-worktree (type 1) as unstaged" {
    const a = std.testing.allocator;
    // XY=".M" → unstaged 変更。フィールドは porcelain v2 の固定順。
    const raw = "1 .M N... 100644 100644 100644 0000000 0000000 README.md\x00";
    const entries = try parse(a, raw);
    defer { for (entries) |*e| e.deinit(a); a.free(entries); }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("README.md", entries[0].path);
    try std.testing.expectEqual(Section.unstaged, entries[0].section);
    try std.testing.expect(entries[0].orig_path == null);
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig test src/git/status.zig`
Expected: FAIL（`MalformedRecord` を返す未実装）。

- [ ] **Step 3: パーサ実装（レコード種別ごとの状態機械）**

```zig
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError![]StatusEntry {
    var list: std.ArrayList(StatusEntry) = .empty;
    errdefer { for (list.items) |*e| e.deinit(a); list.deinit(a); }

    var it = std.mem.splitScalar(u8, raw, 0); // NUL 区切りトークン
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        switch (tok[0]) {
            '1' => try appendOrdinary(a, &list, tok, false),
            '2' => {
                // rename/copy: このレコードの後に NUL 区切りの origPath が続く
                const orig = it.next() orelse return ParseError.MalformedRecord;
                try appendOrdinary(a, &list, tok, true);
                const last = &list.items[list.items.len - 1];
                last.orig_path = try a.dupe(u8, orig);
            },
            '?' => {
                const path = tok[2..]; // "? <path>"
                try list.append(a, .{
                    .path = try a.dupe(u8, path),
                    .orig_path = null,
                    .section = .untracked,
                });
            },
            'u', '!' => {}, // MVP: 未マージ/ignored はスキップ
            else => return ParseError.MalformedRecord,
        }
    }
    return list.toOwnedSlice(a);
}

// "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>" / "2 <XY> ... <Xscore> <path>"
fn appendOrdinary(
    a: std.mem.Allocator,
    list: *std.ArrayList(StatusEntry),
    tok: []const u8,
    is_rename: bool,
) ParseError!void {
    var fields = std.mem.tokenizeScalar(u8, tok, ' ');
    _ = fields.next(); // "1" or "2"
    const xy = fields.next() orelse return ParseError.MalformedRecord;
    if (xy.len < 2) return ParseError.MalformedRecord;
    // パスは固定数フィールドの後ろ。type1=8フィールド後, type2=9フィールド後(scoreが1つ多い)。
    const skip: usize = if (is_rename) 7 else 6;
    var i: usize = 0;
    while (i < skip) : (i += 1) _ = fields.next() orelse return ParseError.MalformedRecord;
    const path = fields.rest(); // 残り全部がパス（空白を含みうる）
    if (path.len == 0) return ParseError.MalformedRecord;

    // X(index)=staged 側, Y(worktree)=unstaged 側。両方変更があれば 2 エントリにしたいが、
    // MVP は「片方でも staged 変更があれば staged、それ以外で worktree 変更があれば unstaged」を
    // 1 ファイル 1 セクションで表現する基本形にする。両立は後続で (path,section) 2 エントリ化。
    const x = xy[0];
    const section: Section = if (x != '.') .staged else .unstaged;
    try list.append(a, .{
        .path = try a.dupe(u8, path),
        .orig_path = null,
        .section = section,
    });
}
```

- [ ] **Step 4: テスト実行（成功確認）**

Run: `zig test src/git/status.zig`
Expected: PASS。

- [ ] **Step 5: rename・untracked・日本語パス・staged のテストを追加**

```zig
test "parses rename (type 2) consuming two paths" {
    const a = std.testing.allocator;
    // "2 R. <...> R100 <newpath>\x00<origpath>\x00"
    const raw = "2 R. N... 100644 100644 100644 0000000 0000000 R100 new.txt\x00old.txt\x00";
    const entries = try parse(a, raw);
    defer { for (entries) |*e| e.deinit(a); a.free(entries); }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("new.txt", entries[0].path);
    try std.testing.expectEqualStrings("old.txt", entries[0].orig_path.?);
    try std.testing.expectEqual(Section.staged, entries[0].section);
}

test "rename followed by another entry does not desync" {
    const a = std.testing.allocator;
    const raw =
        "2 R. N... 100644 100644 100644 0000000 0000000 R100 new.txt\x00old.txt\x00" ++
        "1 .M N... 100644 100644 100644 0000000 0000000 after.txt\x00";
    const entries = try parse(a, raw);
    defer { for (entries) |*e| e.deinit(a); a.free(entries); }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("after.txt", entries[1].path);
}

test "parses untracked single question mark" {
    const a = std.testing.allocator;
    const raw = "? 新規ファイル.txt\x00";
    const entries = try parse(a, raw);
    defer { for (entries) |*e| e.deinit(a); a.free(entries); }
    try std.testing.expectEqual(Section.untracked, entries[0].section);
    try std.testing.expectEqualStrings("新規ファイル.txt", entries[0].path);
}

test "staged modification (X=M) is staged section" {
    const a = std.testing.allocator;
    const raw = "1 M. N... 100644 100644 100644 0000000 0000000 src/main.zig\x00";
    const entries = try parse(a, raw);
    defer { for (entries) |*e| e.deinit(a); a.free(entries); }
    try std.testing.expectEqual(Section.staged, entries[0].section);
}
```
Run: `zig test src/git/status.zig`
Expected: PASS（全件）。

- [ ] **Step 6: Commit**

```bash
git add src/git/status.zig
git commit -m "feat(git): porcelain v2 -z parser (rename two-path, untracked, utf8)"
```

---

## Task 4: git コマンド argv 生成（`src/git/commands.zig`）

**Files:**
- Create: `src/git/commands.zig`

各操作の argv を生成する純粋関数（テスト容易）と、`process.run` を呼ぶ高レベル関数。spec §3/§8 準拠。

- [ ] **Step 1: argv 生成の失敗テストを書く**

`src/git/commands.zig`:
```zig
const std = @import("std");
const process = @import("process.zig");

pub const Section = @import("status.zig").Section;

/// stage の argv。rename のときは新旧両パスを渡す。呼び出し側が free。
pub fn stageArgv(a: std.mem.Allocator, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    _ = a; _ = path; _ = orig_path;
    return error.NotImplemented;
}

test "stageArgv passes path; both paths for rename" {
    const a = std.testing.allocator;
    const argv = try stageArgv(a, "new.txt", "old.txt");
    defer a.free(argv);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("add", argv[1]);
    try std.testing.expectEqualStrings("--", argv[2]);
    try std.testing.expectEqualStrings("new.txt", argv[3]);
    try std.testing.expectEqualStrings("old.txt", argv[4]);
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig test src/git/commands.zig`
Expected: FAIL（`NotImplemented`）。

- [ ] **Step 3: argv 生成を実装**

```zig
pub fn stageArgv(a: std.mem.Allocator, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "add", "--", path });
    if (orig_path) |o| try list.append(a, o);
    return list.toOwnedSlice(a);
}

/// HEAD があれば restore --staged、無ければ rm --cached。両パスを渡す。
pub fn unstageArgv(a: std.mem.Allocator, has_head: bool, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    if (has_head) {
        try list.appendSlice(a, &.{ "git", "restore", "--staged", "--", path });
    } else {
        try list.appendSlice(a, &.{ "git", "rm", "--cached", "--", path });
    }
    if (orig_path) |o| try list.append(a, o);
    return list.toOwnedSlice(a);
}

pub fn diffArgv(a: std.mem.Allocator, section: Section, path: []const u8, orig_path: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    switch (section) {
        .staged => try list.appendSlice(a, &.{ "git", "diff", "--cached", "--", path }),
        .unstaged => try list.appendSlice(a, &.{ "git", "diff", "--", path }),
        .untracked => try list.appendSlice(a, &.{ "git", "diff", "--no-index", "--", "/dev/null", path }),
    }
    if (orig_path) |o| if (section != .untracked) try list.append(a, o);
    return list.toOwnedSlice(a);
}
```

- [ ] **Step 4: テスト実行 + 各 argv のテストを追加**

```zig
test "unstageArgv uses rm --cached when no HEAD" {
    const a = std.testing.allocator;
    const argv = try unstageArgv(a, false, "f.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("rm", argv[1]);
    try std.testing.expectEqualStrings("--cached", argv[2]);
}
test "diffArgv untracked uses --no-index against /dev/null" {
    const a = std.testing.allocator;
    const argv = try diffArgv(a, .untracked, "new.txt", null);
    defer a.free(argv);
    try std.testing.expectEqualStrings("--no-index", argv[2]);
    try std.testing.expectEqualStrings("/dev/null", argv[4]);
}
```
Run: `zig test src/git/commands.zig` → PASS。

- [ ] **Step 5: 高レベル関数（実行系）を追加**

```zig
pub fn repoRoot(a: std.mem.Allocator) !?[]u8 {
    var res = try process.run(a, &.{ "git", "rev-parse", "--show-toplevel" }, null);
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    const trimmed = std.mem.trimRight(u8, res.stdout, "\n");
    return try a.dupe(u8, trimmed);
}

pub fn hasHead(a: std.mem.Allocator, cwd: []const u8) !bool {
    var res = try process.run(a, &.{ "git", "rev-parse", "--verify", "HEAD" }, cwd);
    defer res.deinit(a);
    return res.exit_code == 0;
}

pub fn statusRaw(a: std.mem.Allocator, cwd: []const u8) !process.RunResult {
    return process.run(a, &.{ "git", "status", "--porcelain=v2", "-z" }, cwd);
}

/// メッセージを stdin で渡してコミット。
pub fn commit(a: std.mem.Allocator, cwd: []const u8, message: []const u8) !process.RunResult {
    var child = std.process.Child.init(&.{ "git", "commit", "-F", "-" }, a);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    try child.stdin.?.writeAll(message);
    child.stdin.?.close();
    child.stdin = null;
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(a);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(a);
    try child.collectOutput(a, &stdout, &stderr, 16 * 1024 * 1024);
    const term = try child.wait();
    const code: u8 = switch (term) { .Exited => |c| @intCast(c), else => 255 };
    return .{
        .stdout = try stdout.toOwnedSlice(a),
        .stderr = try stderr.toOwnedSlice(a),
        .exit_code = code,
    };
}
```
> `child.collectOutput` / `child.stdin` の 0.16 シグネチャは Task 1 ノートに合わせる。コンパイルエラーが出たら実 API へ調整。

- [ ] **Step 6: Commit**

```bash
git add src/git/commands.zig
git commit -m "feat(git): argv builders + high-level status/commit/head/root"
```

---

## Task 5: Model と所有権（`src/model.zig`）

**Files:**
- Create: `src/model.zig`

UI 状態の保持と `deinit`。spec §4「Model の所有権」準拠。zigzag 非依存。

- [ ] **Step 1: 型と deinit の失敗テストを書く**

```zig
const std = @import("std");
const status = @import("git/status.zig");

pub const Focus = enum { changes, diff, commit };

pub const FileItem = struct {
    path: []u8,
    orig_path: ?[]u8,
    section: status.Section,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    repo_root: []u8,
    has_head: bool,
    branch: []u8,
    files: std.ArrayList(FileItem),
    selected: usize,
    diff_text: []u8,         // 選択ファイルの diff（空可）
    commit_message: []u8,    // TextArea の内容（空可）
    focus: Focus,
    busy: bool,
    error_text: []u8,        // 直近エラー（空可）
    mouse_enabled: bool,

    pub fn init(a: std.mem.Allocator, repo_root: []const u8) !Model {
        return .{
            .allocator = a,
            .repo_root = try a.dupe(u8, repo_root),
            .has_head = false,
            .branch = try a.dupe(u8, ""),
            .files = .empty,
            .selected = 0,
            .diff_text = try a.dupe(u8, ""),
            .commit_message = try a.dupe(u8, ""),
            .focus = .changes,
            .busy = false,
            .error_text = try a.dupe(u8, ""),
            .mouse_enabled = true,
        };
    }

    pub fn deinit(self: *Model) void {
        const a = self.allocator;
        a.free(self.repo_root);
        a.free(self.branch);
        for (self.files.items) |*f| { a.free(f.path); if (f.orig_path) |p| a.free(p); }
        self.files.deinit(a);
        a.free(self.diff_text);
        a.free(self.commit_message);
        a.free(self.error_text);
    }

    /// files を新しいエントリ集合で置換（旧データを free）。
    /// entries は**複製**する（借用しない）。entries 自体の所有権は呼び出し側に残り、
    /// 呼び出し側が Msg.status_loaded の deinit で解放する（spec §4: 二重 free 防止）。
    pub fn replaceFiles(self: *Model, entries: []const status.StatusEntry) !void {
        const a = self.allocator;
        for (self.files.items) |*f| { a.free(f.path); if (f.orig_path) |p| a.free(p); }
        self.files.clearRetainingCapacity();
        for (entries) |e| {
            const path = try a.dupe(u8, e.path);
            errdefer a.free(path);
            const orig: ?[]u8 = if (e.orig_path) |p| try a.dupe(u8, p) else null;
            try self.files.append(a, .{ .path = path, .orig_path = orig, .section = e.section });
        }
        if (self.selected >= self.files.items.len) self.selected = if (self.files.items.len == 0) 0 else self.files.items.len - 1;
    }

    /// 文字列フィールドを置換するヘルパ（旧を free して dup）。
    pub fn setStr(self: *Model, field: *[]u8, value: []const u8) !void {
        const a = self.allocator;
        const dup = try a.dupe(u8, value);
        a.free(field.*);
        field.* = dup;
    }
};

test "init/deinit leaves no leaks" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    try std.testing.expectEqualStrings("/tmp/repo", m.repo_root);
    try std.testing.expectEqual(Focus.changes, m.focus);
}
```

- [ ] **Step 2: テスト実行（成功確認 — リーク無し）**

Run: `zig test src/model.zig`
Expected: PASS（`std.testing.allocator` がリークを報告しない）。

- [ ] **Step 3: setStr / replaceFiles のテストを追加**

```zig
test "setStr frees old and stores new without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    try m.setStr(&m.diff_text, "diff A");
    try std.testing.expectEqualStrings("diff A", m.diff_text);
    try m.setStr(&m.diff_text, "diff B");
    try std.testing.expectEqualStrings("diff B", m.diff_text);
}

test "replaceFiles copies entries (caller still owns originals)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/tmp/repo");
    defer m.deinit();
    var entries = try a.alloc(status.StatusEntry, 1);
    defer { a.free(entries[0].path); a.free(entries); } // 呼び出し側が originals を解放
    entries[0] = .{ .path = try a.dupe(u8, "f.txt"), .orig_path = null, .section = .unstaged };
    try m.replaceFiles(entries); // Model は複製を持つ（二重 free しない）
    try std.testing.expectEqual(@as(usize, 1), m.files.items.len);
    try std.testing.expectEqualStrings("f.txt", m.files.items[0].path);
}
```
Run: `zig test src/model.zig` → PASS（リーク無し）。

- [ ] **Step 4: Commit**

```bash
git add src/model.zig
git commit -m "feat: Model state with explicit ownership and deinit"
```

---

## Task 6: Msg / AppCmd 型（`src/messages.zig`）

**Files:**
- Create: `src/messages.zig`

reducer の入出力。所有ペイロードは複製・`deinit` を持つ（spec §4「所有権規約」）。zigzag 非依存。

- [ ] **Step 1: 型と deinit の失敗テストを書く**

```zig
const std = @import("std");
const status = @import("git/status.zig");
const Section = status.Section;

pub const Msg = union(enum) {
    key_down,            // j / ↓
    key_up,              // k / ↑
    toggle_stage,        // space / s / ダブルクリック
    focus_next,          // tab
    focus_commit,        // c
    request_refresh,     // r
    request_commit,      // Ctrl+S
    quit,
    select_index: usize, // マウスでファイル行クリック
    char_input: u21,     // commit フォーカス時の文字入力（コードポイント）
    backspace,
    // 解釈器からの結果（所有: 複製済み）
    status_loaded: []status.StatusEntry,
    diff_loaded: []u8,
    git_error: []u8,
    committed,

    pub fn deinit(self: *Msg, a: std.mem.Allocator) void {
        switch (self.*) {
            .status_loaded => |entries| { for (entries) |*e| { a.free(e.path); if (e.orig_path) |p| a.free(p); } a.free(entries); },
            .diff_loaded => |s| a.free(s),
            .git_error => |s| a.free(s),
            else => {},
        }
    }
};

pub const AppCmd = union(enum) {
    none,
    refresh_status,
    stage: OwnedPath,
    unstage: OwnedPath,
    load_diff: LoadDiff,
    commit: []u8, // 所有: メッセージ複製
    quit,

    pub const OwnedPath = struct { path: []u8, orig_path: ?[]u8, section: Section };
    pub const LoadDiff = struct { path: []u8, orig_path: ?[]u8, section: Section };

    pub fn deinit(self: *AppCmd, a: std.mem.Allocator) void {
        switch (self.*) {
            .stage, .unstage => |op| { a.free(op.path); if (op.orig_path) |p| a.free(p); },
            .load_diff => |ld| { a.free(ld.path); if (ld.orig_path) |p| a.free(p); },
            .commit => |m| a.free(m),
            else => {},
        }
    }
};

test "AppCmd.commit owns its message and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .commit = try a.dupe(u8, "hello") };
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("hello", cmd.commit);
}
```

- [ ] **Step 2: テスト実行（成功確認）**

Run: `zig test src/messages.zig`
Expected: PASS（リーク無し）。

- [ ] **Step 3: Commit**

```bash
git add src/messages.zig
git commit -m "feat: Msg and AppCmd unions with owned payloads + deinit"
```

---

## Task 7: 純粋 reducer（`src/update.zig`）

**Files:**
- Create: `src/update.zig`

`update(model, msg) -> AppCmd`。Model を直接書き換え（in-place）つつ、副作用は AppCmd で表現。AppCmd ペイロードは Model から**複製**する（借用しない）。zigzag 非依存。

- [ ] **Step 1: 失敗テストを書く（選択移動）**

```zig
const std = @import("std");
const Model = @import("model.zig").Model;
const Focus = @import("model.zig").Focus;
const msgs = @import("messages.zig");
const Msg = msgs.Msg;
const AppCmd = msgs.AppCmd;
const status = @import("git/status.zig");

/// Model を破壊的に更新し、必要な副作用を AppCmd で返す。
/// 返した AppCmd は呼び出し側（解釈器/テスト）が deinit する。
pub fn update(model: *Model, msg: Msg) !AppCmd {
    _ = model; _ = msg;
    return AppCmd.none;
}

fn addFile(m: *Model, path: []const u8, section: status.Section) !void {
    try m.files.append(m.allocator, .{ .path = try m.allocator.dupe(u8, path), .orig_path = null, .section = section });
}

test "key_down moves selection within bounds" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "a", .unstaged);
    try addFile(&m, "b", .unstaged);
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    var c1 = try update(&m, .key_down); c1.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), m.selected);
    var c2 = try update(&m, .key_down); c2.deinit(a); // 末尾で止まる
    try std.testing.expectEqual(@as(usize, 1), m.selected);
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig test src/update.zig`
Expected: FAIL（selection が動かない）。

- [ ] **Step 3: reducer 実装**

```zig
pub fn update(model: *Model, msg: Msg) !AppCmd {
    switch (msg) {
        .key_down => { if (model.selected + 1 < model.files.items.len) model.selected += 1; return .none; },
        .key_up => { if (model.selected > 0) model.selected -= 1; return .none; },
        .select_index => |i| { if (i < model.files.items.len) model.selected = i; return loadDiffCmd(model); },
        .focus_next => { model.focus = switch (model.focus) { .changes => .diff, .diff => .commit, .commit => .changes }; return .none; },
        .focus_commit => { model.focus = .commit; return .none; },
        .toggle_stage => {
            if (model.files.items.len == 0) return .none;
            const f = model.files.items[model.selected];
            const op = AppCmd.OwnedPath{
                .path = try model.allocator.dupe(u8, f.path),
                .orig_path = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null,
                .section = f.section,
            };
            // staged なら unstage、それ以外（unstaged/untracked）は stage
            return if (f.section == .staged) .{ .unstage = op } else .{ .stage = op };
        },
        .request_refresh => return .refresh_status,
        .request_commit => {
            if (model.commit_message.len == 0) { try model.setStr(&model.error_text, "コミットメッセージが空です"); return .none; }
            return .{ .commit = try model.allocator.dupe(u8, model.commit_message) };
        },
        .char_input => |cp| { if (model.focus == .commit) try appendCodepoint(model, cp); return .none; },
        .backspace => { if (model.focus == .commit) popCodepoint(model); return .none; },
        .quit => return .quit,
        // 解釈器からの結果
        .status_loaded => |entries| { model.busy = false; try model.replaceFiles(entries); return loadDiffCmd(model); },
        .diff_loaded => |text| { model.busy = false; try model.setStr(&model.diff_text, text); return .none; },
        .git_error => |text| { model.busy = false; try model.setStr(&model.error_text, text); return .none; },
        .committed => { model.busy = false; try model.setStr(&model.commit_message, ""); return .refresh_status; },
    }
}

fn loadDiffCmd(model: *Model) !AppCmd {
    if (model.files.items.len == 0) { try model.setStr(&model.diff_text, ""); return .none; }
    const f = model.files.items[model.selected];
    return .{ .load_diff = .{
        .path = try model.allocator.dupe(u8, f.path),
        .orig_path = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null,
        .section = f.section,
    } };
}

fn appendCodepoint(model: *Model, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    const joined = try std.mem.concat(model.allocator, u8, &.{ model.commit_message, buf[0..n] });
    model.allocator.free(model.commit_message);
    model.commit_message = joined;
}

fn popCodepoint(model: *Model) void {
    if (model.commit_message.len == 0) return;
    var i: usize = model.commit_message.len;
    // UTF-8 継続バイト(0b10xxxxxx)をスキップして先頭バイトまで戻す
    while (i > 0) { i -= 1; if (model.commit_message[i] & 0xC0 != 0x80) break; }
    model.commit_message = model.allocator.realloc(model.commit_message, i) catch model.commit_message[0..i];
}
```

- [ ] **Step 4: テスト実行（成功確認）**

Run: `zig test src/update.zig`
Expected: PASS。

- [ ] **Step 5: toggle_stage / status_loaded / commit-empty / 日本語入力のテストを追加**

```zig
test "toggle_stage on unstaged returns stage cmd with copied path" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    var cmd = try update(&m, .toggle_stage);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .stage);
    try std.testing.expectEqualStrings("f.txt", cmd.stage.path);
}

test "request_commit with empty message sets error and no commit" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var cmd = try update(&m, .request_commit);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .none);
    try std.testing.expect(m.error_text.len > 0);
}

test "char_input appends multibyte when focus is commit" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.focus = .commit;
    var c1 = try update(&m, .{ .char_input = 0x65E5 }); c1.deinit(a); // 日
    var c2 = try update(&m, .{ .char_input = 0x672C }); c2.deinit(a); // 本
    try std.testing.expectEqualStrings("日本", m.commit_message);
    var c3 = try update(&m, .backspace); c3.deinit(a);
    try std.testing.expectEqualStrings("日", m.commit_message);
}
```
Run: `zig test src/update.zig` → PASS（リーク無し）。

- [ ] **Step 6: Commit**

```bash
git add src/update.zig
git commit -m "feat: pure update reducer (Model+Msg -> AppCmd), tested headless"
```

---

## Task 8: AppCmd 解釈器（`src/appcmd.zig`）— 一時リポジトリ結合テスト

**Files:**
- Create: `src/appcmd.zig`

`AppCmd` を git backend 実行に変換し、結果 `Msg` を返す。端末不要。spec §9 の結合テスト（空リポジトリ初回コミット・rename・untracked・サブディレクトリ起動）をここで満たす。

- [ ] **Step 1: 解釈器スケルトンと最初の結合テストを書く**

```zig
const std = @import("std");
const cmds = @import("git/commands.zig");
const process = @import("git/process.zig");
const statusmod = @import("git/status.zig");
const msgs = @import("messages.zig");
const Msg = msgs.Msg;
const AppCmd = msgs.AppCmd;

/// AppCmd を実行し、結果 Msg を返す（呼び出し側が Msg を deinit）。
pub fn run(a: std.mem.Allocator, cwd: []const u8, cmd: AppCmd) !Msg {
    _ = a; _ = cwd; _ = cmd;
    return error.NotImplemented;
}

// --- テスト用ヘルパ: 一時 git リポジトリを作る ---
const TmpRepo = struct {
    dir: std.testing.TmpDir,
    path: []u8,
    a: std.mem.Allocator,
    fn init(a: std.mem.Allocator) !TmpRepo {
        var dir = std.testing.tmpDir(.{});
        const path = try dir.dir.realpathAlloc(a, ".");
        _ = try process.run(a, &.{ "git", "init", "-q" }, path);
        _ = try process.run(a, &.{ "git", "config", "user.email", "t@t" }, path);
        _ = try process.run(a, &.{ "git", "config", "user.name", "t" }, path);
        return .{ .dir = dir, .path = path, .a = a };
    }
    fn writeFile(self: *TmpRepo, name: []const u8, content: []const u8) !void {
        try self.dir.dir.writeFile(.{ .sub_path = name, .data = content });
    }
    fn deinit(self: *TmpRepo) void { self.a.free(self.path); self.dir.cleanup(); }
};

test "refresh_status on empty repo with one untracked file" {
    const a = std.testing.allocator;
    var repo = try TmpRepo.init(a);
    defer repo.deinit();
    try repo.writeFile("new.txt", "hi");
    var msg = try run(a, repo.path, .refresh_status);
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    try std.testing.expectEqual(@as(usize, 1), msg.status_loaded.len);
    try std.testing.expectEqual(statusmod.Section.untracked, msg.status_loaded[0].section);
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig test src/appcmd.zig`
Expected: FAIL（`NotImplemented`）。

- [ ] **Step 3: 解釈器を実装**

```zig
pub fn run(a: std.mem.Allocator, cwd: []const u8, cmd: AppCmd) !Msg {
    switch (cmd) {
        .none, .quit => return .committed, // 呼び出し側が使わない場合の安全値（quit は main で別処理）
        .refresh_status => {
            var res = try cmds.statusRaw(a, cwd);
            defer res.deinit(a);
            if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            const entries = try statusmod.parse(a, res.stdout);
            return .{ .status_loaded = entries };
        },
        .stage => |op| {
            const argv = try cmds.stageArgv(a, op.path, op.orig_path);
            defer a.free(argv);
            return execThenRefresh(a, cwd, argv);
        },
        .unstage => |op| {
            const has_head = try cmds.hasHead(a, cwd);
            const argv = try cmds.unstageArgv(a, has_head, op.path, op.orig_path);
            defer a.free(argv);
            return execThenRefresh(a, cwd, argv);
        },
        .load_diff => |ld| {
            const argv = try cmds.diffArgv(a, ld.section, ld.path, ld.orig_path);
            defer a.free(argv);
            var res = try process.run(a, argv, cwd);
            defer res.deinit(a);
            // diff --no-index は差分ありで exit 1 を返すので、stderr が空なら成功扱い
            if (res.exit_code != 0 and res.stderr.len != 0 and ld.section != .untracked)
                return .{ .git_error = try a.dupe(u8, res.stderr) };
            return .{ .diff_loaded = try a.dupe(u8, res.stdout) };
        },
        .commit => |message| {
            var res = try cmds.commit(a, cwd, message);
            defer res.deinit(a);
            if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
            return .committed;
        },
    }
}

// 副作用コマンドを実行 → 失敗なら git_error、成功なら status を読み直して status_loaded を返す
fn execThenRefresh(a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !Msg {
    var res = try process.run(a, argv, cwd);
    defer res.deinit(a);
    if (res.exit_code != 0) return .{ .git_error = try a.dupe(u8, res.stderr) };
    var sres = try cmds.statusRaw(a, cwd);
    defer sres.deinit(a);
    if (sres.exit_code != 0) return .{ .git_error = try a.dupe(u8, sres.stderr) };
    return .{ .status_loaded = try statusmod.parse(a, sres.stdout) };
}
```

- [ ] **Step 4: テスト実行（成功確認）**

Run: `zig test src/appcmd.zig`
Expected: PASS。

- [ ] **Step 5: stage→commit サイクルと rename の結合テストを追加**

```zig
test "stage then commit on empty repo succeeds (first commit, no parent)" {
    const a = std.testing.allocator;
    var repo = try TmpRepo.init(a);
    defer repo.deinit();
    try repo.writeFile("a.txt", "hello");
    // stage
    var m1 = try run(a, repo.path, .{ .stage = .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .untracked } });
    defer m1.deinit(a);
    try std.testing.expect(m1 == .status_loaded);
    // commit
    var m2 = try run(a, repo.path, .{ .commit = try a.dupe(u8, "first commit") });
    defer m2.deinit(a);
    try std.testing.expect(m2 == .committed);
    // 確認: HEAD ができている
    try std.testing.expect(try cmds.hasHead(a, repo.path));
}

test "rename is reported and unstaged with both paths" {
    const a = std.testing.allocator;
    var repo = try TmpRepo.init(a);
    defer repo.deinit();
    try repo.writeFile("old.txt", "x");
    _ = try process.run(a, &.{ "git", "add", "old.txt" }, repo.path);
    _ = try process.run(a, &.{ "git", "commit", "-q", "-m", "init" }, repo.path);
    _ = try process.run(a, &.{ "git", "mv", "old.txt", "new.txt" }, repo.path);
    var m = try run(a, repo.path, .refresh_status);
    defer m.deinit(a);
    try std.testing.expect(m == .status_loaded);
    // rename エントリが新パスを持つ
    var found = false;
    for (m.status_loaded) |e| { if (std.mem.eql(u8, e.path, "new.txt")) found = true; }
    try std.testing.expect(found);
}
```
Run: `zig test src/appcmd.zig` → PASS（全件・リーク無し）。

- [ ] **Step 6: Commit**

```bash
git add src/appcmd.zig
git commit -m "feat: AppCmd interpreter + integration tests (empty repo, rename, untracked)"
```

---

## Task 9: 入力正規化（`src/input.zig`）

**Files:**
- Create: `src/input.zig`

zigzag の入力イベントを `Msg` に正規化する。**マッピング判断は純粋関数**にして単体テストし、zigzag イベント型からの取り出しだけ薄く zigzag 依存にする。spec §6（フォーカス時のキー捕捉）準拠。

- [ ] **Step 1: 純粋マッピングの失敗テストを書く**

```zig
const std = @import("std");
const Focus = @import("model.zig").Focus;
const Msg = @import("messages.zig").Msg;

/// 抽象化したキー（zigzag のキー型はここに変換してから渡す）
pub const Key = union(enum) {
    char: u21,     // 通常文字（コードポイント）
    enter, backspace, tab, escape,
    ctrl_s, down, up,
};

/// フォーカスを考慮してキー→Msg を決める純粋関数。
/// commit フォーカス時は編集キー以外のグローバルキーを無効化する（spec §6）。
pub fn keyToMsg(focus: Focus, key: Key) ?Msg {
    if (focus == .commit) {
        return switch (key) {
            .char => |c| .{ .char_input = c },
            .backspace => .backspace,
            .ctrl_s => .request_commit,
            .escape, .tab => .focus_next,
            else => null, // q/s 等のグローバルキーは無効
        };
    }
    return switch (key) {
        .char => |c| switch (c) {
            'j' => .key_down,
            'k' => .key_up,
            's', ' ' => .toggle_stage,
            'c' => .focus_commit,
            'r' => .request_refresh,
            'q' => .quit,
            else => null,
        },
        .down => .key_down,
        .up => .key_up,
        .tab => .focus_next,
        else => null,
    };
}

test "in commit focus, q is typed not quit" {
    const m = keyToMsg(.commit, .{ .char = 'q' });
    try std.testing.expect(m.? == .char_input);
}
test "in changes focus, q quits" {
    const m = keyToMsg(.changes, .{ .char = 'q' });
    try std.testing.expect(m.? == .quit);
}
test "ctrl_s in commit requests commit" {
    try std.testing.expect(keyToMsg(.commit, .ctrl_s).? == .request_commit);
}
```

- [ ] **Step 2: テスト実行（成功確認）**

Run: `zig test src/input.zig`
Expected: PASS（実装は Step 1 に含む）。先に失敗を見たい場合は本体を `return null;` にしてから戻す。

- [ ] **Step 3: マウス→Msg の純粋関数を追加**

```zig
pub const MouseEvent = struct {
    kind: enum { left_click, left_double, wheel_up, wheel_down },
    /// ファイル一覧ペイン内で計算済みの行インデックス（ペイン外は null）
    file_row: ?usize,
};

pub fn mouseToMsg(ev: MouseEvent) ?Msg {
    return switch (ev.kind) {
        .left_click => if (ev.file_row) |r| .{ .select_index = r } else null,
        .left_double => if (ev.file_row != null) .toggle_stage else null,
        .wheel_up, .wheel_down => null, // diff スクロールは view 側状態で処理（MVP）
    };
}

test "double click on file row toggles stage" {
    try std.testing.expect(mouseToMsg(.{ .kind = .left_double, .file_row = 2 }).? == .toggle_stage);
}
```
Run: `zig test src/input.zig` → PASS。

- [ ] **Step 4: zigzag イベント → `Key`/`MouseEvent` 変換の薄いアダプタを追加**

Task 1 の `zigzag-api-notes.md` に記録した zigzag の入力イベント型に従い、`fromZigzagKey(ev) Key` と
`fromZigzagMouse(ev, layout) MouseEvent` を実装する（行インデックスはレイアウト矩形から算出）。
この部分は zigzag 依存のため `test` は付けず、Task 11 のヘッドレス/手動検証でカバーする。

```zig
// 例（実際の zigzag 型名は api-notes に合わせる）:
// pub fn fromZigzagKey(ev: zz.Key) ?Key { ... }
// pub fn fromZigzagMouse(ev: zz.Mouse, files_rect: Rect) MouseEvent { ... }
```

- [ ] **Step 5: Commit**

```bash
git add src/input.zig
git commit -m "feat: input normalization (focus-aware key/mouse -> Msg), pure-tested"
```

---

## Task 10: 描画（`src/view.zig`）

**Files:**
- Create: `src/view.zig`

`Model` を zigzag の描画 API で 2 ペイン + コミット欄 + ステータスバーに描く。spec §5 のレイアウト。zigzag 依存のため、**レイアウト矩形の計算（純粋）だけ単体テスト**し、描画呼び出しは Task 1 の API ノートに従う。

- [ ] **Step 1: レイアウト計算（純粋）の失敗テストを書く**

```zig
const std = @import("std");

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };
pub const Layout = struct { changes: Rect, diff: Rect, commit: Rect, status: Rect };

/// 端末サイズから各ペインの矩形を決める純粋関数。
/// 左 40% を Changes、右 60% を Diff、下部 commit_h 行を Commit、最下行を status。
pub fn computeLayout(w: u16, h: u16, commit_h: u16) Layout {
    return undefined;
}

test "layout splits width 40/60 and reserves commit+status rows" {
    const l = computeLayout(100, 30, 5);
    try std.testing.expectEqual(@as(u16, 40), l.changes.w);
    try std.testing.expectEqual(@as(u16, 60), l.diff.w);
    try std.testing.expectEqual(@as(u16, 1), l.status.h);
    try std.testing.expectEqual(@as(u16, 5), l.commit.h);
    // status は最下行
    try std.testing.expectEqual(@as(u16, 29), l.status.y);
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig test src/view.zig`
Expected: FAIL（`undefined` 返却でフィールドが一致しない）。

- [ ] **Step 3: レイアウト計算を実装**

```zig
pub fn computeLayout(w: u16, h: u16, commit_h: u16) Layout {
    const status_h: u16 = 1;
    const top_h: u16 = h - commit_h - status_h;
    const left_w: u16 = w * 40 / 100;
    const right_w: u16 = w - left_w;
    return .{
        .changes = .{ .x = 0, .y = 0, .w = left_w, .h = top_h },
        .diff = .{ .x = left_w, .y = 0, .w = right_w, .h = top_h },
        .commit = .{ .x = 0, .y = top_h, .w = w, .h = commit_h },
        .status = .{ .x = 0, .y = h - status_h, .w = w, .h = status_h },
    };
}
```

- [ ] **Step 4: テスト実行（成功確認）**

Run: `zig test src/view.zig`
Expected: PASS。

- [ ] **Step 5: zigzag 描画関数 `render(model, frame)` を実装**

`zigzag-api-notes.md` の描画 API に従い、以下を描く（この部分は zigzag 依存・自動 test なし、手動検証で確認）:
- Changes ペイン: Staged / Unstaged / Untracked のセクション見出しと各ファイル行。`selected` を反転表示。
- Diff ペイン: `model.diff_text` を行単位で描画（スクロール位置は view 内 state）。`+`/`-` を色分け。
- Commit ペイン: zigzag `TextArea` に `model.commit_message` をバインド。`focus==.commit` のとき枠を強調。
- Status バー: `model.branch`、`busy` ならスピナ、`error_text` があれば表示、キーヒント。
- 全角を含む文字列の桁は zigzag の幅計算に委ねる（spec §7）。

```zig
// pub fn render(model: *const Model, ctx: zz.RenderCtx) void { ... } // 実 API は api-notes 準拠
```

- [ ] **Step 6: Commit**

```bash
git add src/view.zig
git commit -m "feat: view layout (pure-tested) + zigzag rendering"
```

---

## Task 11: ランタイム配線（`src/main.zig`）+ エンドツーエンド確認

**Files:**
- Modify: `src/main.zig`

reducer ↔ AppCmd 解釈器を zigzag ランタイムに配線。git 実行はワーカースレッドで行い、完了 `Msg` をイベントループへ注入（spec §4「ランタイムへの接続」）。zigzag 依存・手動検証中心。

- [ ] **Step 1: 起動シーケンスを実装**

`zigzag-api-notes.md` に従い:
1. `cmds.repoRoot` を取得。null ならエラー表示して終了（spec §8）。
2. `Model.init(allocator, root)`、`cmds.hasHead` で `has_head` を設定。
3. 起動直後に `AppCmd.refresh_status` を 1 回実行（初期状態ロード）。
4. zigzag の Program を起動。`update` コールバックで:
   - 入力イベントを `input.fromZigzagKey/Mouse` → `Msg` に正規化（`keyToMsg`/`mouseToMsg`）。
   - `update.update(&model, msg)` を呼び `AppCmd` を得る。**reducer は Msg の中身を複製して取り込む**
     （replaceFiles/setStr は dup する）ため、**main は `update` 呼び出し後に `msg.deinit(allocator)` を呼ぶ**
     （所有権規約: Msg の消費者＝main が解放）。同様に得た `AppCmd` は使用後に `cmd.deinit(allocator)`。
   - `AppCmd` が副作用なら**ワーカースレッドで `appcmd.run` を実行**、`model.busy=true`。完了時に結果 `Msg` を
     スレッドセーフキューへ push し、メインループの tick で取り出して再度 `update.update` に流す
     （この結果 Msg も処理後に main が `deinit`）。
   - `AppCmd.quit` でループ終了。
5. `view.render(&model, ...)` で描画。
6. 終了時に `model.deinit()`、`disable_mouse` 等の後始末。

> 注入手段（外部スレッド→ループ）が zigzag に無い場合は、tick ごとにキューをポーリングするフォールバック（spec §4）。

- [ ] **Step 2: ビルド & 起動**

Run: `zig build && zig build run`
Expected: 現在のリポジトリで起動し、変更ファイルが Staged/Unstaged/Untracked に分かれて表示される。

- [ ] **Step 3: 受け入れ基準の手動検証（spec §2.5）**

別の検証用リポジトリで以下を手動確認し、結果を記録する:
1. ファイル選択で右ペインに適切な diff（staged→`--cached` / unstaged→通常 / untracked→`--no-index`）。
2. キーボードのみで stage→unstage→`c`でメッセージ入力→`Ctrl+S`でコミット まで完結。
3. **空リポジトリで初回コミット完了**（`git init` した空ディレクトリで起動）。
4. **日本語ファイル名**を stage→diff 表示→commit、桁ずれ無し。コミットメッセージに日本語入力・編集。
5. マウス: クリック選択・ダブルクリック stage・ホイールスクロール。
6. `git-tui` を `TERM` がマウス非対応の状況で起動し、キーボードのみで全操作が完結。
7. 故意に失敗させ（例: フック失敗）stderr 表示と Model 非破壊を確認。

- [ ] **Step 4: 手動検証マトリクスを記録**

`docs/superpowers/plans/zigzag-api-notes.md` の末尾、または `docs/manual-test-checklist.md` に
端末×マウス×日本語の検証結果（OK/NG）を表で残す。

- [ ] **Step 5: Commit**

```bash
git add src/main.zig docs/
git commit -m "feat: wire zigzag runtime, worker thread for git, e2e manual verify"
```

---

## 受け入れ基準 ↔ タスク対応（self-review 用）

| 受け入れ基準（spec §2.5） | 担保するタスク |
|---|---|
| 1. Staged/Unstaged/Untracked 表示 | Task 3（パーサ）+ Task 8（status）+ Task 10（描画）|
| 2. セクション別の diff 表示 | Task 4（diffArgv）+ Task 8（load_diff）+ Task 7（loadDiffCmd）|
| 3. キーボードのみで stage→unstage→commit | Task 7（reducer）+ Task 9（keyToMsg）+ Task 8 |
| 4. 空リポジトリ初回コミット | Task 8（結合テスト）+ Task 4（hasHead 分岐）|
| 5. 日本語ファイル名・メッセージ | Task 3（utf8 パス）+ Task 7（char_input/backspace）+ Task 10（幅）|
| 6. マウス操作 | Task 9（mouseToMsg）+ Task 11（配線）|
| 7. マウス無効でもキーボードで完結 | Task 9（keyToMsg 完全パス）+ Task 11 |
| 8. git 失敗時に Model 非破壊 | Task 8（git_error）+ Task 7（楽観更新しない）|
| 9. テスト一式が通る（リーク無し） | Task 2–9（各 `test` ブロック、`zig build test`）|
