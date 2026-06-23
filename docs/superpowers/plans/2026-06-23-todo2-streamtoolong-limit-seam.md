# StreamTooLong limit 注入 seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `git log` 実行経路の出力 limit を注入可能にし、`error.StreamTooLong` → `LogLoadFailed`/`LogPageFailed` の正規化を 16MiB 実データ無しでテストできるようにする。

**Architecture:** `src/git/process.zig` に `runWithLimit`（stdout_limit を引数化）+ `default_stream_limit` 定数を新設し、既存 `run` は既定値で委譲する薄いラッパへ。`src/appcmd.zig` の `runLogInt`/`runLogPageInt` に `log_limit: std.Io.Limit` 引数を追加し、**`git log` 実行 1 箇所ずつ**だけ `runWithLimit` へ切替。dispatcher は `default_stream_limit` を渡すので本番挙動は不変。

**Tech Stack:** Zig 0.16（`std.process.run` の Io 版・`std.Io.Limit`）。Elm 風アーキ（副作用は appcmd 解釈器に隔離）。

**Review status:** codex 独立レビュー済み（**READY**・BLOCKER 0 / MAJOR 0 / NIT 3）。所有権（値渡し + `defer cmd.deinit(a)` で二重解放なし）・`revParseHead` 戻り `!?[]u8` 所有・無効 tip→exit128 前提・`run` ラッパ化の後方互換を実コードで確認。NIT-1（logArgv が出力を縮めない前提）は実装時に logArgv フォーマットを一度目視（40 文字 hash 単独で 16 byte 超のため実害なし）。

## Global Constraints

- Zig 0.16（Writergate）: 子プロセスは `std.process.run(gpa, io, opts)`（`io` 必須）。`opts.stdout_limit`/`stderr_limit` は `std.Io.Limit`（`.limited(N)`/`.unlimited`・整数不可）。
- テストは**実装と同じ `.zig` 内の `test {}` ブロック**に書く（別テストファイルを作らない）。
- 必ず `std.testing.allocator`（リーク検出）+ `std.testing.io`。
- ビルド: `zig build`。テスト: `zig build test --summary all`（**既定 Debug を維持**）。
- `process.zig`/`appcmd.zig` は既に `src/root_test.zig` 登録済み（既存テストあり）→ 追加登録不要。
- **挙動不変が必須**: 本番の全 git 実行は 16MiB 既定 limit のまま。seam はテストからのみ小 limit を渡す。
- spec: `docs/superpowers/specs/2026-06-23-todo2-streamtoolong-limit-seam-design.md`（codex レビュー READY 反映済み）。
- **前提（実証済み）**: `std.process.run` は `stdout_limit` 超過時に truncate せず `error.StreamTooLong` を返す（判定は strict `>`・`lib/std/process.zig:520-528`）。limit 値は出力サイズより小さく取る。

---

## File Structure

- `src/git/process.zig`（Modify）: limit 定数 + `runWithLimit` 新設 + `run` ラッパ化 + 単体テスト 1 件。
- `src/appcmd.zig`（Modify）: `runLogInt`/`runLogPageInt` の `log_limit` 引数 + log 実行点切替 + dispatcher 2 arm + 結合テスト 2 件。
- `TODO.md`（Modify）: phase 3b 残「StreamTooLong の limit 注入 seam」チェックボックス更新（Task 2 完了時）。

---

### Task 1: process.zig — `runWithLimit` + `run` ラッパ化 + StreamTooLong 単体テスト

**Files:**
- Modify: `src/git/process.zig:28-45`（`run` を `runWithLimit` へ分割）
- Test: `src/git/process.zig`（同ファイル内 `test {}`）

**Interfaces:**
- Consumes: `std.process.run`（既存）、`std.Io.Limit`、`RunResult`/`RunError`/`Cwd`（既存・同ファイル）。
- Produces:
  - `pub const default_stream_limit: std.Io.Limit`（= `.limited(16 * 1024 * 1024)`）
  - `pub fn runWithLimit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: Cwd, stdout_limit: std.Io.Limit) RunError!RunResult`
  - `pub fn run(allocator, io, argv, cwd) RunError!RunResult`（シグネチャ不変・本体はラッパ）

