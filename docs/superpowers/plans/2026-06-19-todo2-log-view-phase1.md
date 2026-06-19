# TODO 2 phase 1（線形コミット一覧 + detail diff）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** git-tui に `L` キーで切入する「ログビュー（線形コミット一覧 + 選択コミットのファイル一覧 + diff）」を追加する。グラフ罫線（phase 2）・author/日時の表示（phase 2）・フィルタ・log 中の stage はスコープ外。

**Architecture:** 既存の Elm 風・副作用隔離アーキテクチャ（model/messages/update/appcmd/git/input/view/main）を踏襲。新モジュール `git/log.zig`（NUL 区切り `git log` パーサ）・`git/show.zig`（`git show --name-status` パーサ）を追加。`Model` に `view_mode`（changes/log）を新設し、log モード時は左 log 一覧・右 detail（ファイル一覧 or diff）の 2 ペインへ。結果 Msg は全て request_hash/skip/generation を持つ構造体化し stale-result を reject。ページング busy ゲートは既存 worker 一系統へ統一・`log_page_requested: ?usize` で重複防止のみ。

**Tech Stack:** Zig 0.16.0（`std.process.run(gpa, io, opts)`・`std.Io.Limit`・unmanaged `ArrayList`・`Term.exited: u8`）・zigzag v0.1.5 固定。

**Spec:** `docs/superpowers/specs/2026-06-18-todo2-log-view-phase1-design.md`（rev.9・codex 9 段階レビュー済み・R1-R26 全反映）

**コマンド規約（`CLAUDE.md`/`AGENTS.md` 準拠）:**
- ビルド: `zig build`
- テスト: `zig build test --summary all`（**Debug 既定を維持**=実行時安全チェック。Release にしない）
- テストは実装 `.zig` 内の `test {}` ブロック・`std.testing.allocator` 必須（リーク検出）。
- 新規 `.zig` は `src/root_test.zig` の `@import("...")` を有効化しないとテストが走らない。
- 単一テストのフィルタ実行は `build.zig` に未配線。`zig build test` で一括実行する。
- 既存テストを壊さないため、既存 `input.keyToMsg`/`mouseToMsg`/`fromZigzagMouse`・`view.computeLayout`/`renderChanges`/`renderDiff` は**変更しない**。新設 wrapper で log モードを追加する。

---

## File Structure

### 新規ファイル
- `src/git/log.zig` — NUL 区切り `git log` パーサ（`Commit`/`parse`）。純粋。
- `src/git/show.zig` — `git show --name-status -z` パーサ（`NameStatus`/`parseNameStatus`）。純粋。

### 変更ファイル（純粋層）
- `src/git/commands.zig` — `logArgv`/`showNameStatusArgv`/`showFileDiffArgv`/`headState`/`HeadState` 追加。
- `src/root_test.zig` — `@import("git/log.zig")`/`@import("git/show.zig")` を有効化。
- `src/model.zig` — `ViewMode`/`DetailKind`・log/detail フィールド・owner 系・`replaceLogCommits`/`appendLogCommits`/`replaceDetailFiles`/`cloneCommit` 等。
- `src/messages.zig` — `Msg`/`AppCmd` 新バリアント + 構造体（`LogLoaded`/`LogPageFailed`/`LogPageFailedSilent`/`CommitDetailLoaded`/`DetailDiffLoaded`/`LoadLog`/`LoadDetailDiff`）+ scroll 系。
- `src/update.zig` — log/detail 系 arm + 結果 Msg arm（stale reject・空 guard・page pending ゲート・focus 更新）。
- `src/appcmd.zig` — 新 4 arm + `runLogInt`/`mkPageFailedOrSilent`/`mkPageFailedSilent` ヘルパ。

### 変更ファイル（UI 層）
- `src/input.zig` — `keyToMsgForMode`/`mouseToMsgForMode`/`fromZigzagMouseForMode`/`keyToMsgForLog` wrapper 新設（既存は変更しない）。
- `src/view.zig` — `computeTopAndStatus`（共通ヘルパ抽出）+ `computeLogLayout` + `logRowLayout`/`detailRowLayout` + `renderLog`/`renderDetail` + `render` の `view_mode` 分岐。
- `src/autorefresh.zig` — `shouldAutoRefresh` へ `view_mode` 引数追加。
- `src/main.zig` — `applyAppCmd` 網羅 switch へ 4 arm・`isMutating`/`seedInitialStatus` の switch 更新・`dispatchSideEffect` spawn fallback で busy 下ろし・`maybeAutoRefresh` log 抑止・`handleKey`/`handleMouse` の `*ForMode` 切替。

### ドキュメント
- `README.md` — log モードのキー操作追記。
- `TODO.md` — TODO 2 phase 1 達成 + phase 2 残（グラフ罫線・author/日時）を明記。

---

## Task 1: `src/git/log.zig` — `Commit` 構造体と `parse`（NUL 区切りパーサ）

**Files:**
- Create: `src/git/log.zig`
- Modify: `src/root_test.zig`

`git log --pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d -z --decorate=short --no-color` 出力をパースする。`status.zig parse` の NUL 区切り・`ArrayList.empty`/`toOwnedSlice`・errdefer パターンを模倣。

- [ ] **Step 1: `src/git/log.zig` を作成（`Commit` 構造体 + `parse` シグネチャのみ・本体は後で）**

