# busy lifecycle 完全修正 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `busy` を runtime（`main.zig`）のみが所有し、reducer（`update.zig`）が一切書き込まないようにして、M-N9 の競合（stale worker 結果の drain が新 worker の busy を早落とし→二重実行）を構造的に排除する。

**Architecture:** reducer の `busy=false` 書き込み 4 箇所を削除し、busy の上げ下げを `dispatchSideEffect`/`reapWorker`/sync フォールバックのみへ集約。テスト容易化のため `std.Thread.spawn` を `App.spawn_fn`（関数ポインタ）へ抽象化し、`worker: ?std.Thread` を `?WorkerHandle`（`thread: ?std.Thread` ラップ）へ変更して、実スレッド無しで在飛状態を偽装できるようにする。テスト executor は staged 結果を同期的に push し、M-N9 競合を決定的に再現する。

**Tech Stack:** Zig 0.16.0（std.Io API）/ zigzag v0.1.5 / 既存の `ResultQueue` mutex キュー・worker 直列実行モデル。

**Spec:** `docs/superpowers/specs/2026-06-24-todo2-busy-lifecycle-design.md`

## Global Constraints

- Zig 0.16.0（`mise.toml` 固定）。`std.Io` 必須（mutex は `lockUncancelable(io)`）。
- テストは `zig build test --summary all`（**Debug 既定維持**・Release にしない）。`--test-filter` は未配線（AGENTS.md）・常に全件実行。
- テストは実装 `.zig` 内の `test {}`。`std.testing.allocator` 必須（リーク検出）。io は `std.testing.io`。
- 新規 `.zig` は `src/root_test.zig` へ import 追加（今回は `main.zig` を追加）。
- 純粋層（model/update/messages/appcmd/git）を TDD → UI/runtime 配線の順。
- lint/format/typecheck/codegen/migration ステップは存在しない（`zig build test` が型検査も兼ねる）。
- コメント規約: コードコメントは日本語可（既存踏襞）・実装には不要なコメントを足さない。

---

## File Structure

- **`src/main.zig`**（変更）: `WorkerHandle` 型・`App.spawn_fn`/`App.test_staged` フィールド追加・`dispatchSideEffect`/`spawnAsync`/`spawnSync`/`reapWorker` 書き直し・sync フォールバック busy 下ろし・`main()` で `spawn_fn` 設定・`deinit` で `test_staged` 解放・新規 `test {}`（`makeTestApp`/`freeTestApp`/所有権テスト）。
- **`src/update.zig`**（変更）: reducer 4 箇所の `model.busy = false;` 削除・既存テスト 1 件修正・busy 不変テスト 3 件追加。
- **`src/root_test.zig`**（変更）: `_ = @import("main.zig");` 追加。
- **`TODO.md`**（変更）: `:198` の #4 チェックボックスを `[x]` へ。

---

## Task 1: Runtime seam — injectable spawn + WorkerHandle + sync-fallback busy 下ろし

reducer はまだ `busy=false` を書く（二重で無害）。本タスクで runtime が busy を完全所有できる構造を作り、sync フォールバックで自前下ろすようにする。本番挙動は維持（既存 509 テスト green を保つ）。

**Files:**
- Modify: `src/main.zig`（`App` struct `:96-115`・`dispatchSideEffect` `:161-181`・`reapWorker` `:223-241`・`deinit` `:322-343`・`main()` の `g_app` リテラル `:652-663`・新規 executor fn・新規 `test {}`）
- Modify: `src/root_test.zig`
- Test: `src/main.zig`（新規 `test {}`）

**Interfaces:**
- Consumes: `App`（`src/main.zig:96`）・`ResultQueue`（`:42`）・`workerThread`/`workerRun`（`:126-147`）・`isMutating`（`:152`）・`Model.busy`/`working`（`src/model.zig:42-43`）。
- Produces: `WorkerHandle` struct・`App.spawn_fn: *const fn(*App, AppCmd) void`・`App.test_staged: std.ArrayList(Msg)`・`App.worker: ?WorkerHandle`・`spawnAsync`/`spawnSync`・書き直し `dispatchSideEffect`/`reapWorker`・`makeTestApp`/`freeTestApp`。