- [ ] **Step 1: StreamTooLong 単体テストを書く（失敗させる）**

`src/git/process.zig` の末尾テスト群（`test "run false returns nonzero exit"` の後）に追加:

```zig
test "runWithLimit returns StreamTooLong when stdout exceeds the limit" {
    const a = std.testing.allocator;
    // "hello\n" は 6 byte。stdout_limit=2 で超過 → error.StreamTooLong。
    // 前提（spec §6）: limit 超過は truncate ではなく error。本テストがその回帰ガード。
    try std.testing.expectError(
        error.StreamTooLong,
        runWithLimit(a, std.testing.io, &.{ "echo", "hello" }, .inherit, .limited(2)),
    );
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: コンパイルエラー（`runWithLimit` / `default_stream_limit` 未定義）または FAIL。

- [ ] **Step 3: `default_stream_limit` + `runWithLimit` + `run` ラッパを実装**

`src/git/process.zig:28-45` の現 `run` 全体を以下へ置換:

```zig
/// std.process.run の既定ストリーム上限（16MiB）。
/// 注意: `run` では stdout/stderr 両方へ適用するが、`runWithLimit` では
/// stderr のみへ適用する（stdout は注入引数 `stdout_limit` で置換）。
pub const default_stream_limit: std.Io.Limit = .limited(16 * 1024 * 1024);

/// argv を cwd で実行し、stdout/stderr と正規化した exit code を返す。
/// `stdout_limit` は呼び出し側が指定（テストでの StreamTooLong 再現用 seam）。
/// stderr は常に `default_stream_limit`（git のエラー文は小さく超過しないため）。
/// 返り値の stdout/stderr の所有権は呼び出し側（`RunResult.deinit` で解放）。
pub fn runWithLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: Cwd,
    stdout_limit: std.Io.Limit,
) RunError!RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = stdout_limit,
        .stderr_limit = default_stream_limit,
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c, // 既に u8
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = code };
}

/// 既定 limit（16MiB）で argv を実行する薄いラッパ。本番経路はこちらを使う。
/// エラーセットは `RunError`（= `std.process.RunError` の再エクスポート）で明示する。
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: Cwd,
) RunError!RunResult {
    return runWithLimit(allocator, io, argv, cwd, default_stream_limit);
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: PASS。既存 2 テスト（`run echo returns stdout and exit 0` / `run false returns nonzero exit`）も通過（`run` はラッパ化されても挙動同一）。

- [ ] **Step 5: コミット**

```bash
git add src/git/process.zig
git commit -m "feat(process): add runWithLimit seam, run becomes default-limit wrapper

stdout_limit is now injectable for tests; run() delegates with the 16MiB
default_stream_limit constant. Unit test proves limit overflow returns
error.StreamTooLong (no truncate, strict >), guarding the seam premise.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: appcmd.zig — `log_limit` 引数 + log 実行点切替 + StreamTooLong 結合テスト

**Files:**
- Modify: `src/appcmd.zig:108-109`（dispatcher 2 arm）
- Modify: `src/appcmd.zig:156`（`runLogInt` シグネチャ）, `:186`（log 実行点）
- Modify: `src/appcmd.zig:261`（`runLogPageInt` シグネチャ）, `:264`（log 実行点）
- Modify: `TODO.md`（チェックボックス更新）
- Test: `src/appcmd.zig`（同ファイル内 `test {}`・既存 `runLogInt:` テスト群の後）

**Interfaces:**
- Consumes: `process.runWithLimit` / `process.default_stream_limit`（Task 1）、`cmds.revParseHead(a, io, cwd) ?[]u8`（既存・所有 or null）、`FilterSpec.init()`（空・確保ゼロ）、`AppCmd.LoadLog`/`AppCmd.LoadLogPage`（messages.zig:239-245）、`TmpRepo`（appcmd.zig:318）、`Msg.deinit`（messages.zig:124）。
- Produces:
  - `fn runLogInt(a, io, cwd, cmd: AppCmd.LoadLog, log_limit: std.Io.Limit) !Msg`（末尾に `log_limit` 追加）
  - `fn runLogPageInt(a, io, cwd, cmd: AppCmd.LoadLogPage, log_limit: std.Io.Limit) !Msg`（末尾に `log_limit` 追加）

- [ ] **Step 1: StreamTooLong 結合テスト 2 件を書く（失敗させる）**

`src/appcmd.zig` の `runLogInt:`/`runLogPageInt:` テスト群の末尾に追加（`runOwned` を使わず log 関数を**直接**呼ぶ点に注意）:

```zig
test "runLogInt: tiny stdout_limit normalizes StreamTooLong to log_load_failed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // 1 コミット必須: head 解決を通過して git log 実行（注入 limit 使用）へ到達させるため。
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    // 直接呼びは runOwned の auto-deinit を経由しないので payload を明示解放。
    // LoadLog.filter は空（FilterSpec.init = 確保ゼロ）だが規約遵守で union+defer。
    var cmd = AppCmd{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = FilterSpec.init(),
    } };
    defer cmd.deinit(a);
    // 40 文字 hash を含む git log 出力 >> 16 byte → StreamTooLong → 正規化。
    var msg = try runLogInt(a, io, repo.cwd(), cmd.load_log, .limited(16));
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_load_failed);
    try std.testing.expect(std.mem.indexOf(u8, msg.log_load_failed.error_text, "git log 実行エラー") != null);
}