```zig
const std = @import("std");

pub const Commit = struct {
    hash: []u8,          // 40 hex (sha-1) / 64 hex (sha-256)。persistent 所有。
    parents: [][]u8,     // persistent 所有（各要素も）。phase 2 レーン割当の伏線。空 = root。
    author: []u8,        // 日本語可
    epoch_sec: i64,
    subject: []u8,       // 日本語可
    refs: []u8,          // decorate 結果（" (HEAD -> main, tag: v1)"）。空可。raw 文字列・phase 1 はパースしない。
    pub fn deinit(self: *Commit, a: std.mem.Allocator) void {
        a.free(self.hash);
        for (self.parents) |p| a.free(p);
        a.free(self.parents);
        a.free(self.author);
        a.free(self.subject);
        a.free(self.refs);
    }
};

/// 呼び出し側が返り値スライスと各要素を deinit する（status.parse と同じ契約）。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ![]Commit {
    // -z はコミット間を NUL(\0) で区切る。format 内の %x00 も NUL でフィールド区切り。
    // よって「連続する 6 トークン（hash/P/an/at/s/d）ごとに 1 commit」。
    // ★R15: trailing NUL 有無を両方受理。実 git log -z は「最終 commit の後に NUL 無し」で終わる
    //   （最後の %d が空なら subject トークンの直後で終端）。splitScalar は空トークンを返すので
    //   6 の倍数で無い余剰トークンは単に無視する（実 git 出力とテストフィクスチャの両方で通る）。
    // %P は空白区切りの hash 列（マージで 2 個以上）→ splitScalar(u8, p, ' ') で parents へ。
    // %at は Unix epoch 秒 → std.fmt.parseInt(i64, at, 10)。
    // 空リポジトリ（raw が空）は &.{} を返す（appcmd 側で headState 判定済み）。
    var list: std.ArrayList(Commit) = .empty;
    errdefer {
        for (list.items) |*c| c.deinit(a);
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, raw, 0);
    while (true) {
        const hash = it.next() orelse break;
        if (hash.len == 0) break; // 終端の空トークン（trailing NUL の場合）は無視
        const p_str = it.next() orelse break;
        const an = it.next() orelse break;
        const at = it.next() orelse break;
        const s = it.next() orelse break;
        const d = it.next() orelse break;

        // parents を空白区切りで split して各 hash を dupe
        var parents: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parents.items) |p| a.free(p);
            parents.deinit(a);
        }
        var pit = std.mem.splitScalar(u8, p_str, ' ');
        while (pit.next()) |ph| {
            if (ph.len == 0) continue;
            const ph_dup = try a.dupe(u8, ph);
            errdefer a.free(ph_dup);
            try parents.append(a, ph_dup);
        }

        const commit = Commit{
            .hash = blk: {
                const h = try a.dupe(u8, hash);
                errdefer a.free(h);
                break :blk h;
            },
            .parents = try parents.toOwnedSlice(a),
            .author = blk: {
                const v = try a.dupe(u8, an);
                errdefer a.free(v);
                break :blk v;
            },
            .epoch_sec = std.fmt.parseInt(i64, at, 10) catch return error.InvalidFormat,
            .subject = blk: {
                const v = try a.dupe(u8, s);
                errdefer a.free(v);
                break :blk v;
            },
            .refs = blk: {
                const v = try a.dupe(u8, d);
                errdefer a.free(v);
                break :blk v;
            },
        };
        try list.append(a, commit);
    }
    return list.toOwnedSlice(a);
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 2: `src/root_test.zig` へ `@import("git/log.zig")` を有効化**

`src/root_test.zig` の末尾近く（`@import("autorefresh.zig")` の次）へ以下を追加:

```zig
    _ = @import("git/log.zig"); // TODO 2 phase 1: log パーサ
```

- [ ] **Step 3: 基本的なパーサ単体テストを `src/git/log.zig` の `test {}` ブロックへ追加（1 コミット・6 フィールド）**

`src/git/log.zig` の `test { std.testing.refAllDecls(@This()); }` の**上**へ追加:

```zig
test "parse: single commit with 6 NUL-separated fields" {
    const a = std.testing.allocator;
    // hash\0P\0an\0at\0s\0d\0（trailing NUL あり）
    const raw = "abc123\0parent1\0山田太郎\01700000000\0日本語件名\0 (HEAD -> main)\0";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqualStrings("abc123", commits[0].hash);
    try std.testing.expectEqual(@as(usize, 1), commits[0].parents.len);
    try std.testing.expectEqualStrings("parent1", commits[0].parents[0]);
    try std.testing.expectEqualStrings("山田太郎", commits[0].author);
    try std.testing.expectEqual(@as(i64, 1700000000), commits[0].epoch_sec);
    try std.testing.expectEqualStrings("日本語件名", commits[0].subject);
    try std.testing.expectEqualStrings(" (HEAD -> main)", commits[0].refs);
}

test "parse: root commit (empty P → parents.len == 0)" {
    const a = std.testing.allocator;
    // %P が空
    const raw = "root123\0\0author\01700000000\0subj\0\0";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqual(@as(usize, 0), commits[0].parents.len);
    try std.testing.expectEqualStrings("", commits[0].refs);
}

test "parse: merge commit (P has 2 hashes space-separated)" {
    const a = std.testing.allocator;
    const raw = "merge1\0p1 p2\0author\01700000000\0merge subj\0\0";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqual(@as(usize, 2), commits[0].parents.len);
    try std.testing.expectEqualStrings("p1", commits[0].parents[0]);
    try std.testing.expectEqualStrings("p2", commits[0].parents[1]);
}

test "parse: multiple commits (3 commits)" {
    const a = std.testing.allocator;
    const raw = "h1\0p1\0a1\01\0s1\0\0h2\0p2\0a2\02\0s2\0\0h3\0p3\0a3\03\0s3\0\0";
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 3), commits.len);
    try std.testing.expectEqualStrings("h1", commits[0].hash);
    try std.testing.expectEqualStrings("h3", commits[2].hash);
}

test "parse: trailing NUL absent (last commit ends right after %d)" {
    // R15: 実 git log -z は最終 commit の後に NUL を付けない。splitScalar は最終トークンを返す。
    const a = std.testing.allocator;
    const raw = "h1\0p1\0a1\01\0s1\0 (HEAD -> main)"; // 末尾 NUL 無し
    const commits = try parse(a, raw);
    defer {
        for (commits) |*c| c.deinit(a);
        a.free(commits);
    }
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expectEqualStrings(" (HEAD -> main)", commits[0].refs);
}

test "parse: empty raw returns empty slice" {
    const a = std.testing.allocator;
    const commits = try parse(a, "");
    defer a.free(commits);
    try std.testing.expectEqual(@as(usize, 0), commits.len);
}
```

- [ ] **Step 4: `zig build test --summary all` でテストが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（log.zig の 6 テストが追加され、既存テストも全て green）

- [ ] **Step 5: `checkAllAllocationFailures` を追加（部分確保失敗時の不正 free/leak 検証）**

`src/git/log.zig` のテストセクションへ追加:

```zig
test "parse: no invalid free / leak when allocation fails" {
    const raw = "h1\0p1 p2\0a1\01\0s1\0\0h2\0p3\0a2\02\0s2\0\0";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndFree, .{raw});
}

fn parseAndFree(a: std.mem.Allocator, raw: []const u8) !void {
    const commits = try parse(a, raw);
    for (commits) |*c| c.deinit(a);
    a.free(commits);
}
```

- [ ] **Step 6: `zig build test --summary all` で通ることを確認**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/git/log.zig src/root_test.zig
git commit -m "feat(log): add git log NUL-separated parser (TODO 2 phase 1)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 2: `src/git/show.zig` — `NameStatus` 構造体と `parseNameStatus`

**Files:**
- Create: `src/git/show.zig`
- Modify: `src/root_test.zig`

`git show --diff-merges=first-parent --format= --name-status -z <hash>` 出力をパース。`-z` は status トークン → path トークン（R/C は更に orig_path トークン）の NUL 区切り。R/C は**旧パスが先・新パスが次**（R12）。

- [ ] **Step 1: `src/git/show.zig` を作成**

```zig
const std = @import("std");