- [ ] **Step 1: `WorkerHandle` 型と `App` フィールド追加**

`src/main.zig` の `App` struct（`:96`）の直前（`:94` の `};` の後・`:95` コメントの前）へ挿入:

```zig
/// 在飛 worker のハンドル。`thread` は本番 spawn のみ非 null。
/// テスト executor（spawnSync）は `.{ .thread = null }` で在飛状態を偽装し、
/// reapWorker は `if (w.thread) |t| t.join()` で本番のみ join する。
const WorkerHandle = struct { thread: ?std.Thread = null };
```

`App` struct（`:96-115`）の `worker`/`pending` フィールドを変更・`spawn_fn`/`test_staged` 追加。該当箇所:

```zig
    // ワーカー直列実行（1 度に 1 コマンド）。busy 中の新規副作用は pending に latest-wins で退避。
    worker: ?WorkerHandle = null,
    pending: ?AppCmd = null,
    // 副作用の起動 executor。本番は spawnAsync（実スレッド）。テストは spawnSync（同期・staged 結果）。
    spawn_fn: *const fn(*App, AppCmd) void,
    // テスト専用: spawnSync が push する結果 Msg の staging（本番では常に空）。
    test_staged: std.ArrayList(Msg) = .empty,
```

- [ ] **Step 2: `dispatchSideEffect` を `spawn_fn` 委譲へ書き直し + `spawnAsync`/`spawnSync` 新設**

`src/main.zig:159-181`（`dispatchSideEffect` 全体）を以下へ置換:

```zig
/// 副作用 AppCmd をワーカーへ委譲する。busy 中なら pending に退避（latest-wins）。
/// `cmd` の所有権を受け取る（委譲できなければ executor 側で deinit する）。
fn dispatchSideEffect(app: *App, cmd: AppCmd) void {
    if (app.worker != null) {
        // 既存ワーカー稼働中。前の pending は捨てて最新で上書き（rapid j/k の load_diff を間引く）。
        if (app.pending) |*p| p.deinit(app.gpa);
        app.pending = cmd;
        return;
    }
    app.model.busy = true; // reducer の二重実行ゲート。全 in-flight で立てる（表示はしない）。
    app.model.working = isMutating(cmd); // スピナ表示用。変更系のときだけ true（読み取りでは点滅させない）。
    app.spawn_fn(app, cmd);
}

/// 本番 executor: 実スレッドで workerThread を起動。spawn 失敗時は同期フォールバック
/// （workerRun 後に busy/working を下ろす・markWorkerDone 無し＝review Issue 2 維持）。
/// busy は reducer ではなく runtime のみが触る（M-N9 完全修正）。
fn spawnAsync(app: *App, cmd: AppCmd) void {
    const handle = std.Thread.spawn(.{}, workerThread, .{ app, cmd }) catch {
        // spawn 失敗時はメインスレッドで同期実行（degraded だがクラッシュしない）。
        // worker は null のままなので reapWorker は join せず、worker_done も触らない（＝
        // 次回の正規ワーカーが stale done で誤 join される事故を避ける）。busy/working は
        // workerRun 完了後にここで下ろす（reducer に頼らない・M-N9）。
        app.worker = null;
        app.model.busy = false;
        app.model.working = false;
        workerRun(app, cmd);
        return;
    };
    app.worker = .{ .thread = handle };
}

/// テスト executor: 実スレッド/appcmd.run を使わず、staged 結果を同期的に push する。
/// M-N9 競合を決定的に再現するための seam（実 thread スケジューリングに依存しない）。
fn spawnSync(app: *App, cmd: AppCmd) void {
    cmd.deinit(app.gpa); // 実行しないので所有権を解放
    while (app.test_staged.items.len > 0) {
        const m = app.test_staged.orderedRemove(0); // 順序保持・所有権は queue へ移譲
        app.queue.push(app.io, app.gpa, m);
    }
    app.queue.markWorkerDone(app.io);
    app.worker = .{ .thread = null };
}
```