test "runLogPageInt: tiny stdout_limit normalizes StreamTooLong to log_page_failed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    // runLogPageInt は head 解決せず tip_hash で直接 log 実行 → 有効な tip が必要
    // （無効 tip だと stdout 空 → StreamTooLong 不発・exit 128 経路になる）。
    const tip = (try cmds.revParseHead(a, io, repo.cwd())).?;
    // tip は cmd.tip_hash が所有（cmd.deinit で free）。
    var cmd = AppCmd{ .load_log_page = .{
        .skip = 0, .max_count = 100, .generation = 1, .tip_hash = tip, .filter = FilterSpec.init(),
    } };
    defer cmd.deinit(a);
    var msg = try runLogPageInt(a, io, repo.cwd(), cmd.load_log_page, .limited(16));
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_page_failed);
    try std.testing.expect(std.mem.indexOf(u8, msg.log_page_failed.error_text, "git log 実行エラー") != null);
}
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: コンパイルエラー（`runLogInt`/`runLogPageInt` は 5 引数を取らない・引数不一致）。

- [ ] **Step 3: `runLogInt` に `log_limit` を追加し log 実行を `runWithLimit` へ**

`src/appcmd.zig:156` のシグネチャを変更:

```zig
fn runLogInt(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd.LoadLog, log_limit: std.Io.Limit) !Msg {
```

`src/appcmd.zig:186` の log 実行行を変更（前後の `// MINOR7:` コメントと catch 句は不変）:

```zig
    var res = process.runWithLimit(a, io, argv.args, cwd, log_limit) catch
        return mkLoadFailedOrSilent(a, cmd, "git log 実行エラー", snapshot_tip);
```

- [ ] **Step 4: `runLogPageInt` に `log_limit` を追加し log 実行を `runWithLimit` へ**

`src/appcmd.zig:261` のシグネチャを変更:

```zig
fn runLogPageInt(a: std.mem.Allocator, io: std.Io, cwd: Cwd, cmd: AppCmd.LoadLogPage, log_limit: std.Io.Limit) !Msg {
```

`src/appcmd.zig:264` の log 実行行を変更:

```zig
    var res = process.runWithLimit(a, io, argv.args, cwd, log_limit) catch
        return mkPageFailedOrSilentForPage(a, cmd, "git log 実行エラー");
```

- [ ] **Step 5: dispatcher の 2 arm が既定 limit を渡すよう変更**

`src/appcmd.zig:108-109` を変更:

```zig
        .load_log => |c| return runLogInt(a, io, cwd, c, process.default_stream_limit),
        .load_log_page => |c| return runLogPageInt(a, io, cwd, c, process.default_stream_limit),
```