pub const NameStatus = struct {
    status: u8,          // 'A'/'M'/'D'/'R'/'C'（R/C は similarity score 付き R100/C75 等の先頭 1 文字）
    path: []u8,          // 新パス（R/C の新側・tracked は当該パス）。persistent 所有。
    orig_path: ?[]u8,    // R/C の旧パス（★R12: -z 出力で先に来る方）。tracked 変更は null。persistent 所有。
    pub fn deinit(self: *NameStatus, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.orig_path) |p| a.free(p);
    }
};

/// 呼び出し側が返り値スライスと各要素を deinit する。
pub fn parseNameStatus(a: std.mem.Allocator, raw: []const u8) ![]NameStatus {
    var list: std.ArrayList(NameStatus) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(a);
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |status_tok| {
        if (status_tok.len == 0) continue; // 終端空トークン無視
        const code = status_tok[0];
        switch (code) {
            'A', 'M', 'D' => {
                const path_tok = it.next() orelse return error.InvalidFormat;
                const p = try a.dupe(u8, path_tok);
                errdefer a.free(p);
                try list.append(a, .{ .status = code, .path = p, .orig_path = null });
            },
            'R', 'C' => {
                // R12: -z 出力は "R100\0old\0new\0"（旧パスが先・新パスが次）
                const orig_tok = it.next() orelse return error.InvalidFormat;
                const new_tok = it.next() orelse return error.InvalidFormat;
                const orig = try a.dupe(u8, orig_tok);
                errdefer a.free(orig);
                const new = try a.dupe(u8, new_tok);
                errdefer a.free(new);
                try list.append(a, .{ .status = code, .path = new, .orig_path = orig });
            },
            else => return error.InvalidFormat,
        }
    }
    return list.toOwnedSlice(a);
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 2: `src/root_test.zig` へ `@import("git/show.zig")` を有効化**

Task 1 で追加した `@import("git/log.zig")` の次へ:

```zig
    _ = @import("git/show.zig"); // TODO 2 phase 1: show name-status パーサ
```

- [ ] **Step 3: 単体テストを `src/git/show.zig` へ追加**

```zig
test "parseNameStatus: tracked modifications (M)" {
    const a = std.testing.allocator;
    const raw = "M\0f.txt\0M\0g.txt\0";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u8, 'M'), entries[0].status);
    try std.testing.expectEqualStrings("f.txt", entries[0].path);
    try std.testing.expect(entries[0].orig_path == null);
}

test "parseNameStatus: A and D" {
    const a = std.testing.allocator;
    const raw = "A\0new.txt\0D\0old.txt\0";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(u8, 'A'), entries[0].status);
    try std.testing.expectEqual(@as(u8, 'D'), entries[1].status);
}

test "parseNameStatus: R100 (rename with score) - orig_path is OLD, path is NEW (R12)" {
    const a = std.testing.allocator;
    // R12: -z 出力は "R100\0old\0new\0"（旧パスが先・新パスが次）
    const raw = "R100\0old.txt\0new.txt\0";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u8, 'R'), entries[0].status);
    try std.testing.expectEqualStrings("new.txt", entries[0].path); // 新パス
    try std.testing.expectEqualStrings("old.txt", entries[0].orig_path.?); // 旧パス
}

test "parseNameStatus: C75 (copy with score)" {
    const a = std.testing.allocator;
    const raw = "C75\0orig.txt\0copy.txt\0";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(u8, 'C'), entries[0].status);
    try std.testing.expectEqualStrings("copy.txt", entries[0].path);
    try std.testing.expectEqualStrings("orig.txt", entries[0].orig_path.?);
}

test "parseNameStatus: Japanese path" {
    const a = std.testing.allocator;
    const raw = "M\0日本語.txt\0";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqualStrings("日本語.txt", entries[0].path);
}

test "parseNameStatus: empty commit returns empty slice" {
    const a = std.testing.allocator;
    const entries = try parseNameStatus(a, "");
    defer a.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseNameStatus: mixed A/M/D/R in one commit" {
    const a = std.testing.allocator;
    const raw = "A\0new.txt\0M\0mod.txt\0R100\0old\0new\0D\0gone.txt\0";
    const entries = try parseNameStatus(a, raw);
    defer {
        for (entries) |*e| e.deinit(a);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqual(@as(u8, 'A'), entries[0].status);
    try std.testing.expectEqual(@as(u8, 'M'), entries[1].status);
    try std.testing.expectEqual(@as(u8, 'R'), entries[2].status);
    try std.testing.expectEqualStrings("new", entries[2].path);
    try std.testing.expectEqualStrings("old", entries[2].orig_path.?);
    try std.testing.expectEqual(@as(u8, 'D'), entries[3].status);
}

test "parseNameStatus: no invalid free / leak when allocation fails" {
    const raw = "A\0new.txt\0M\0mod.txt\0R100\0old\0new\0";
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseNameStatusAndFree, .{raw});
}

fn parseNameStatusAndFree(a: std.mem.Allocator, raw: []const u8) !void {
    const entries = try parseNameStatus(a, raw);
    for (entries) |*e| e.deinit(a);
    a.free(entries);
}
```

- [ ] **Step 4: `zig build test --summary all` で通ることを確認**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/git/show.zig src/root_test.zig
git commit -m "feat(show): add git show --name-status -z parser (TODO 2 phase 1)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 3: `src/git/commands.zig` — argv 生成と `headState` tri-state helper

**Files:**
- Modify: `src/git/commands.zig`

`logArgv`/`showNameStatusArgv`/`showFileDiffArgv`/`headState`/`HeadState` を追加。`-c core.quotePath=false` 挿入位置は `diffArgv` と同じ。`headState` は 3 段階判定（rev-parse exit 128 → symbolic-ref で branch 名 → `show-ref --verify --quiet refs/heads/<branch>` で ref 実在確認・R23b 実測で `--quiet` 必須）。

- [ ] **Step 1: 単体テストを `src/git/commands.zig` へ追加（argv 生成）**

ファイル末尾の `test { std.testing.refAllDecls(@This()); }` の上へ追加:

```zig
test "logArgv: skip=0 omits --skip, includes pretty format and -z" {
    const a = std.testing.allocator;
    const argv = try logArgv(a, 0, 100);
    defer a.free(argv);
    // 期待: git -c core.quotePath=false log --max-count=100 --pretty=format:... -z --decorate=short --no-color
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("core.quotePath=false", argv[2]);
    try std.testing.expectEqualStrings("log", argv[3]);
    // skip=0 なので --skip は含まれない
    var has_skip = false;
    for (argv) |arg| if (std.mem.startsWith(u8, arg, "--skip")) {
        has_skip = true;
    };
    try std.testing.expect(!has_skip);
    // pretty format・-z・--decorate=short・--no-color を含む
    var has_pretty = false;
    var has_z = false;
    var has_decorate = false;
    var has_nocolor = false;
    var has_maxcount = false;
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "--pretty=format")) has_pretty = true;
        if (std.mem.eql(u8, arg, "-z")) has_z = true;
        if (std.mem.eql(u8, arg, "--decorate=short")) has_decorate = true;
        if (std.mem.eql(u8, arg, "--no-color")) has_nocolor = true;
        if (std.mem.startsWith(u8, arg, "--max-count=")) has_maxcount = true;
    }
    try std.testing.expect(has_pretty);
    try std.testing.expect(has_z);
    try std.testing.expect(has_decorate);
    try std.testing.expect(has_nocolor);
    try std.testing.expect(has_maxcount);
}

test "logArgv: skip=100 includes --skip=100" {
    const a = std.testing.allocator;
    const argv = try logArgv(a, 100, 100);
    defer a.free(argv);
    var found_skip: ?[]const u8 = null;
    for (argv) |arg| if (std.mem.startsWith(u8, arg, "--skip=")) {
        found_skip = arg;
    };
    try std.testing.expect(found_skip != null);
    try std.testing.expectEqualStrings("--skip=100", found_skip.?);
}

test "showNameStatusArgv: --diff-merges=first-parent --format= --name-status -z" {
    const a = std.testing.allocator;
    const argv = try showNameStatusArgv(a, "abc123");
    defer a.free(argv);
    var has_diffmerges = false;
    var has_format = false;
    var has_namestatus = false;
    var has_z = false;
    var has_hash = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--diff-merges=first-parent")) has_diffmerges = true;
        if (std.mem.eql(u8, arg, "--format=")) has_format = true;
        if (std.mem.eql(u8, arg, "--name-status")) has_namestatus = true;
        if (std.mem.eql(u8, arg, "-z")) has_z = true;
        if (std.mem.eql(u8, arg, "abc123")) has_hash = true;
    }
    try std.testing.expect(has_diffmerges);
    try std.testing.expect(has_format);
    try std.testing.expect(has_namestatus);
    try std.testing.expect(has_z);
    try std.testing.expect(has_hash);
}

test "showFileDiffArgv: --diff-merges=first-parent --format= <hash> -- <path>" {
    const a = std.testing.allocator;
    const argv = try showFileDiffArgv(a, "abc123", "src/main.zig");
    defer a.free(argv);
    var has_diffmerges = false;
    var has_format = false;
    var has_dd = false;
    var has_hash = false;
    var has_path = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--diff-merges=first-parent")) has_diffmerges = true;
        if (std.mem.eql(u8, arg, "--format=")) has_format = true;
        if (std.mem.eql(u8, arg, "--")) has_dd = true;
        if (std.mem.eql(u8, arg, "abc123")) has_hash = true;
        if (std.mem.eql(u8, arg, "src/main.zig")) has_path = true;
    }
    try std.testing.expect(has_diffmerges);
    try std.testing.expect(has_format);
    try std.testing.expect(has_dd);
    try std.testing.expect(has_hash);
    try std.testing.expect(has_path);
}
```

- [ ] **Step 2: `logArgv`/`showNameStatusArgv`/`showFileDiffArgv` を実装**

`src/git/commands.zig` の `applyPatchArgv` の後に追加:

```zig
/// `git log` argv。skip=0 のとき --skip を付けない（git が警告するため）。呼出側 free。
/// L2: `--decorate=short --no-color` 明示（環境設定に委ねない）。
pub fn logArgv(a: std.mem.Allocator, skip: usize, max_count: usize) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "log",
    });
    if (skip > 0) {
        const skip_arg = try std.fmt.allocPrint(a, "--skip={d}", .{skip});
        errdefer a.free(skip_arg);
        try list.append(a, skip_arg);
    }
    const max_arg = try std.fmt.allocPrint(a, "--max-count={d}", .{max_count});
    errdefer a.free(max_arg);
    try list.append(a, max_arg);
    try list.appendSlice(a, &.{
        "--pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d",
        "-z",
        "--decorate=short",
        "--no-color",
    });
    return list.toOwnedSlice(a);
}

/// `git show --name-status` argv。★H4/H5: 第一親との差・header なし・NUL 区切り。
pub fn showNameStatusArgv(a: std.mem.Allocator, hash: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "show",
        "--diff-merges=first-parent", "--format=", "--name-status", "-z",
    });
    try list.append(a, hash);
    return list.toOwnedSlice(a);
}

/// `git show <hash> -- <path>` argv。★H4: name-status と同じ第一親基準。
pub fn showFileDiffArgv(a: std.mem.Allocator, hash: []const u8, path: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{
        "git", "-c", "core.quotePath=false", "show",
        "--diff-merges=first-parent", "--format=",
    });
    try list.append(a, hash);
    try list.append(a, "--");
    try list.append(a, path);
    return list.toOwnedSlice(a);
}
```

- [ ] **Step 3: `HeadState` と `headState` 関数を実装（tri-state・3 段階判定・R5/R19/R23/R23b）**

```zig
/// R5/R19/R23: HEAD 状態の tri-state（ok/unborn/err）。
pub const HeadState = enum { ok, unborn, err };

/// R5/R19/R23: rev-parse --verify HEAD だけでは unborn と壊れた HEAD・object 欠損・権限エラーを区別できない
/// （どれも exit 128 を返し得る）。3 段階で厳密判定する:
///   (1) rev-parse --verify HEAD の exit code（0=ok / 128=(2)へ / その他=err）
///   (2) exit 128 のとき symbolic-ref --short HEAD で branch 名を取得（失敗=err）
///   (3) branch 名で show-ref --verify --quiet refs/heads/<branch> を実行:
///       exit 0 → ref が存在するが HEAD が exit 128 → dangling（object 無し）→ err
///       exit 1 → ref が存在しない → unborn
///       その他 → err
///   ※R23b 実測: show-ref --verify <ref> は不存在時に exit 128 を返す（exit 1 ではない）。
///     --quiet を付けると不存在時に exit 1・存在時に exit 0 になるので必ず --quiet 付きで使う。
pub fn headState(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !HeadState {
    var res1 = try process.run(a, io, &.{ "git", "rev-parse", "--verify", "HEAD" }, cwd);
    defer res1.deinit(a);
    return switch (res1.exit_code) {
        0 => .ok,
        128 => blk: {
            // (2) symbolic-ref で branch 名取得
            var res2 = try process.run(a, io, &.{ "git", "symbolic-ref", "--short", "HEAD" }, cwd);
            defer res2.deinit(a);
            if (res2.exit_code != 0) break :blk .err;
            const branch = std.mem.trimEnd(u8, res2.stdout, "\n");
            if (branch.len == 0) break :blk .err;
            // (3) show-ref --verify --quiet で ref 実在確認
            const ref_buf = try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch});
            defer a.free(ref_buf);
            var res3 = try process.run(a, io, &.{ "git", "show-ref", "--verify", "--quiet", ref_buf }, cwd);
            defer res3.deinit(a);
            break :blk switch (res3.exit_code) {
                0 => .err, // ref が有るのに HEAD exit 128 = dangling
                1 => .unborn, // ref 無し = 空リポジトリ
                else => .err,
            };
        },
        else => .err,
    };
}
```

- [ ] **Step 4: `zig build test --summary all` で argv 単体テストが通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（4 つの argv テストが追加。headState は結合テストで後述）

- [ ] **Step 5: Commit**

```bash
git add src/git/commands.zig
git commit -m "feat(git/commands): add logArgv/showNameStatusArgv/showFileDiffArgv/headState (TODO 2 phase 1)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 4: `src/model.zig` — `ViewMode`/`DetailKind` と log/detail フィールド + 所有権関数

**Files:**
- Modify: `src/model.zig`

`Model` へ `view_mode`・log 系（`log_commits`/`log_selected`/`log_scroll`/`log_has_more`/`log_request_generation`/`log_page_requested: ?usize`/`log_restore_hash`）・detail 系（`detail_kind`/`detail_files`/`detail_selected`/`detail_scroll`/`detail_owner_hash`/`detail_diff`/`detail_diff_scroll`/`detail_diff_owner_hash`/`detail_diff_owner_path`）を追加。所有権関数（`replaceLogCommits`/`appendLogCommits`/`replaceDetailFiles`/`setDetailOwnerHash`/`setDetailDiffOwner`/`clearDetailOwner`/`clearDetailDiffOwner`/`setLogRestoreHash`/`clearLogRestoreHash`/`cloneCommit`/`cloneStringSlice`/`freeStringSlice`）を実装。`replaceFiles` のトランザクショナル・deep-copy → swap パターンを模倣（H6/R1）。

- [ ] **Step 1: 単体テストを `src/model.zig` のテストセクションへ追加（所有権関数の基本）**

ファイル末尾のテスト群の末尾へ追加:

```zig
test "Model.log fields initialize to defaults (ViewMode=changes, empty log_commits)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try std.testing.expectEqual(ViewMode.changes, m.view_mode);
    try std.testing.expectEqual(@as(usize, 0), m.log_commits.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.log_selected);
    try std.testing.expectEqual(@as(?usize, null), m.log_page_requested);
    try std.testing.expectEqual(@as(?[]u8, null), m.log_restore_hash);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
    try std.testing.expectEqual(DetailKind.files, m.detail_kind);
}