- [ ] **Step 3: `reapWorker` を `WorkerHandle` へ書き直し**

`src/main.zig:223-241`（`reapWorker` 全体）を以下へ置換:

```zig
/// ワーカー完了を回収する。完了していれば join し、pending があれば次を起動する。
fn reapWorker(app: *App) void {
    if (app.worker) |w| {
        // join はブロックするので、ワーカーが終端に到達した（markWorkerDone 済み）ことを
        // 確認してから join する。完了検出はキュー長ではなく独立フラグで行う: キュー drain
        // とのインターリーブで完了を取りこぼし、worker が恒久的に non-null になる事故を防ぐ
        //（review Issue 2）。worker は markWorkerDone 直後に return するため join は即時返る。
        // takeWorkerDone は取得即クリアなので、結果が既に drain 済みでも完了を取りこぼさない。
        if (!app.queue.takeWorkerDone(app.io)) return;
        if (w.thread) |t| t.join(); // 本番のみ（テスト executor は thread=null で join 不要）
        app.worker = null;
        app.model.busy = false;
        app.model.working = false; // スピナ解除（pending があれば下の dispatch が再設定する）。
        if (app.pending) |next| {
            app.pending = null;
            dispatchSideEffect(app, next);
        }
    }
}
```

- [ ] **Step 4: `main()` の `g_app` リテラルへ `spawn_fn` 設定**

`src/main.zig:652-663` の `g_app = .{ ... }` リテラルへ `.spawn_fn = spawnAsync,` を追加（`.filter_modal = undefined,` の次あたり）:

```zig
    g_app = .{
        .gpa = gpa,
        .io = io,
        .cwd = cwd_root,
        .model = m,
        .textarea = undefined, // RuntimeModel.init で生成
        .filter_author_input = undefined,
        .filter_since_input = undefined,
        .filter_until_input = undefined,
        .filter_path_input = undefined,
        .filter_modal = undefined,
        .spawn_fn = spawnAsync, // 本番 executor（テストは spawnSync へ上書き）
    };
```

- [ ] **Step 5: `deinit` で `test_staged` を解放**

`src/main.zig:322-343`（`RuntimeModel.deinit`）の `app.queue.deinit(app.gpa);`（`:334`）の直後に追加:

```zig
        app.queue.deinit(app.gpa);
        app.test_staged.deinit(app.gpa);
```

- [ ] **Step 6: `root_test.zig` へ `main.zig` を追加**

`src/root_test.zig` の `test { ... }` ブロック末尾（`:23` の `filter.zig` import の後）へ追加:

```zig
    _ = @import("filter.zig"); // TODO 2 phase 3a: ログフィルタ
    _ = @import("main.zig"); // TODO 2 phase 3b #4: busy lifecycle runtime 層
```

- [ ] **Step 7: `makeTestApp`/`freeTestApp` ヘルパーと所有権テストを追加**

`src/main.zig` 末尾（`:716` のファイル末尾）へ追加:

```zig
// =============================================================================
// TODO 2 phase 3b #4: busy lifecycle runtime テスト（spec §6.2）
// 実 thread を使わず spawnSync で決定的に検証する。
// =============================================================================

/// テスト用の最小 App を構築する。spawn_fn=spawnSync・空 test_staged。
fn makeTestApp() !*App {
    const a = std.testing.allocator;
    const m = try Model.init(a, "/r");
    g_app = .{
        .gpa = a,
        .io = std.testing.io,
        .cwd = .{ .path = m.repo_root },
        .model = m,
        .textarea = zz.TextArea.init(a),
        .filter_author_input = zz.TextInput.init(a),
        .filter_since_input = zz.TextInput.init(a),
        .filter_until_input = zz.TextInput.init(a),
        .filter_path_input = zz.TextInput.init(a),
        .filter_modal = zz.Modal.init(),
        .spawn_fn = spawnSync,
    };
    g_app_ready = true;
    return &g_app;
}

/// makeTestApp の後始末。zz 系も含め全解放する。
fn freeTestApp(app: *App) void {
    app.model.deinit();
    app.queue.deinit(app.gpa);
    app.textarea.deinit();
    app.filter_author_input.deinit();
    app.filter_since_input.deinit();
    app.filter_until_input.deinit();
    app.filter_path_input.deinit();
    app.test_staged.deinit(app.gpa);
    g_app_ready = false;
}

/// staged 結果を test_staged へ追加するヘルパー（dupe して所有）。
fn stage(app: *App, msg: Msg) !void {
    try app.test_staged.append(app.gpa, msg);
}

test "dispatchSideEffect sets busy and in-flight worker" {
    const a = std.testing.allocator;
    const app = try makeTestApp();
    defer freeTestApp(app);
    try std.testing.expect(!app.model.busy);
    dispatchSideEffect(app, .refresh_status);
    try std.testing.expect(app.model.busy);
    try std.testing.expect(app.worker != null);
}

test "reapWorker clears busy and worker after done" {
    const a = std.testing.allocator;
    const app = try makeTestApp();
    defer freeTestApp(app);
    dispatchSideEffect(app, .refresh_status); // spawnSync: 結果無し・done=true
    try std.testing.expect(app.worker != null);
    reapWorker(app); // takeWorkerDone=true・join 無し(thread=null)・busy=false
    try std.testing.expect(!app.model.busy);
    try std.testing.expect(app.worker == null);
}

test "sync fallback (spawnAsync failure path) clears busy" {
    // spawnAsync の catch 経路を直接呼んで、workerRun 後に busy/working が下りることを検証。
    const a = std.testing.allocator;
    const app = try makeTestApp();
    defer freeTestApp(app);
    app.model.busy = true; // dispatchSideEffect が立てた状態を模倣
    app.model.working = true;
    app.spawn_fn = spawnAsync; // spawn は実環境でしか成功しない→ここでは catch へ
    spawnAsync(app, .refresh_status); // spawn 失敗 → 同期フォールバック
    try std.testing.expect(!app.model.busy);
    try std.testing.expect(!app.model.working);
    try std.testing.expect(app.worker == null);
    // workerRun が push した結果（git_error・appcmd.run 失敗）を片付ける
    var local: std.ArrayList(Msg) = .empty;
    defer local.deinit(a);
    app.queue.drain(app.io, a, &local);
    for (local.items) |*m| m.deinit(a);
}

test "pending is latest-wins while worker in-flight" {
    const a = std.testing.allocator;
    const app = try makeTestApp();
    defer freeTestApp(app);
    dispatchSideEffect(app, .refresh_status); // worker 在飛
    dispatchSideEffect(app, .load_diff); // pending へ
    try std.testing.expect(app.pending != null);
    try std.testing.expect(app.pending.? == .load_diff);
    dispatchSideEffect(app, .refresh_status); // 上書き
    try std.testing.expect(app.pending.? == .refresh_status);
}
```

> 注: `sync fallback` テストでは `spawnAsync` を直接呼び `std.Thread.spawn` が失敗する（テスト環境でワーカー起動不可とは限らないが、`spawnAsync` の catch 経路は `workerRun` を呼び appcmd.run が git リポジトリ外で失敗 → `git_error` を push する）。push された結果は最後に drain して解放する。

- [ ] **Step 8: ビルドしてコンパイル確認**

Run: `zig build`
Expected: コンパイル成功（エラーがあれば型/所有権の不一致を修正）。

- [ ] **Step 9: テスト実行して green 確認**

Run: `zig build test --summary all`
Expected: 全件 PASS（既存 509 + 本タスクの新規 4 件）。`main.zig` の import でコンパイルエラーが出た場合は `makeTestApp` が最小 `App` のみ参照するよう隔離（zz フィールドの init を確認）。

- [ ] **Step 10: コミット**

