# 実行中の自動 status リフレッシュ 実装計画

**Goal:** git-tui 実行中に作業ツリーが外部で変化したら、再起動や手動 `r` なしで Changes 一覧（および閲覧中ファイルの diff）が自動更新されるようにする。

**方式:** 既存の tick（`zz.Cmd.everyMs(33)`）に相乗りし、**worker 非稼働かつ pending 無しのとき、前回から一定間隔（1500ms）経過していれば `refresh_status` を発火**する。WSL2 では inotify が 9p 境界で不安定なため、定期ポーリングを採用（既存 tick 流用で堅牢）。

**磨き込み（advisor 指摘・必須）:**
1. 自動ポーリングは **busy スピナを点滅させない**（`model.busy` を立てずに worker spawn）。直列化は `app.worker` で担保、`reapWorker` が busy を無条件クリアするので安全。
2. 選択を **(section, path) で維持**（インデックスのみのクランプだとファイル出現/消滅時に別ファイルへジャンプする）。`replaceFiles` を改修（手動 `r` にも効く一般改善）。
3. status＋diff の両リロードは**維持**（閲覧中ファイルの diff もライブ更新される。内容不変なら視覚的に安定）。

**スロットル判定は純粋関数に切り出してテスト**（main.zig は root_test 非対象のため、新規 `src/autorefresh.zig` に置く）。

**ブランチ:** 現在の `feat/partial-staging-hunk` に積む（partial-staging とは別関心だが未マージ・同一セッション継続のため）。

**重要な housekeeping:** 作業ツリーの `README.md`（`MM` = ユーザのデモ/テスト変更）は**絶対に触らない**。`git add` は下記の対象ソースファイルのパスのみを明示指定し、`git add -A`/`git commit -am` は使わない。

---

## Task A: `src/autorefresh.zig`（純粋スロットル判定・新規）

**Files:** Create `src/autorefresh.zig` / Modify `src/root_test.zig`

新規 `src/autorefresh.zig` を以下の内容で作成:

```zig
//! 自動 status リフレッシュのスロットル判定（純粋・zigzag/git 非依存）。
//! main の tick ハンドラから呼ぶ。worker 稼働中 / pending 退避ありのときは抑止し、
//! それ以外は前回 dispatch から interval_ms 以上経過していれば true。
const std = @import("std");

/// 自動 status リフレッシュを今 dispatch すべきか。
/// - worker_active: ワーカースレッドが稼働中（直列化中）なら true
/// - pending_active: 退避中の副作用がある（latest-wins）なら true
/// どちらかが true なら抑止（ポーリングを積まない・直列化を乱さない）。
/// それ以外は now_ms - last_ms >= interval_ms で判定。
pub fn shouldAutoRefresh(
    now_ms: i64,
    last_ms: i64,
    interval_ms: i64,
    worker_active: bool,
    pending_active: bool,
) bool {
    if (worker_active or pending_active) return false;
    return now_ms - last_ms >= interval_ms;
}

test "shouldAutoRefresh: skips while worker active" {
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, true, false));
}

test "shouldAutoRefresh: skips while pending active" {
    try std.testing.expect(!shouldAutoRefresh(10_000, 0, 1500, false, true));
}

test "shouldAutoRefresh: fires when idle and interval elapsed" {
    try std.testing.expect(shouldAutoRefresh(1500, 0, 1500, false, false)); // 境界ちょうど
    try std.testing.expect(shouldAutoRefresh(5000, 1000, 1500, false, false));
}

test "shouldAutoRefresh: holds when interval not elapsed" {
    try std.testing.expect(!shouldAutoRefresh(1499, 0, 1500, false, false));
    try std.testing.expect(!shouldAutoRefresh(2000, 1000, 1500, false, false));
}

test {
    std.testing.refAllDecls(@This());
}
```

`src/root_test.zig` の `test {}` ブロックに 1 行追加（`_ = @import("diff/hunk.zig");` の直後など末尾）:

```zig
    _ = @import("autorefresh.zig"); // 自動リフレッシュ
```

確認: `zig build test --summary all` → green。
コミット: `git add src/autorefresh.zig src/root_test.zig` のみ → `git commit -m "feat(autorefresh): 自動 status リフレッシュのスロットル判定を追加"`

---

## Task B: `src/model.zig` の `replaceFiles` を選択 (section,path) 維持に改修

**Files:** Modify `src/model.zig`