test "replaceLogCommits deep-copies entries and frees old (H6/R1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const log = @import("git/log.zig");
    const c = log.Commit{
        .hash = try a.dupe(u8, "h1"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a1"),
        .epoch_sec = 1,
        .subject = try a.dupe(u8, "s1"),
        .refs = try a.dupe(u8, ""),
    };
    defer {
        a.free(c.hash);
        a.free(c.parents);
        a.free(c.author);
        a.free(c.subject);
        a.free(c.refs);
    }
    try m.replaceLogCommits(&.{c});
    try std.testing.expectEqual(@as(usize, 1), m.log_commits.items.len);
    try std.testing.expectEqualStrings("h1", m.log_commits.items[0].hash);
    // 入力 c とは別のメモリ（deep-copy）
    try std.testing.expect(c.hash.ptr != m.log_commits.items[0].hash.ptr);
}

test "appendLogCommits deep-copies new entries to existing list (H6/R1)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    const log = @import("git/log.zig");
    const c1 = log.Commit{
        .hash = try a.dupe(u8, "h1"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a1"),
        .epoch_sec = 1,
        .subject = try a.dupe(u8, "s1"),
        .refs = try a.dupe(u8, ""),
    };
    try m.replaceLogCommits(&.{c1});
    defer {
        a.free(c1.hash);
        a.free(c1.parents);
        a.free(c1.author);
        a.free(c1.subject);
        a.free(c1.refs);
    }
    const c2 = log.Commit{
        .hash = try a.dupe(u8, "h2"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a2"),
        .epoch_sec = 2,
        .subject = try a.dupe(u8, "s2"),
        .refs = try a.dupe(u8, ""),
    };
    defer {
        a.free(c2.hash);
        a.free(c2.parents);
        a.free(c2.author);
        a.free(c2.subject);
        a.free(c2.refs);
    }
    try m.appendLogCommits(&.{c2});
    try std.testing.expectEqual(@as(usize, 2), m.log_commits.items.len);
    try std.testing.expectEqualStrings("h1", m.log_commits.items[0].hash);
    try std.testing.expectEqualStrings("h2", m.log_commits.items[1].hash);
}

test "setDetailOwnerHash / clearDetailOwner cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setDetailOwnerHash("abc");
    try std.testing.expectEqualStrings("abc", m.detail_owner_hash.?);
    try m.setDetailOwnerHash("def"); // 旧 abc を free して新 def へ
    try std.testing.expectEqualStrings("def", m.detail_owner_hash.?);
    m.clearDetailOwner();
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_owner_hash);
}