```bash
git add src/main.zig src/root_test.zig
git commit -m "feat(main): injectable spawn seam + runtime-owned busy lifecycle

WorkerHandle(thread: ?std.Thread) で在飛状態を実 thread から切り離し、
App.spawn_fn(spawnAsync/spawnSync) で spawn を注入可能化。sync フォールバックで
busy/working を自前下ろす（reducer に頼らない）。所有権の runtime テストを追加。"
```

---

## Task 2: reducer busy 書き込み削除 + 不変テスト + M-N9 競合回帰テスト

Task 1 で runtime が busy を所有できる構造が整った。本タスクで reducer の冗長な `busy=false` 4 箇所を削除し、競合を構造的に排除する。TDD: まず red（不変テスト・競合テストが失敗）→ 削除で green。

**Files:**
- Modify: `src/update.zig`（`:240,245,257,269` の 4 行削除・既存テスト `:1165-1179` 修正・新規テスト）
- Modify: `src/main.zig`（新規 M-N9 競合回帰テスト）

**Interfaces:**
- Consumes: Task 1 の `spawnSync`/`test_staged`/`makeTestApp`/`reapWorker`/`dispatchSideEffect`・`update.update`（`src/update.zig:21`）。
- Produces: reducer が busy を書かない不変（以降のタスクが依存）。

- [ ] **Step 1: busy 不変テストを追加（red）**

`src/update.zig` の既存テスト `git_error preserves file list …`（`:1165`）の直後に 3 つの不変テストを追加:

```zig
test "reducer leaves busy untouched on status_loaded" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.busy = true;
    var cmd = try update(&m, .{ .status_loaded = &.{} });
    defer cmd.deinit(a);
    try std.testing.expect(m.busy); // reducer は busy を下ろさない
}

test "reducer leaves busy untouched on diff_loaded" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.busy = true;
    var msg = Msg{ .diff_loaded = try a.dupe(u8, "diff --git a/x b/x\n") };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expect(m.busy);
}

test "reducer leaves busy untouched on committed" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.busy = true;
    var cmd = try update(&m, .committed);
    defer cmd.deinit(a); // .refresh_status
    try std.testing.expect(m.busy);
}
```

- [ ] **Step 2: テスト実行して red 確認**

Run: `zig build test --summary all`
Expected: FAIL — 上記 3 テストが `m.busy == true` で失敗（reducer が現在 busy を false にするため）。

- [ ] **Step 3: M-N9 競合回帰テストを追加（red）**

`src/main.zig` 末尾（Task 1 のテスト群の後）へ追加:

```zig
/// M-N9 競合回帰: 旧 worker の stale git_error が drain されても、新 worker の busy が
/// 早落としされないことを決定的に検証する（spec §6.2）。
test "M-N9 race: stale drained git_error does not clear new worker busy" {
    const a = std.testing.allocator;
    const app = try makeTestApp();
    defer freeTestApp(app);

    // worker A の結果として stale git_error を stage
    try stage(app, .{ .git_error = try a.dupe(u8, "fatal: stale A") });
    dispatchSideEffect(app, .refresh_status); // A 在飛・busy=true・queue=[git_error_A]・done=true

    // worker B の結果を stage した上で、A 在飛中に新副作用 → pending=B
    try stage(app, .{ .git_error = try a.dupe(u8, "fatal: fresh B") });
    dispatchSideEffect(app, .refresh_status); // worker!=null → pending=B（busy 変わらず true）

    reapWorker(app); // A 回収 → busy=false → pending B dispatch → spawnSync で B 結果 push・busy=true
    try std.testing.expect(app.model.busy); // B 仍在飛
    try std.testing.expect(app.worker != null);

    // drainQueue 相当: キュー結果を reducer へ流す（program 不要・update を直接呼ぶ）
    var local: std.ArrayList(Msg) = .empty;
    defer local.deinit(a);
    app.queue.drain(app.io, a, &local);
    for (local.items) |m| {
        var c = update.update(&app.model, m) catch unreachable;
        c.deinit(a);
        try std.testing.expect(app.model.busy); // ← 修正前はここで false（バグ）
    }
    for (local.items) |*m| m.deinit(a);

    try std.testing.expect(app.model.busy); // 最終的に B の busy は生存
}
```