現在の `replaceFiles` は選択をインデックスでクランプするだけで、ファイルが増減すると別ファイルへ選択がジャンプする。置換前の選択 (section, path) を控え、新リストで同一 (section, path) を再探索して選択を維持する（見つからなければ従来どおりインデックスクランプにフォールバック）。

### Step 1: 失敗テストを追加
`src/model.zig` の既存テスト群の末尾（`test "replaceFiles sorts by section..."` の後）に追加:

```zig
test "replaceFiles preserves selection by (section, path) across refresh" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    // 初回: 3 ファイル（unstaged a, b, c）。選択を b（index 1）にする。
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "c.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    m.selected = 1; // b.txt
    // リフレッシュ: 先頭に新ファイル z(staged) が増え、表示順が変わる。b.txt は unstaged のまま。
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "z.txt"), .orig_path = null, .section = .staged },
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "c.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    // 選択は b.txt を追従しているべき（index ではなく path で維持）。
    try std.testing.expectEqualStrings("b.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.unstaged, m.files.items[m.selected].section);
}

test "replaceFiles falls back to index clamp when selected file is gone" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "b.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    m.selected = 1; // b.txt
    // b.txt が消えて a.txt だけ → b は見つからず、selected は新 len にクランプ（0）。
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "a.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    try std.testing.expectEqual(@as(usize, 0), m.selected);
    try std.testing.expectEqualStrings("a.txt", m.files.items[m.selected].path);
}
```

### Step 2: テスト失敗を確認
`zig build test --summary all` → 1 つ目の新テストが FAIL（現状はインデックスクランプで b を追従しない）。

### Step 3: `replaceFiles` を改修
`src/model.zig` の `replaceFiles` を以下に置き換える（既存のロジックを保ちつつ、選択維持を追加）:

```zig
    pub fn replaceFiles(self: *Model, entries: []const status.StatusEntry) !void {
        const a = self.allocator;
        // 置換前の選択ファイル識別子（section + path）を控える。path は旧 files を指す借用 slice。
        // next 構築〜照合は旧 files 解放より前に行うので安全（解放後に prev は使わない）。
        const prev: ?struct { section: status.Section, path: []const u8 } =
            if (self.selected < self.files.items.len)
                .{ .section = self.files.items[self.selected].section, .path = self.files.items[self.selected].path }
            else
                null;

        var next: std.ArrayList(FileItem) = .empty;
        errdefer {
            for (next.items) |*f| {
                a.free(f.path);
                if (f.orig_path) |p| a.free(p);
            }
            next.deinit(a);
        }
        for (entries) |e| {
            const path = try a.dupe(u8, e.path);
            errdefer a.free(path);
            const orig: ?[]u8 = if (e.orig_path) |p| try a.dupe(u8, p) else null;
            errdefer if (orig) |o| a.free(o);
            try next.append(a, .{ .path = path, .orig_path = orig, .section = e.section });
        }
        std.mem.sort(FileItem, next.items, {}, lessThanForDisplay);

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

        // ここまで来れば成功。旧 files を解放して入れ替える（以降 prev.path は使わない）。
        for (self.files.items) |*f| {
            a.free(f.path);
            if (f.orig_path) |p| a.free(p);
        }
        self.files.deinit(a);
        self.files = next;
        self.selected = if (self.files.items.len == 0) 0 else @min(new_selected, self.files.items.len - 1);
    }
```

注意: 既存コメント（section→path ソート・トランザクショナル）の意図は保つこと。既存テスト（`replaceFiles copies entries` / `sorts by section`）は旧 files が空（selected 0 >= len 0 → prev=null）なので不変。

### Step 4: テスト green 確認
`zig build test --summary all` → 全 green（新 2 テスト含む）。
コミット: `git add src/model.zig` のみ → `git commit -m "feat(model): replaceFiles で選択を (section,path) 維持（リフレッシュ時のジャンプ防止）"`

---

## Task C: `src/main.zig` に自動リフレッシュを配線

**Files:** Modify `src/main.zig`

main.zig は zigzag 統合点で自動テスト無し（Task A の純粋判定でロジックは担保済み）。以下を実装する。

### Step 1: import と定数
ファイル冒頭の import 群（`const process = @import("git/process.zig");` の後など）に追加:
```zig
const autorefresh = @import("autorefresh.zig");
```
適当な file-scope 定数定義位置（`var g_app: App = undefined;` 付近の前後）に追加:
```zig
/// 自動 status リフレッシュの最短間隔（ms）。worker 非稼働かつ pending 無しのときのみ発火。
const auto_refresh_interval_ms: i64 = 1500;
```