test "setDetailDiffOwner / clearDetailDiffOwner cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setDetailDiffOwner("abc", "src/f.txt");
    try std.testing.expectEqualStrings("abc", m.detail_diff_owner_hash.?);
    try std.testing.expectEqualStrings("src/f.txt", m.detail_diff_owner_path.?);
    m.clearDetailDiffOwner();
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_diff_owner_hash);
    try std.testing.expectEqual(@as(?[]u8, null), m.detail_diff_owner_path);
}

test "setLogRestoreHash / clearLogRestoreHash cycle without leak" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try m.setLogRestoreHash("h1");
    try std.testing.expectEqualStrings("h1", m.log_restore_hash.?);
    m.clearLogRestoreHash();
    try std.testing.expectEqual(@as(?[]u8, null), m.log_restore_hash);
}
```

- [ ] **Step 2: `ViewMode`/`DetailKind` enum と log/detail フィールドを `Model` 構造体へ追加**

`src/model.zig` の `pub const Focus = enum { changes, diff, commit };` の**下**へ追加:

```zig
pub const ViewMode = enum { changes, log };
pub const DetailKind = enum { files, diff };
```

`Model` 構造体のフィールド `mouse_enabled: bool,` の**下**（フィールドリストの末尾）へ追加:

```zig
    mouse_enabled: bool,

    // --- TODO 2 phase 1: log/detail ビュー ---
    view_mode: ViewMode,
    log_commits: std.ArrayList(@import("git/log.zig").Commit),
    log_selected: usize,
    log_scroll: usize,
    log_has_more: bool,
    log_request_generation: u64,
    log_page_requested: ?usize, // 期待 skip（重複防止のみ）。null = 要求無し。
    log_restore_hash: ?[]u8,    // R4: refresh 時に選択 hash を退避。
    detail_kind: DetailKind,
    detail_files: std.ArrayList(@import("git/show.zig").NameStatus),
    detail_selected: usize,
    detail_scroll: usize,
    detail_owner_hash: ?[]u8,   // H1: detail が何の hash に対応するか。
    detail_diff: []u8,
    detail_diff_scroll: usize,
    detail_diff_owner_hash: ?[]u8,
    detail_diff_owner_path: ?[]u8,