- [ ] **Step 4: テスト実行して red 確認**

Run: `zig build test --summary all`
Expected: FAIL — `M-N9 race` テストが `app.model.busy` で失敗（reducer の git_error arm が busy を false にするため）。

- [ ] **Step 5: reducer の busy 書き込み 4 箇所を削除**

`src/update.zig` の以下 4 行を削除（周辺コードは維持）:

- `:240`（`.status_loaded` arm 内）の `model.busy = false;`
- `:245`（`.diff_loaded` arm 内）の `model.busy = false;`
- `:257`（`.git_error` arm 内）の `model.busy = false;`
- `:269`（`.committed` arm 内）の `model.busy = false;`

例（`:239-243` status_loaded arm は削除後こうなる）:
```zig
        .status_loaded => |entries| {
            try model.replaceFiles(entries);
            return loadDiffCmd(model);
        },
```

- [ ] **Step 6: 既存テスト `git_error preserves …` を修正**

`src/update.zig:1165-1179` を以下へ置換（`!m.busy` 表明を `m.busy` へ・テスト名から `/busy` を削除）:

```zig
test "git_error preserves file list and only sets error_text" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "a", .unstaged);
    try addFile(&m, "b", .unstaged);
    m.busy = true;
    var msg = Msg{ .git_error = try a.dupe(u8, "fatal: boom") };
    defer msg.deinit(a);
    var cmd = try update(&m, msg);
    defer cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), m.files.items.len); // ファイル一覧は保持
    try std.testing.expect(m.busy); // reducer は busy を触らない（runtime 所有）
    try std.testing.expectEqualStrings("fatal: boom", m.error_text);
}
```

- [ ] **Step 7: stale コメントを更新**

`src/main.zig:170-179` 付近（`spawnAsync` 内のコメント）は Step 2 で既に更新済み。`dispatchSideEffect` の旧コメント（元 `:159-160`）も Step 2 で置換済み。念のため `main.zig` 内に「busy は reducer 結果で下りる」の記述が残っていないか確認（`update.zig` 側に phase3a §4.8 の「busy=false は維持」記述があれば「reducer は触らない」へ整合）。

- [ ] **Step 8: テスト実行して green 確認**

Run: `zig build test --summary all`
Expected: 全件 PASS（既存 + Task 1 + 本タスクの不変テスト 3 件 + 競合回帰テスト 1 件）。

- [ ] **Step 9: コミット**

```bash
git add src/update.zig src/main.zig
git commit -m "fix(update): make busy runtime-owned, remove reducer writes (M-N9)

reducer の busy=false 4 箇所(status_loaded/diff_loaded/git_error/committed)を削除。
busy は dispatchSideEffect/reapWorker/sync フォールバックのみが所有。stale 結果の
drain が新 worker の busy を早落としする M-N9 競合を構造的に排除。不変テスト +
決定的競合回帰テストを追加。"
```

---

## Task 3: TODO.md 更新 + 最終検証

**Files:**
- Modify: `TODO.md:198`

- [ ] **Step 1: TODO.md の #4 チェックボックスを更新**

`TODO.md:198` を `[ ]` → `[x]` へ:

```markdown
- [x] busy lifecycle 完全修正（runtime lifecycle（main の `reapWorker`/`dispatchSideEffect`）のみで busy を管理・reducer で busy を触らない・M-N9・phase3a は log 中 git_error 無視で最小対処）: `App.spawn_fn`/`WorkerHandle` seam で spawn 注入可能化・sync フォールバックで busy 自前下ろし・reducer busy 書き込み 4 箇所削除・M-N9 競合回帰テスト追加（決定的）。spec: `docs/superpowers/specs/2026-06-24-todo2-busy-lifecycle-design.md`。
```

- [ ] **Step 2: 全テスト再実行**