- [ ] **Step 6: テストを実行して通過を確認**

Run: `zig build test --summary all 2>&1 | tail -20`
Expected: PASS。新規 2 テストが通過し、既存の `runLogInt:`/`runLogPageInt:`/log paging 系テスト（dispatcher 経由）も全通過。リーク検出（`std.testing.allocator`）でエラーなし。

- [ ] **Step 7: `TODO.md` のチェックボックスを更新**

`TODO.md` の phase 3b 残リストの該当行を `[ ]` → `[x]` へ:

```
- [x] **StreamTooLong の limit 注入 seam**（テスト容易化・`git/process.zig`・spec §6.3）: `process.runWithLimit` + `default_stream_limit` 新設・`runLogInt`/`runLogPageInt` へ `log_limit` 注入・小 limit で StreamTooLong→`LogLoadFailed`/`LogPageFailed` 正規化を実証（2026-06-23 完了）。spec: `docs/superpowers/specs/2026-06-23-todo2-streamtoolong-limit-seam-design.md`。
```

（元の行は `- [ ] **StreamTooLong の limit 注入 seam（テスト容易化・...phase3a は catch で LogLoadFailed/LogPageFailed へ正規化のみ）**` 形式。完了マークと実装サマリへ置換する。）

- [ ] **Step 8: コミット**

```bash
git add src/appcmd.zig TODO.md
git commit -m "feat(appcmd): thread log_limit through runLogInt/runLogPageInt

git log execution now uses process.runWithLimit; dispatcher passes the
16MiB default (behavior unchanged). Integration tests reproduce
StreamTooLong with a tiny limit and assert normalization to
log_load_failed / log_page_failed. Marks TODO 2 phase3b seam done.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage（spec §7 受け入れ基準との対応）:**
- §7.1 `runWithLimit` 新設 + `run` ラッパ → Task 1 Step 3。✓
- §7.2 小 limit で `error.StreamTooLong` 実証 → Task 1 Step 1/4。✓
- §7.3 `runLogInt`/`runLogPageInt` の `log_limit` + dispatcher 既定 → Task 2 Step 3/4/5。✓
- §7.4 小 limit で `.log_load_failed`/`.log_page_failed`（prefix「git log 実行エラー」）→ Task 2 Step 1/6。✓
- §7.5 既存テスト全通過 + 本番挙動不変 → Task 1 Step 4 / Task 2 Step 6（既存テストは dispatcher 経由で既定 limit）。✓
- §7.6 `TODO.md` 更新 → Task 2 Step 7。✓
- §1.1 定数コメント（非対称適用・NIT-2）→ Task 1 Step 3 のコメント。✓
- §4.2 直接呼びの payload 明示 deinit（MINOR-1・特に `LoadLogPage.tip_hash`）→ Task 2 Step 1（union+`defer cmd.deinit(a)`・tip は `revParseHead` で所有）。✓
- §4.2 1 コミット必須理由（MINOR-2）→ Task 2 Step 1 コメント。✓

**2. Placeholder scan:** TBD/TODO/「適切なエラー処理」等なし。全 step に実コード/実コマンド/期待値あり。✓

**3. Type consistency:**
- `runWithLimit(.., stdout_limit: std.Io.Limit)` — Task 1 定義と Task 2 呼び出し（`.limited(16)` / `process.default_stream_limit`）一致。✓
- `runLogInt(.., cmd: AppCmd.LoadLog, log_limit: std.Io.Limit)` / `runLogPageInt(.., cmd: AppCmd.LoadLogPage, log_limit)` — Task 2 Step 3/4 定義と Step 1 テスト呼び出し・Step 5 dispatcher 呼び出し一致。✓
- `cmds.revParseHead` 戻り `?[]u8`（`.?` で unwrap・所有）→ `tip_hash: []u8`（messages.zig:244）へ代入・`cmd.deinit` で free。✓
- `FilterSpec.init()`（filter.zig:23・空・確保ゼロ）→ `AppCmd.deinit` の `filter.deinit(a)` は no-op。✓