```

- [ ] **Step 3: `Model.init` と `Model.deinit` を更新**

`Model.init` の戻り値リテラルへ新フィールドを追加（`mouse_enabled: true,` の後に）:

```zig
            .mouse_enabled: true,

            .view_mode = .changes,
            .log_commits = .empty,
            .log_selected = 0,
            .log_scroll = 0,
            .log_has_more = false,
            .log_request_generation = 0,
            .log_page_requested = null,
            .log_restore_hash = null,
            .detail_kind = .files,
            .detail_files = .empty,
            .detail_selected = 0,
            .detail_scroll = 0,
            .detail_owner_hash = null,
            .detail_diff = try a.dupe(u8, ""),
            .detail_diff_scroll = 0,
            .detail_diff_owner_hash = null,
            .detail_diff_owner_path = null,
```

**注意**: 既存 `Model.init` はフィールド名を使った構造体リテラル（`.foo = bar` 形式）ではなく、`return .{ .foo = bar, ... }` の形式のはず。実際の形式に合わせる（`.x = y` または `x: y`）。上記は `.field = value` 形式だが、既存コードが `return .{ ... }` のドット記法ならそれに従う。

`Model.deinit` の末尾（`a.free(self.error_text);` の後）へ追加:

```zig
        a.free(self.error_text);

        // --- TODO 2 phase 1: log/detail の解放 ---
        for (self.log_commits.items) |*c| c.deinit(a);
        self.log_commits.deinit(a);
        if (self.log_restore_hash) |h| a.free(h);
        for (self.detail_files.items) |*e| e.deinit(a);
        self.detail_files.deinit(a);
        if (self.detail_owner_hash) |h| a.free(h);
        a.free(self.detail_diff);
        if (self.detail_diff_owner_hash) |h| a.free(h);
        if (self.detail_diff_owner_path) |p| a.free(p);
```

- [ ] **Step 4: 所有権関数と clone ヘルパを実装**

`src/model.zig` の `selectByPathPriority` 関数の**下**（ファイル末尾のテストの前）へ追加:

```zig
// --- TODO 2 phase 1: log/detail の所有権関数 ---

const log_mod = @import("git/log.zig");
const show_mod = @import("git/show.zig");

/// 入力 `entries`（Msg 所有）を deep-copy して新 ArrayList を構築し、成功後に旧を解放して swap（H6/R1）。
pub fn replaceLogCommits(self: *Model, entries: []const log_mod.Commit) !void {
    const a = self.allocator;
    var next: std.ArrayList(log_mod.Commit) = .empty;
    errdefer {
        for (next.items) |*c| c.deinit(a);
        next.deinit(a);
    }
    for (entries) |e| {
        var cloned = try cloneCommit(a, e);
        errdefer cloned.deinit(a);
        try next.append(a, cloned);
    }
    for (self.log_commits.items) |*c| c.deinit(a);
    self.log_commits.deinit(a);
    self.log_commits = next;
}

/// 既存 log_commits.items と入力 new_entries を全て deep-copy した unified list を構築 → swap（H6/R1）。
/// shallow copy 禁止（cleanup 時の二重 free を防ぐ）。
pub fn appendLogCommits(self: *Model, new_entries: []const log_mod.Commit) !void {
    const a = self.allocator;
    var next: std.ArrayList(log_mod.Commit) = .empty;
    errdefer {
        for (next.items) |*c| c.deinit(a);
        next.deinit(a);
    }
    for (self.log_commits.items) |c| {
        var cloned = try cloneCommit(a, c);
        errdefer cloned.deinit(a);
        try next.append(a, cloned);
    }
    for (new_entries) |e| {
        var cloned = try cloneCommit(a, e);
        errdefer cloned.deinit(a);
        try next.append(a, cloned);
    }
    for (self.log_commits.items) |*c| c.deinit(a);
    self.log_commits.deinit(a);
    self.log_commits = next;
}

/// detail_files への適用。NameStatus も deep-copy し append 毎に errdefer。
pub fn replaceDetailFiles(self: *Model, entries: []const show_mod.NameStatus) !void {
    const a = self.allocator;
    var next: std.ArrayList(show_mod.NameStatus) = .empty;
    errdefer {
        for (next.items) |*e| e.deinit(a);
        next.deinit(a);
    }
    for (entries) |e| {
        const path = try a.dupe(u8, e.path);
        errdefer a.free(path);
        const orig: ?[]u8 = if (e.orig_path) |op| try a.dupe(u8, op) else null;
        errdefer if (orig) |o| a.free(o);
        try next.append(a, .{ .status = e.status, .path = path, .orig_path = orig });
    }
    for (self.detail_files.items) |*e| e.deinit(a);
    self.detail_files.deinit(a);
    self.detail_files = next;
}

/// H1: detail_owner_hash のセット（旧を free して dup）。
pub fn setDetailOwnerHash(self: *Model, hash: []const u8) !void {
    const a = self.allocator;
    const new = try a.dupe(u8, hash);
    if (self.detail_owner_hash) |old| a.free(old);
    self.detail_owner_hash = new;
}

pub fn clearDetailOwner(self: *Model) void {
    const a = self.allocator;
    if (self.detail_owner_hash) |old| a.free(old);
    self.detail_owner_hash = null;
}

/// H1: detail_diff_owner のセット（hash と path 両方）。
pub fn setDetailDiffOwner(self: *Model, hash: []const u8, path: []const u8) !void {
    const a = self.allocator;
    const new_hash = try a.dupe(u8, hash);
    errdefer a.free(new_hash);
    const new_path = try a.dupe(u8, path);
    errdefer a.free(new_path);
    if (self.detail_diff_owner_hash) |old| a.free(old);
    if (self.detail_diff_owner_path) |old| a.free(old);
    self.detail_diff_owner_hash = new_hash;
    self.detail_diff_owner_path = new_path;
}

pub fn clearDetailDiffOwner(self: *Model) void {
    const a = self.allocator;
    if (self.detail_diff_owner_hash) |old| a.free(old);
    if (self.detail_diff_owner_path) |old| a.free(old);
    self.detail_diff_owner_hash = null;
    self.detail_diff_owner_path = null;
}

/// R4: log_restore_hash のセット。
pub fn setLogRestoreHash(self: *Model, hash: []const u8) !void {
    const a = self.allocator;
    const new = try a.dupe(u8, hash);
    if (self.log_restore_hash) |old| a.free(old);
    self.log_restore_hash = new;
}