Run: `zig build test --summary all`
Expected: 全件 PASS。

- [ ] **Step 3: ビルド確認**

Run: `zig build`
Expected: 成功。

- [ ] **Step 4: コミット**

```bash
git add TODO.md
git commit -m "docs(todo): mark phase 3b #4 busy lifecycle complete"
```

- [ ] **Step 5: 手動検証（tmux pty・AGENTS.md 手順）**

git リポジトリ内で TUI を起動し、フィルタ切替中に高速で `Ctrl+S`/`s`/`H` を連打し、二重実行・ハング・spinner 貼り付きがないことを目視確認（オプション・非ブロッカー）。

---

## Self-Review

**1. Spec coverage:**
- §2 核心不変（reducer は busy を書かない）→ Task 2 Step 5。
- §3 runtime 所有権規則（dispatch=true/reap=false/sync-fallback=false/seed=既存）→ Task 1 Step 2-3（sync-fallback）・Task 2（reducer 削除で runtime 専有化）。
- §3.1 sync フォールバック busy 下ろし → Task 1 Step 2（spawnAsync catch）。
- §3.2 committed フロー → Task 2 Step 1（committed 不変テストで検証: busy 维持・refresh_status 再 dispatch）。
- §4 seam（WorkerHandle/spawn_fn/spawnSync/reapWorker 書き直し）→ Task 1 Step 1-3。
- §5 reducer 変更 4 行削除 → Task 2 Step 5。
- §6.1 純粋層テスト（不変 4 種・1165 修正・ガード据え置き）→ Task 2 Step 1/6（git_error は 1165 修正でカバー・status_loaded/diff_loaded/committed は新規 3 テスト）。
- §6.2 runtime テスト（makeTestApp/競合回帰/所有権）→ Task 1 Step 7（所有権）・Task 2 Step 3（競合回帰）。
- §9 受け入れ基準 1-5 → Task 1/2/3。6（tmux）→ Task 3 Step 5。
- §10 D1（sync フォールバック busy=false は workerRun 後）→ Task 1 Step 2 のコード順序（busy=false → workerRun）。D2（spawn_fn は main() で明示設定）→ Task 1 Step 4。

**2. Placeholder scan:** なし。全 Step に具体コード/コマンド/期待値あり。

**3. Type consistency:**
- `WorkerHandle`（Task 1 Step 1）↔ `app.worker: ?WorkerHandle` ↔ `.{ .thread = handle }`/`.{ .thread = null }`（Step 2）↔ `if (app.worker) |w| ... w.thread`（Step 3）→ 整合。
- `App.spawn_fn: *const fn(*App, AppCmd) void` ↔ `spawnAsync`/`spawnSync` のシグネチャ（`fn(*App, AppCmd) void`）→ 整合。
- `App.test_staged: std.ArrayList(Msg)` ↔ `orderedRemove`/`append`/`deinit` → 整合。
- `update.update(model: *Model, msg: Msg) !AppCmd`（`src/update.zig:21`）↔ テストの `update(&m, ...)` → 整合。
- `Msg` バリアント（`status_loaded: []StatusEntry`/`diff_loaded: []u8`/`committed`/`git_error: []u8`・`src/messages.zig:48,49,58`）↔ テストのリテラル → 整合。

**注記（実装者が留意すべき所有権の罠）:**
- `spawnSync` は `cmd.deinit(app.gpa)` する（cmd を実行しないので所有権解放）。`spawnAsync` 成功時は `workerThread`→`workerRun` が cmd を deinit する（既存）。
- `spawnSync` の `orderedRemove` は Msg の所有権を queue へ移譲（staged 側は解放済み）。テストで staged Msg を二重解放しないこと。
- 不変テストで `.{ .status_loaded = &.{} }` は msg を deinit しない（既存 `src/update.zig:1524` と同パターン・`&.{}` はヒープ非所有）。`diff_loaded`/`git_error` は `defer msg.deinit(a)` で解放（`update` は payload を複製して消費しない・`src/main.zig:205` の step() と同）。