### Step 2: App に最終リフレッシュ時刻フィールドを追加
`App` struct（`pending: ?AppCmd = null,` の後）に追加:
```zig
    /// 自動リフレッシュの前回 dispatch 時刻（ms）。tick で間引くために使う。
    last_auto_refresh_ms: i64 = 0,
```
（`App` は既に queue/worker/pending にデフォルトを持つので、main() の `g_app = App{...}` リテラルは変更不要＝デフォルト 0 が使われる。）

### Step 3: `dispatchSideEffect` に busy 抑止フラグを追加
`dispatchSideEffect` のシグネチャに `set_busy: bool` を足し、busy 設定を条件化する:
```zig
fn dispatchSideEffect(app: *App, cmd: AppCmd, set_busy: bool) void {
    if (app.worker != null) {
        if (app.pending) |*p| p.deinit(app.gpa);
        app.pending = cmd;
        return;
    }
    if (set_busy) app.model.busy = true; // 自動リフレッシュ（set_busy=false）はスピナを点滅させない。
    app.worker = std.Thread.spawn(.{}, workerThread, .{ app, cmd }) catch {
        app.worker = null;
        workerRun(app, cmd);
        return;
    };
}
```
既存の呼び出し元 2 箇所を `set_busy=true` に更新:
- `applyAppCmd` 内の `dispatchSideEffect(app, cmd)` → `dispatchSideEffect(app, cmd, true)`
- `reapWorker` 内の `dispatchSideEffect(app, next)` → `dispatchSideEffect(app, next, true)`

（`dispatchSideEffect` を呼ぶ箇所を grep で全数確認し、すべて引数 3 つに更新すること。）

### Step 4: `maybeAutoRefresh` を実装し tick で呼ぶ
`reapWorker` の近くに追加:
```zig
/// tick ごとに呼ぶ: worker 非稼働かつ pending 無しで前回から間隔経過していれば、
/// busy を立てずに（スピナを点滅させずに）status を再読込する。外部のファイル変更を
/// 再起動なしで反映するための定期ポーリング（WSL2 では inotify 不安定のため採用）。
fn maybeAutoRefresh(app: *App) void {
    const now = nowMs(app);
    if (!autorefresh.shouldAutoRefresh(now, app.last_auto_refresh_ms, auto_refresh_interval_ms, app.worker != null, app.pending != null)) return;
    app.last_auto_refresh_ms = now;
    dispatchSideEffect(app, .refresh_status, false); // silent（busy を立てない）
}
```
`RuntimeModel.update` の `.tick` アームを以下に更新（`reapWorker`/`drainQueue` の後に `maybeAutoRefresh` を追加）:
```zig
            .tick => {
                // ワーカー完了を回収し、キューを drain して reducer に流す。
                reapWorker(app);
                drainQueue(app, program);
                // 外部のファイル変更を再起動なしで反映する定期ポーリング（間引き済み・busy 非点灯）。
                maybeAutoRefresh(app);
            },
```

### Step 5: ビルド確認
`zig build` 成功・`zig build test --summary all` 全 green。
コミット: `git add src/main.zig` のみ → `git commit -m "feat(main): tick で外部変更を自動反映（busy 非点灯のスロットル付きポーリング）"`

---

## 受け入れ基準（behavioral・tmux で確認）
1. git-tui 実行中に別シェルでファイルを変更すると、約 1.5 秒以内に Changes 一覧へ反映される（再起動・`r` 不要）。
2. アイドル時にステータスバーの `[busy]` スピナが点滅しない。
3. アイドル時に選択（カーソル）が別ファイルへ勝手にジャンプしない（同一ファイルが残る限り選択維持）。
4. 閲覧中ファイルを外部で変更すると、その diff もライブ更新される。
5. Ctrl+S（コミット）が自動ポーリング中に来てもコミットは 1 回だけ（pending latest-wins で直列化）。
6. 既存のファイル単位/ハンク単位 stage・コミット・マウス・スクロールは不変。121+ テスト green。

## 既知の留意点
- git status + git diff が 1.5 秒ごとに再実行される（通常リポジトリでは軽微）。大規模リポジトリで重い場合は間隔調整。
- 真の即時反映ではなく最大 1.5 秒の遅延。