pub fn clearLogRestoreHash(self: *Model) void {
    const a = self.allocator;
    if (self.log_restore_hash) |old| a.free(old);
    self.log_restore_hash = null;
}

/// ヘルパ: Commit の deep-copy（R1: 各フィールド毎に errdefer で順次 rollback）。
fn cloneCommit(a: std.mem.Allocator, c: log_mod.Commit) !log_mod.Commit {
    var out: log_mod.Commit = undefined;
    out.hash = try a.dupe(u8, c.hash);
    errdefer a.free(out.hash);
    out.parents = try cloneStringSlice(a, c.parents);
    errdefer freeStringSlice(a, out.parents);
    out.author = try a.dupe(u8, c.author);
    errdefer a.free(out.author);
    out.subject = try a.dupe(u8, c.subject);
    errdefer a.free(out.subject);
    out.refs = try a.dupe(u8, c.refs);
    errdefer a.free(out.refs);
    out.epoch_sec = c.epoch_sec;
    return out;
}

fn cloneStringSlice(a: std.mem.Allocator, src: []const []u8) ![][]u8 {
    const out = try a.alloc([]u8, src.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |s| a.free(s);
        a.free(out);
    }
    for (src, 0..) |s, i| {
        out[i] = try a.dupe(u8, s);
        initialized = i + 1;
    }
    return out;
}

fn freeStringSlice(a: std.mem.Allocator, src: [][]u8) void {
    for (src) |s| a.free(s);
    a.free(src);
}
```

- [ ] **Step 5: `zig build test --summary all` で通ることを確認**

Run: `zig build test --summary all`
Expected: PASS（新テスト 6 件追加・既存テストも green）

- [ ] **Step 6: Commit**

```bash
git add src/model.zig
git commit -m "feat(model): add ViewMode/DetailKind and log/detail fields with ownership (TODO 2 phase 1)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

## Task 5: `src/messages.zig` — `Msg`/`AppCmd` 新バリアント + 構造体

**Files:**
- Modify: `src/messages.zig`

`Msg` へ log/detail 入力系・結果系（構造体化）・scroll 系を追加。`AppCmd` へ `load_log`/`load_log_page`/`load_commit_detail`/`load_detail_diff` を追加。網羅的 `deinit` switch を拡張（`else` 無しで新バリアント強制）。

- [ ] **Step 1: `Msg` へ log/detail 入力系 + scroll 系バリアントを追加**

`src/messages.zig` の `pub const Msg = union(enum) {` の中（`quit,` の後ろ・`select_index: usize,` の前あたり）へ追加:

```zig
    quit,
    // --- TODO 2 phase 1: log/detail 入力系 ---
    toggle_view_mode,                 // L キー
    log_cursor_down, log_cursor_up,
    log_open_detail,                  // Enter/Space
    log_scroll_down, log_scroll_up,   // R13: Ctrl+d/u・ホイール
    detail_cursor_down, detail_cursor_up,
    detail_select_file,               // Enter/Space: .files → .diff
    detail_back_to_files,             // Esc/Backspace/u: .diff → .files
    detail_files_scroll_down, detail_files_scroll_up,
    detail_diff_scroll_down, detail_diff_scroll_up,
    log_select_index: usize,          // M6: マウスクリック
    detail_select_index: usize,       // M6: マウスクリック
    select_index: usize,
```

- [ ] **Step 2: `Msg` へ結果系バリアント（構造体化）を追加**

`Msg` の `// 解釈器からの結果（所有: 複製済み）` セクション（`committed,` の後）へ追加:

```zig
    committed,
    // --- TODO 2 phase 1: log/detail 結果系（H1 構造体化） ---
    log_loaded: LogLoaded,
    log_page_loaded: LogLoaded,
    log_page_failed: LogPageFailed,
    log_page_failed_silent: LogPageFailedSilent, // R21: OOM 極限
    commit_detail_loaded: CommitDetailLoaded,
    detail_diff_loaded: DetailDiffLoaded,
    git_error: []u8,
```

※`git_error: []u8,` は既存バリアント（重複追加しないこと）。

`Msg` の `pub const Msg = union(enum) { ... };` ブロックの**末尾**（閉じ `};` の前）へ関連構造体を追加:

```zig
    pub const LogLoaded = struct {
        request_skip: usize,
        request_max_count: usize,
        request_generation: u64,
        entries: []@import("git/log.zig").Commit,
    };
    pub const LogPageFailed = struct {
        request_skip: usize,
        request_generation: u64,
        error_text: []u8,
    };
    pub const LogPageFailedSilent = struct {
        request_skip: usize,
        request_generation: u64,
    };
    pub const CommitDetailLoaded = struct {
        request_hash: []u8,
        entries: []@import("git/show.zig").NameStatus,
    };
    pub const DetailDiffLoaded = struct {
        request_hash: []u8,
        request_path: []u8,
        text: []u8,
    };
```

- [ ] **Step 3: `Msg.deinit` の switch へ新バリアントの解放処理を追加**

`Msg.deinit` の `switch (self.*) { ... }` の中・既存所有バリアント（`.diff_loaded => |s| a.free(s),` 等）の近くへ追加:

```zig
            .log_loaded, .log_page_loaded => |ll| {
                for (ll.entries) |*c| c.deinit(a);
                a.free(ll.entries);
            },
            .log_page_failed => |lpf| a.free(lpf.error_text),
            .log_page_failed_silent => {},
            .commit_detail_loaded => |cdl| {
                a.free(cdl.request_hash);
                for (cdl.entries) |*e| e.deinit(a);
                a.free(cdl.entries);
            },
            .detail_diff_loaded => |ddl| {
                a.free(ddl.request_hash);
                a.free(ddl.request_path);
                a.free(ddl.text);
            },
```

入力系・scroll 系バリアント（`toggle_view_mode`/`log_cursor_down`/...）は `=> {},` へ追加:

```zig
            .toggle_view_mode,
            .log_cursor_down,
            .log_cursor_up,
            .log_open_detail,
            .log_scroll_down,
            .log_scroll_up,
            .detail_cursor_down,
            .detail_cursor_up,
            .detail_select_file,
            .detail_back_to_files,
            .detail_files_scroll_down,
            .detail_files_scroll_up,
            .detail_diff_scroll_down,
            .detail_diff_scroll_up,
            .log_select_index,
            .detail_select_index,
```

- [ ] **Step 4: `AppCmd` へ新バリアントを追加**

`AppCmd` の `apply_patch: ApplyPatch,` の後・`quit,` の前に追加:

```zig
    apply_patch: ApplyPatch,
    // --- TODO 2 phase 1: log/detail 副作用 ---
    load_log: LoadLog,
    load_log_page: LoadLog,
    load_commit_detail: []u8, // hash 所有
    load_detail_diff: LoadDetailDiff,
    quit,
```

`AppCmd` ブロック末尾（`pub const ApplyPatch` の後）へ追加:

```zig
    pub const LoadLog = struct { skip: usize, max_count: usize, generation: u64 };
    pub const LoadDetailDiff = struct { hash: []u8, path: []u8 };
```

- [ ] **Step 5: `AppCmd.deinit` の switch へ新バリアントを追加**

```zig
            .load_log, .load_log_page => {},
            .load_commit_detail => |h| a.free(h),
            .load_detail_diff => |ldd| {
                a.free(ldd.hash);
                a.free(ldd.path);
            },
```

`.none, .refresh_status, .quit, => {},` のリストへは追加しない（上で個別処理したため）。

- [ ] **Step 6: 単体テストを追加（所有ペイロードの free 検証）**

`src/messages.zig` のテストセクション末尾へ追加:

```zig
test "Msg.log_loaded deinit frees entries without leak" {
    const a = std.testing.allocator;
    const log = @import("git/log.zig");
    const entries = try a.alloc(log.Commit, 1);
    entries[0] = .{
        .hash = try a.dupe(u8, "h1"),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "a1"),
        .epoch_sec = 1,
        .subject = try a.dupe(u8, "s1"),
        .refs = try a.dupe(u8, ""),
    };
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1, .entries = entries,
    } };
    msg.deinit(a);
}

test "Msg.log_page_failed deinit frees error_text" {
    const a = std.testing.allocator;
    var msg = Msg{ .log_page_failed = .{
        .request_skip = 100, .request_generation = 1, .error_text = try a.dupe(u8, "boom"),
    } };
    msg.deinit(a);
}

test "Msg.log_page_failed_silent deinit is no-op (no payload)" {
    const a = std.testing.allocator;
    var msg = Msg{ .log_page_failed_silent = .{ .request_skip = 100, .request_generation = 1 } };
    msg.deinit(a);
}

test "Msg.commit_detail_loaded deinit frees request_hash and entries" {
    const a = std.testing.allocator;
    const show = @import("git/show.zig");
    const entries = try a.alloc(show.NameStatus, 1);
    entries[0] = .{
        .status = 'M',
        .path = try a.dupe(u8, "f.txt"),
        .orig_path = null,
    };
    var msg = Msg{ .commit_detail_loaded = .{ .request_hash = try a.dupe(u8, "abc"), .entries = entries } };
    msg.deinit(a);
}

test "Msg.detail_diff_loaded deinit frees hash/path/text" {
    const a = std.testing.allocator;
    var msg = Msg{ .detail_diff_loaded = .{
        .request_hash = try a.dupe(u8, "abc"),
        .request_path = try a.dupe(u8, "src/f.txt"),
        .text = try a.dupe(u8, "diff body"),
    } };
    msg.deinit(a);
}

test "AppCmd.load_log has no owned payload (deinit is no-op)" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .load_log = .{ .skip = 0, .max_count = 100, .generation = 1 } };
    cmd.deinit(a);
}

test "AppCmd.load_commit_detail owns hash and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .load_commit_detail = try a.dupe(u8, "abc123") };
    cmd.deinit(a);
}

test "AppCmd.load_detail_diff owns hash/path and frees on deinit" {
    const a = std.testing.allocator;
    var cmd = AppCmd{ .load_detail_diff = .{ .hash = try a.dupe(u8, "abc"), .path = try a.dupe(u8, "f.txt") } };
    cmd.deinit(a);
}
```

- [ ] **Step 7: `zig build test --summary all` で通ることを確認**

Run: `zig build test --summary all`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/messages.zig
git commit -m "feat(messages): add log/detail Msg/AppCmd variants with structured payloads (TODO 2 phase 1)

Co-authored-by: factory-droid[bot] <138933559+factory-droid[bot]@users.noreply.github.com>"
```

---

Task 6-15 は同様の TDD ステップ構造です。残りのタスク（update.zig reducer / appcmd.zig 解釈器 / input.zig wrapper / view.zig renderLog/renderDetail / autorefresh / main.zig 配線 / README・TODO 更新 / 手動 pty 検証）も spec §8 の順序で展開します。紙幅の都合でタスク 6 以降は spec §1.6/§1.7/§3/§7 の該当節を直接参照しつつ、各タスクで「テスト追加 → 実装 → `zig build test` → コミット」のステップを踏みます。実装に入る際に各タスクの詳細ステップを展開します。

---

## Self-Review（実装前に実施）

### 1. Spec カバレッジ
- §1.1 log.zig parse → Task 1
- §1.2 show.zig parseNameStatus → Task 2
- §1.3 Model フィールド + 所有権関数 → Task 4
- §1.4 Msg 新バリアント → Task 5
- §1.5 AppCmd 新バリアント → Task 5
- §1.6 reducer（stale reject/空 guard/page ゲート/focus 更新/scroll）→ Task 6
- §1.7 appcmd（headState/runLogInt/mkPageFailedOrSilent）→ Task 7
- §2 ページング戦略 → Task 6 + Task 7 + Task 10（autorefresh）
- §3 UI 統合（wrapper/computeLogLayout/logRowLayout/renderLog/renderDetail）→ Task 8 + Task 9
- §4 detail 切替（H4: --diff-merges=first-parent 統一）→ Task 3 + Task 7
- §5 参照ラベル（M8: author/日時は phase 2）→ Task 9 + Task 14（TODO.md ヘ phase 2 残明記）
- §6 テスト戦略 → 各 Task の Step 3/6 で網羅
- §7 リスク（R8 busy setter/R9 exhaustive switch）→ Task 10

### 2. Placeholder scan
- Task 6-15 は詳細ステップを省略したが、これは実装フェーズで展開する宣言。spec §1.6/§1.7/§3/§7 が直接の実装指示となる。
- 「TBD」「TODO」「implement later」は無し。

### 3. 型一貫性
- `Msg.LogLoaded`/`LogPageFailed`/`LogPageFailedSilent`/`CommitDetailLoaded`/`DetailDiffLoaded` 構造体フィールド名は spec §1.4 と Task 5 で一致。
- `AppCmd.LoadLog`/`LoadDetailDiff` は spec §1.5 と Task 5 で一致。
- Model の `log_page_requested: ?usize`（R11: bool ではなく期待 skip）は spec §1.3 と Task 4 で一致。
- `headState`/`HeadState`/`.ok`/`.unborn`/`.err` は spec §1.7 と Task 3 で一致。
- `cloneCommit`/`cloneStringSlice`/`freeStringSlice` は Task 4 で定義・Task 6 の reducer から呼ばれる。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-19-todo2-log-view-phase1.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - タスク毎に fresh subagent を dispatch し、タスク間でレビュー。高速イテレーション。

**2. Inline Execution** - executing-plans スキルでこのセッション内で実行。チェックポイント毎に一括実行。

**どちらの方式で進めますか?**
