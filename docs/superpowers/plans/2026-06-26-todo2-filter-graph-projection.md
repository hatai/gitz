# フィルタ中の graph 維持 実装計画（TODO 2 phase 3b #2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** フィルタ適用中でも nearest-visible-parent 投影で graph を表示する（substrate 取得失敗時は従来の suppress へ安全劣化）。

**Architecture:** フィルタ時に `git rev-list --topo-order --parents <snapshot_tip>` で全履歴 topology substrate を取得し、新規純粋モジュールが visible commit 間の最近親可視祖先へ parent を投影 → derived `[]log.Commit` を既存 `graph.computeAll`/`computeIncremental` へ入力。`graph.zig` 不変。

**Tech Stack:** Zig 0.16.0（std.Io API）・`std.StringHashMap`・テストは実装 `.zig` 内 `test {}` + `zig build test --summary all`。

**Spec:** `docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md`（必読）。

## Global Constraints

- Zig 0.16.0 + std.Io API（`std.process.run` Io 版・`std.StringHashMap`）。実 API の正は `docs/superpowers/plans/zigzag-api-notes.md`。
- テストは実装と同じ `.zig` の `test {}`。`std.testing.allocator` 必須（リーク検出）。新規 `.zig` は `src/root_test.zig` へ `@import` 追加（**忘れるとテスト非実行**）。
- `zig build test --summary all` が唯一の検証（Debug 既定維持・`--test-filter` は未配線・lint/format/typecheck は存在しない）。
- 所有権: `Msg` ペイロードは所有・`deinit` 持ち。reducer は by-value `msg` を受けるため **substrate は Msg→Model へ deep-copy**（entries と同様）。
- `graph.zig`・`view.zig`・`main.zig`・`input.zig` は**変更しない**（spec §4.6/4.7）。
- 純粋層（topology/graph_project/model/messages/appcmd/update の純粋部）を TDD → UI は tmux pty 手動検証。

---

## File Structure

- **Create** `src/git/topology.zig` — substrate（全履歴 hash+parents）のパーサとデータ構造。純粋・TDD。
- **Create** `src/git/graph_project.zig` — visible commit 間の nearest-visible-parent 投影。derived `[]log.Commit` を生成。純粋・TDD。`graph.zig` 不変で `computeAll`/`computeIncremental` へ再利用可能な形へ。
- **Modify** `src/git/commands.zig` — `revListParentsArgv` 追加（argv 生成・純粋）。
- **Modify** `src/messages.zig` — `LogLoaded.substrate: ?topology.TopologySubstrate` 追加 + `deinit`。
- **Modify** `src/model.zig` — `topology_substrate` フィールド + helpers + `deinit`/`init`。
- **Modify** `src/appcmd.zig` — `runLogInt` で filter 非empty のとき substrate 取得。
- **Modify** `src/update.zig` — `handleApplyFilter`/`handleLogLoaded`/`handleLogPageLoaded`/`handleClearFilter` の投影配線。
- **Modify** `src/root_test.zig` — 新規 2 モジュールの `@import`。

---

## Task 1: `src/git/topology.zig`（substrate パーサ・純粋 TDD）

**Files:**
- Create: `src/git/topology.zig`
- Modify: `src/root_test.zig`（import 追加）

**Interfaces:**
- Produces: `pub const Entry = struct { hash: []u8, parents: [][]u8 }`, `pub const TopologySubstrate = struct { entries: []Entry, hash_index: std.StringHashMap(usize) }`, `pub const ParseError = error{ OutOfMemory }`, `pub fn parse(a, raw) ParseError!TopologySubstrate`, `TopologySubstrate.clone(a)`, `TopologySubstrate.deinit(a)`.

- [ ] **Step 1: 新規ファイル作成（型 + パーサ全文）**

Create `src/git/topology.zig`:

```zig
//! `git rev-list --topo-order --parents <tip>` 出力のパーサ（zigzag 非依存）。
//! 出力は改行区切り・各行 "<hash>[ <parent>...]"（root は hash 単独）。
//! phase 3b #2: フィルタ中 graph 投影のための全履歴 topology substrate。

const std = @import("std");

pub const Entry = struct {
    hash: []u8,
    parents: [][]u8,
    pub fn deinit(self: *Entry, a: std.mem.Allocator) void {
        a.free(self.hash);
        for (self.parents) |p| a.free(p);
        a.free(self.parents);
    }
};

pub const TopologySubstrate = struct {
    entries: []Entry, // topo 順（newest-first・rev-list 出力順）
    hash_index: std.StringHashMap(usize), // hash -> entries index（keys は entries[].hash を借用）

    pub fn deinit(self: *TopologySubstrate, a: std.mem.Allocator) void {
        // StringHashMap は keys を free しない（構造体のみ）→ entries 先に解放しても安全。
        for (self.entries) |*e| e.deinit(a);
        a.free(self.entries);
        self.hash_index.deinit();
    }

    pub fn clone(self: TopologySubstrate, a: std.mem.Allocator) std.mem.Allocator.Error!TopologySubstrate {
        const out_entries = try a.alloc(Entry, self.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (out_entries[0..initialized]) |*e| e.deinit(a);
            a.free(out_entries);
        }
        for (self.entries, 0..) |e, i| {
            const h = try a.dupe(u8, e.hash);
            errdefer a.free(h);
            const ps = try a.alloc([]u8, e.parents.len);
            var pinit: usize = 0;
            errdefer {
                for (ps[0..pinit]) |p| a.free(p);
                a.free(ps);
            }
            for (e.parents, 0..) |p, j| {
                ps[j] = try a.dupe(u8, p);
                pinit = j + 1;
            }
            out_entries[i] = .{ .hash = h, .parents = ps };
            initialized = i + 1;
        }
        var idx = std.StringHashMap(usize).init(a);
        errdefer idx.deinit();
        for (out_entries, 0..) |e, i| try idx.put(e.hash, i);
        return .{ .entries = out_entries, .hash_index = idx };
    }
};

pub const ParseError = error{ OutOfMemory };

/// `git rev-list --topo-order --parents <tip>` 出力をパース。
/// 空入力（unborn 等）= entries 空・hash_index 空（valid）。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ParseError!TopologySubstrate {
    var entries_list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries_list.items) |*e| e.deinit(a);
        entries_list.deinit(a);
    }
    var line_it = std.mem.splitScalar(u8, raw, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue; // 末尾改行等の空行
        var tok_it = std.mem.splitScalar(u8, line, ' ');
        const hash_tok = tok_it.next() orelse continue;
        const hash = try a.dupe(u8, hash_tok);
        errdefer a.free(hash);
        var parents: std.ArrayList([]u8) = .empty;
        errdefer {
            for (parents.items) |p| a.free(p);
            parents.deinit(a);
        }
        while (tok_it.next()) |pt| {
            if (pt.len == 0) continue;
            const pd = try a.dupe(u8, pt);
            errdefer a.free(pd);
            try parents.append(a, pd);
        }
        const parents_slice = try parents.toOwnedSlice(a);
        try entries_list.append(a, .{ .hash = hash, .parents = parents_slice });
    }
    const entries = try entries_list.toOwnedSlice(a);
    errdefer a.free(entries);
    var idx = std.StringHashMap(usize).init(a);
    errdefer idx.deinit();
    for (entries, 0..) |e, i| try idx.put(e.hash, i);
    return .{ .entries = entries, .hash_index = idx };
}

test "parse: linear (3 commits, each 1 parent)" {
    const a = std.testing.allocator;
    // topo newest-first: C←B, B←A, A root
    const raw = "C B\nB A\nA\n";
    var sub = try parse(a, raw);
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), sub.entries.len);
    try std.testing.expectEqualStrings("C", sub.entries[0].hash);
    try std.testing.expectEqual(@as(usize, 1), sub.entries[0].parents.len);
    try std.testing.expectEqualStrings("B", sub.entries[0].parents[0]);
    try std.testing.expectEqual(@as(usize, 0), sub.entries[2].parents.len); // A root
    // hash_index lookup
    try std.testing.expectEqual(@as(?usize, 0), sub.hash_index.get("C"));
    try std.testing.expectEqual(@as(?usize, 2), sub.hash_index.get("A"));
    try std.testing.expectEqual(@as(?usize, null), sub.hash_index.get("Z")); // miss
}

test "parse: merge commit (2 parents space-separated)" {
    const a = std.testing.allocator;
    const raw = "D B C\nC A\nB A\nA\n";
    var sub = try parse(a, raw);
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), sub.entries[0].parents.len);
    try std.testing.expectEqualStrings("B", sub.entries[0].parents[0]);
    try std.testing.expectEqualStrings("C", sub.entries[0].parents[1]);
}

test "parse: empty input returns empty valid substrate" {
    const a = std.testing.allocator;
    var sub = try parse(a, "");
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), sub.entries.len);
}

test "parse: trailing newline only yields empty" {
    const a = std.testing.allocator;
    var sub = try parse(a, "\n");
    defer sub.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), sub.entries.len);
}

test "clone: deep-copies entries and hash_index (no shared pointers)" {
    const a = std.testing.allocator;
    var sub = try parse(a, "C B\nB A\nA\n");
    defer sub.deinit(a);
    var c = try sub.clone(a);
    defer c.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), c.entries.len);
    try std.testing.expectEqualStrings("C", c.entries[0].hash);
    try std.testing.expectEqual(@as(?usize, 0), c.hash_index.get("C"));
    // 独立メモリ
    try std.testing.expect(sub.entries[0].hash.ptr != c.entries[0].hash.ptr);
}

test "parse: no invalid free / leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAndFree, .{});
}

fn parseAndFree(a: std.mem.Allocator) !void {
    const raw = "D B C\nC A\nB A\nA\n";
    var sub = try parse(a, raw);
    sub.deinit(a);
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 2: root_test.zig へ import 追加**

Modify `src/root_test.zig` — `_ = @import("git/graph.zig");` 行（:22）の直後に追加:

```zig
    _ = @import("git/topology.zig"); // TODO 2 phase 3b #2: topology substrate
```

- [ ] **Step 3: テスト実行（green 確認）**

Run: `zig build test --summary all`
Expected: PASS（topology のテスト全て含む・既存全 green）。

- [ ] **Step 4: Commit**

```bash
git add src/git/topology.zig src/root_test.zig
git commit -m "feat(log): add topology substrate parser for filter graph projection"
```

---

## Task 2: `src/git/graph_project.zig`（投影・純粋 TDD）

**Files:**
- Create: `src/git/graph_project.zig`
- Modify: `src/root_test.zig`

**Interfaces:**
- Consumes: `topology.TopologySubstrate`（Task 1）, `log.Commit`（`src/git/log.zig`）。
- Produces: `pub fn project(a, substrate, visible: []const log.Commit) Allocator.Error![]log.Commit`（derived・parents 投影済み・hash/parents のみ実値・他フィールド空）。`pub fn freeDerived(a, derived: []log.Commit) void`。

- [ ] **Step 1: 新規ファイル作成（全文）**

Create `src/git/graph_project.zig`:

```zig
//! フィルタ中 graph の nearest-visible-parent 投影（zigzag 非依存）。
//! substrate（全履歴 topology）と visible commits から、各 visible commit の
//! parent を「最近親の可視祖先」へ書き換えた derived []log.Commit を生成し、
//! 既存 graph.computeAll/computeIncremental へ入力する。graph.zig は不変。

const std = @import("std");
const topology = @import("topology.zig");
const log = @import("log.zig");

/// derived commit を解放（computeAll/computeIncremental 呼出後に呼ぶ）。
pub fn freeDerived(a: std.mem.Allocator, derived: []log.Commit) void {
    for (derived) |*c| c.deinit(a);
    a.free(derived);
}

/// visible commits（filtered log・topo newest-first 表示順）から derived commits を構築。
/// 各 derived.parents = substrate 上の実 parents を最近親可視祖先へ投影したもの（第一親チェーン追跡・重複排除）。
/// 戻り値 derived は 1:1・同順序。hash/parents のみ実値（author/subject/refs は空・epoch_sec=0）。
pub fn project(
    a: std.mem.Allocator,
    substrate: topology.TopologySubstrate,
    visible: []const log.Commit,
) std.mem.Allocator.Error![]log.Commit {
    // visible set（hash 集合）を構築
    var visible_set = std.StringHashMap(void).init(a);
    defer visible_set.deinit();
    for (visible) |c| try visible_set.put(c.hash, {});

    // nearestVisibleAncestor のメモ化（hash -> ?[]const u8）。所有しない（substrate/visible へ借用）。
    var memo = std.StringHashMap(?[]const u8).init(a);
    defer memo.deinit();

    var out: std.ArrayList(log.Commit) = .empty;
    errdefer freeDerived(a, out.items);
    for (visible) |c| {
        const proj = try projectedParents(a, substrate, visible_set, memo, c.hash);
        defer {
            for (proj) |p| a.free(p);
            a.free(proj);
        }
        try out.append(a, try mkDerived(a, c.hash, proj));
    }
    return out.toOwnedSlice(a);
}

/// C（hash）の実 parents を出発点に最近親可視祖先へ投影。重複排除済みの所有 hash slice を返す。
fn projectedParents(
    a: std.mem.Allocator,
    substrate: topology.TopologySubstrate,
    visible_set: std.StringHashMap(void),
    memo: std.StringHashMap(?[]const u8),
    hash: []const u8,
) std.mem.Allocator.Error![][]u8 {
    const idx = substrate.hash_index.get(hash) orelse return try a.alloc([]u8, 0);
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| a.free(p);
        out.deinit(a);
    }
    for (substrate.entries[idx].parents) |p| {
        const anc = nearestVisibleAncestor(substrate, visible_set, memo, p);
        if (anc) |ah| {
            if (!seen.contains(ah)) {
                try seen.put(ah, {});
                try out.append(a, try a.dupe(u8, ah));
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// X から第一親チェーンを辿り、最近親の可視祖先 hash を返す（無ければ null）。
/// メモ化: 各 commit hash -> ?可視祖先hash。X が substrate 無（shallow 等）なら null。
fn nearestVisibleAncestor(
    substrate: topology.TopologySubstrate,
    visible_set: std.StringHashMap(void),
    memo: std.StringHashMap(?[]const u8),
    hash: []const u8,
) ?[]const u8 {
    if (memo.get(hash)) |cached| return cached;
    const result: ?[]const u8 = blk: {
        if (visible_set.contains(hash)) break :blk hash;
        const idx = substrate.hash_index.get(hash) orelse break :blk null;
        const ps = substrate.entries[idx].parents;
        if (ps.len == 0) break :blk null; // 実 root 到達・可視祖先無し
        break :blk nearestVisibleAncestor(substrate, visible_set, memo, ps[0]); // 第一親へ再帰
    };
    memo.put(hash, result) catch {}; // OOM は再計算を許容（安全側・非致命）
    return result;
}

/// derived log.Commit を構築（hash/parents のみ実値・他は空）。proj（所有 slice）を消費して parents へ。
fn mkDerived(a: std.mem.Allocator, hash: []const u8, proj: [][]u8) std.mem.Allocator.Error!log.Commit {
    // proj を所有 slice のまま parents へ（dupe 済み）。但し errdefer 整合のため新 slice へ移す必要は無い:
    // proj は projectedParents の所有物。ここで所有権を derived へ移譲。呼出側で proj deinit されるので
    // 新バッファへコピーして derived が独立所有する（proj は呼出側で free されるため二重管理を避ける）。
    const parents = try a.alloc([]u8, proj.len);
    var pinit: usize = 0;
    errdefer {
        for (parents[0..pinit]) |p| a.free(p);
        a.free(parents);
    }
    for (proj, 0..) |p, i| {
        parents[i] = try a.dupe(u8, p);
        pinit = i + 1;
    }
    const h = try a.dupe(u8, hash);
    errdefer a.free(h);
    const author = try a.dupe(u8, "");
    errdefer a.free(author);
    const subject = try a.dupe(u8, "");
    errdefer a.free(subject);
    const refs = try a.dupe(u8, "");
    errdefer a.free(refs);
    return .{
        .hash = h,
        .parents = parents,
        .author = author,
        .epoch_sec = 0,
        .subject = subject,
        .refs = refs,
    };
}

// --- tests ---

/// テスト用 visible log.Commit 構築（hash/parents のみ実値）。
fn mkVisible(a: std.mem.Allocator, hash: []const u8) !log.Commit {
    return .{
        .hash = try a.dupe(u8, hash),
        .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, ""),
        .epoch_sec = 0,
        .subject = try a.dupe(u8, ""),
        .refs = try a.dupe(u8, ""),
    };
}

test "project: all visible -> identity projection (real parents kept)" {
    const a = std.testing.allocator;
    // substrate: C←B←A（全可視）。投影 parent == 実 parent。
    const sub_raw = "C B\nB A\nA\n";
    var sub = try @import("topology.zig").parse(a, sub_raw);
    defer sub.deinit(a);
    var visible = try a.alloc(log.Commit, 3);
    defer {
        for (visible) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[0] = try mkVisible(a, "C");
    visible[1] = try mkVisible(a, "B");
    visible[2] = try mkVisible(a, "A");
    const derived = try project(a, sub, visible);
    defer freeDerived(a, derived);
    try std.testing.expectEqual(@as(usize, 3), derived.len);
    // C -> B, B -> A, A -> (root)
    try std.testing.expectEqual(@as(usize, 1), derived[0].parents.len);
    try std.testing.expectEqualStrings("B", derived[0].parents[0]);
    try std.testing.expectEqualStrings("A", derived[1].parents[0]);
    try std.testing.expectEqual(@as(usize, 0), derived[2].parents.len);
}

test "project: gap collapse (non-visible parent projected to nearest visible ancestor)" {
    const a = std.testing.allocator;
    // 実履歴: D←C←B←A。visible = {D, A}（C, B は非可視）。
    // D の実 parent C は非可視 -> 第一親チェーン C->B->A -> A（可視）。D -> A へ投影。
    const sub_raw = "D C\nC B\nB A\nA\n";
    var sub = try @import("topology.zig").parse(a, sub_raw);
    defer sub.deinit(a);
    var visible = try a.alloc(log.Commit, 2);
    defer {
        for (visible) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[0] = try mkVisible(a, "D");
    visible[1] = try mkVisible(a, "A");
    const derived = try project(a, sub, visible);
    defer freeDerived(a, derived);
    try std.testing.expectEqual(@as(usize, 2), derived.len);
    // D -> A（gap 縮約）, A -> root
    try std.testing.expectEqual(@as(usize, 1), derived[0].parents.len);
    try std.testing.expectEqualStrings("A", derived[0].parents[0]);
    try std.testing.expectEqual(@as(usize, 0), derived[1].parents.len);
}

test "project: merge dedup (two parents converge to same visible ancestor)" {
    const a = std.testing.allocator;
    // D=merge(B,C), B←A, C←A。visible = {D, A}（B, C 非可視）。
    // D の実 parents B, C は共に第一親チェーンで A へ到達 -> 重複排除で 1 辺 D->A。
    const sub_raw = "D B C\nC A\nB A\nA\n";
    var sub = try @import("topology.zig").parse(a, sub_raw);
    defer sub.deinit(a);
    var visible = try a.alloc(log.Commit, 2);
    defer {
        for (visible) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[0] = try mkVisible(a, "D");
    visible[1] = try mkVisible(a, "A");
    const derived = try project(a, sub, visible);
    defer freeDerived(a, derived);
    // D -> A（1 辺・重複排除）, A -> root
    try std.testing.expectEqual(@as(usize, 1), derived[0].parents.len);
    try std.testing.expectEqualStrings("A", derived[0].parents[0]);
}

test "project: root projection (all ancestors non-visible -> derived root)" {
    const a = std.testing.allocator;
    // D←C←B←A。visible = {D}（C,B,A 非可視）。A は非可視 root。
    // D の実 parent C -> ... -> A（非可視 root）-> null -> D の投影 parent 空 = derived root。
    const sub_raw = "D C\nC B\nB A\nA\n";
    var sub = try @import("topology.zig").parse(a, sub_raw);
    defer sub.deinit(a);
    var visible = try a.alloc(log.Commit, 1);
    defer {
        for (visible) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[0] = try mkVisible(a, "D");
    const derived = try project(a, sub, visible);
    defer freeDerived(a, derived);
    try std.testing.expectEqual(@as(usize, 0), derived[0].parents.len);
}

test "project: projected parents are subset of visible set and 1:1" {
    const a = std.testing.allocator;
    const sub_raw = "E D\nD C\nC B\nB A\nA\n";
    var sub = try @import("topology.zig").parse(a, sub_raw);
    defer sub.deinit(a);
    // visible = {E, C, A}
    var visible = try a.alloc(log.Commit, 3);
    defer {
        for (visible) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[0] = try mkVisible(a, "E");
    visible[1] = try mkVisible(a, "C");
    visible[2] = try mkVisible(a, "A");
    const derived = try project(a, sub, visible);
    defer freeDerived(a, derived);
    var vset = std.StringHashMap(void).init(a);
    defer vset.deinit();
    for (visible) |c| try vset.put(c.hash, {});
    for (derived) |c| for (c.parents) |p| {
        try std.testing.expect(vset.contains(p)); // 投影 parent は必ず visible set 内
    };
    try std.testing.expectEqual(visible.len, derived.len); // 1:1
}

test "project: no leak on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, projectAndFree, .{});
}

fn projectAndFree(a: std.mem.Allocator) !void {
    var sub = try @import("topology.zig").parse(a, "D B C\nC A\nB A\nA\n");
    defer sub.deinit(a);
    var visible = try a.alloc(log.Commit, 2);
    defer {
        for (visible) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[0] = try mkVisible(a, "D");
    visible[1] = try mkVisible(a, "A");
    const derived = try project(a, sub, visible);
    freeDerived(a, derived);
}

test {
    std.testing.refAllDecls(@This());
}
```

- [ ] **Step 2: root_test.zig へ import 追加**

Modify `src/root_test.zig` — topology 行の直後（Task 1 で追加）に:

```zig
    _ = @import("git/graph_project.zig"); // TODO 2 phase 3b #2: nearest-visible-parent 投影
```

- [ ] **Step 3: テスト実行**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add src/git/graph_project.zig src/root_test.zig
git commit -m "feat(log): add nearest-visible-parent projection for filtered graph"
```

---

## Task 3: `commands.revListParentsArgv`（argv 生成・純粋）

**Files:**
- Modify: `src/git/commands.zig`（`revParseHeadArgv` の直後・高レベル関数の前）
- Test: 同ファイル内 `test {}`。

**Interfaces:**
- Produces: `pub fn revListParentsArgv(a: std.mem.Allocator, snapshot_tip: []const u8) !OwnedArgv`（snapshot_tip 借用・`OwnedArgv` の owned に入れない）。

- [ ] **Step 1: failing test を追加**

`src/git/commands.zig` のテストセクション（`test "revParseHeadArgv ..."` の後）へ追加:

```zig
test "revListParentsArgv: git rev-list --topo-order --parents <snapshot_tip>" {
    const a = std.testing.allocator;
    var argv = try revListParentsArgv(a, "snap9999");
    defer argv.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), argv.args.len);
    try std.testing.expectEqualStrings("git", argv.args[0]);
    try std.testing.expectEqualStrings("rev-list", argv.args[1]);
    try std.testing.expectEqualStrings("--topo-order", argv.args[2]);
    try std.testing.expectEqualStrings("--parents", argv.args[3]);
    try std.testing.expectEqualStrings("snap9999", argv.args[4]); // 末尾・借用
    try std.testing.expectEqual(@as(usize, 0), argv.owned.items.len); // owned 空（snapshot_tip 借用）
}
```

- [ ] **Step 2: テスト実行（失敗確認）**

Run: `zig build test --summary all`
Expected: FAIL（`revListParentsArgv` 未定義・コンパイルエラー）。

- [ ] **Step 3: 実装追加**

`src/git/commands.zig` の `revParseHeadArgv` 関数（:255-257）の直後へ追加:

```zig
/// `git rev-list --topo-order --parents <snapshot_tip>` argv（phase 3b #2 graph 投影用 substrate）。
/// 全履歴の hash + 実 parents を取得（フィルタ無し）。snapshot_tip は借用（logArgv と同様）。
pub fn revListParentsArgv(a: std.mem.Allocator, snapshot_tip: []const u8) !OwnedArgv {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    try list.appendSlice(a, &.{ "git", "rev-list", "--topo-order", "--parents" });
    try list.append(a, snapshot_tip); // 借用
    return .{ .args = try list.toOwnedSlice(a), .owned = .empty };
}
```

- [ ] **Step 4: テスト実行（green 確認）**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/git/commands.zig
git commit -m "feat(log): add revListParentsArgv for topology substrate fetch"
```

---

## Task 4: `messages.zig` LogLoaded.substrate フィールド + deinit

**Files:**
- Modify: `src/messages.zig`（`LogLoaded` 構造体 :69-76 + `deinit` log_loaded arm :137-141 + 既存テスト :393-410）

**Interfaces:**
- Consumes: `topology.TopologySubstrate`（Task 1）。
- Produces: `Msg.LogLoaded.substrate: ?topology.TopologySubstrate`。

- [ ] **Step 1: import と LogLoaded フィールド追加**

`src/messages.zig` 先頭の import 群（:7 の後）へ追加:

```zig
const topology = @import("git/topology.zig");
```

`LogLoaded` 構造体（:69-76）へ `entries` の後にフィールド追加:

```zig
    pub const LogLoaded = struct {
        request_skip: usize,
        request_max_count: usize,
        request_generation: u64,
        request_tip: []u8, // 所有 — appcmd が rev-parse HEAD で解決した snapshot tip
        is_unborn: bool, // appcmd が headState tri-state で判定
        entries: []@import("git/log.zig").Commit,
        substrate: ?topology.TopologySubstrate, // ★phase 3b #2: filter 活性で非null・投影用 substrate
    };
```

- [ ] **Step 2: deinit へ substrate 解放追加**

`Msg.deinit` の `.log_loaded` arm（:137-141）へ substrate 解放を追加:

```zig
            .log_loaded => |ll| {
                a.free(ll.request_tip);
                for (ll.entries) |*c| c.deinit(a);
                a.free(ll.entries);
                if (ll.substrate) |*s| s.deinit(a); // ★phase 3b #2
            },
```

- [ ] **Step 3: 既存 LogLoaded テストへ substrate フィールド追加**

`test "Msg.log_loaded deinit frees request_tip and entries without leak"`（:393-410）の構造体リテラルへ `.substrate = null` を追加:

```zig
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap1111"), .is_unborn = false, .entries = entries,
        .substrate = null,
    } };
    msg.deinit(a);
```

- [ ] **Step 4: substrate あり deinit テスト追加**

`test "Msg.log_loaded deinit frees request_tip and entries without leak"` の後に新規テスト追加:

```zig
test "Msg.log_loaded deinit frees substrate without leak (phase 3b #2)" {
    const a = std.testing.allocator;
    const sub_raw = "C B\nB A\nA\n";
    var sub = try topology.parse(a, sub_raw);
    var msg = Msg{ .log_loaded = .{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false,
        .entries = try a.alloc(@import("git/log.zig").Commit, 0),
        .substrate = sub,
    } };
    msg.deinit(a); // entries 空 + substrate 解放
}
```

- [ ] **Step 5: テスト実行**

Run: `zig build test --summary all`
Expected: PASS（※ appcmd.zig が LogLoaded を構築する箇所がまだ更新前でコンパイルエラーになる場合は、Task 6 と同時進行不可 → 本 Task の範囲で appcmd の LogLoaded 構築箇所に `.substrate = null` を仮追加して通すこと。具体的: `src/appcmd.zig:165-172`（unborn 分岐）と `:205-212`（成功分岐）と mkLoadFailedOrSilent 系は LogLoaded を返さないので対象外。unborn/成功の2箇所へ `.substrate = null` を追加）。

補足（コンパイルを通すための appcmd 仮追加）:

`src/appcmd.zig` unborn 分岐（:165-172）と成功分岐（:205-212）の LogLoaded リテラルへ `.substrate = null` を追加（本 Task では null まで・実取得は Task 6）。

- [ ] **Step 6: Commit**

```bash
git add src/messages.zig src/appcmd.zig
git commit -m "feat(log): add substrate field to LogLoaded (null placeholder)"
```

---

## Task 5: `model.zig` topology_substrate フィールド + helpers

**Files:**
- Modify: `src/model.zig`（import + Model フィールド :67-70 ブロック + init :118-121 + deinit :157-159 + helpers + テスト）

**Interfaces:**
- Consumes: `topology.TopologySubstrate`（Task 1）。
- Produces: `Model.topology_substrate`, `Model.setTopologySubstrate(owned)`, `Model.clearTopologySubstrate()`。

- [ ] **Step 1: import 追加**

`src/model.zig` の import 群（:5 の後）へ追加:

```zig
const topology_mod = @import("git/topology.zig");
```

- [ ] **Step 2: フィールド追加**

Model の phase 2/3a ブロック（:67-70）へフィールド追加:

```zig
    // --- TODO 2 phase 2/3a: graph display + snapshot tip ---
    log_graph_state: graph_mod.GraphState,
    log_snapshot_tip: ?[]u8,
    graph_render_policy: GraphRenderPolicy,
    topology_substrate: ?topology_mod.TopologySubstrate, // ★phase 3b #2: filter 中 graph 投影用
```

- [ ] **Step 3: init へデフォルト追加**

`Model.init`（:118-121）の phase 2/3a ブロックへ追加:

```zig
            // --- TODO 2 phase 2/3a: graph display + snapshot tip ---
            .log_graph_state = .invalid,
            .log_snapshot_tip = null,
            .graph_render_policy = .auto,
            .topology_substrate = null,
```

- [ ] **Step 4: deinit へ解放追加**

`Model.deinit`（:157-159）の phase 2/3a ブロックへ追加:

```zig
        // --- TODO 2 phase 2/3a ---
        self.log_graph_state.deinit(a);
        if (self.log_snapshot_tip) |t| a.free(t);
        if (self.topology_substrate) |*s| s.deinit(a); // ★phase 3b #2
```

- [ ] **Step 5: helpers 追加**

`clearLogSnapshotTip`（:385-389）の後に追加:

```zig
    /// phase 3b #2: topology_substrate を置換（旧を deinit して swap・所有権移譲）。
    pub fn setTopologySubstrate(self: *Model, sub: topology_mod.TopologySubstrate) void {
        if (self.topology_substrate) |*s| s.deinit(self.allocator);
        self.topology_substrate = sub;
    }
    /// phase 3b #2: topology_substrate をクリア。
    pub fn clearTopologySubstrate(self: *Model) void {
        if (self.topology_substrate) |*s| s.deinit(self.allocator);
        self.topology_substrate = null;
    }
```

- [ ] **Step 6: テスト追加**

`test "Model.log_graph_state initializes to .invalid"`（:929-934）の後に追加:

```zig
test "Model.topology_substrate initializes null (phase 3b #2)" {
    var m = try Model.init(std.testing.allocator, "/r");
    defer m.deinit();
    try std.testing.expectEqual(@as(?topology_mod.TopologySubstrate, null), m.topology_substrate);
}

test "Model.setTopologySubstrate / clearTopologySubstrate cycle without leak (phase 3b #2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var sub1 = try topology_mod.parse(a, "C B\nB A\nA\n");
    m.setTopologySubstrate(sub1); // move
    try std.testing.expect(m.topology_substrate != null);
    try std.testing.expectEqual(@as(usize, 3), m.topology_substrate.?.entries.len);
    var sub2 = try topology_mod.parse(a, "D C\nC\n");
    m.setTopologySubstrate(sub2); // 旧 sub1 解放 + 新 sub2 swap
    try std.testing.expectEqual(@as(usize, 2), m.topology_substrate.?.entries.len);
    m.clearTopologySubstrate();
    try std.testing.expectEqual(@as(?topology_mod.TopologySubstrate, null), m.topology_substrate);
}
```

- [ ] **Step 7: テスト実行**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 8: Commit**

```bash
git add src/model.zig
git commit -m "feat(log): add topology_substrate field and helpers to Model"
```

---

## Task 6: `appcmd.zig` runLogInt で substrate 取得

**Files:**
- Modify: `src/appcmd.zig`（import + `runLogInt` :156-213）。Task 4 で `.substrate = null` 仮追加済みの箇所を実取得へ。

**Interfaces:**
- Consumes: `commands.revListParentsArgv`（Task 3）, `topology.parse`（Task 1）, `process.runWithLimit`。
- Produces: `LogLoaded.substrate`（filter 非empty で取得・失敗は null）。

- [ ] **Step 1: import 追加**

`src/appcmd.zig` import 群（:9 の後）へ追加:

```zig
const topology = @import("git/topology.zig");
```

- [ ] **Step 2: fetchSubstrate ヘルパ追加**

`runLogInt` 関数の直前（:153 あたり・`/// Run git log for load_log ...` コメントの前）へ追加:

```zig
/// phase 3b #2: `git rev-list --topo-order --parents <snapshot_tip>` を取得して substrate をパース。
/// 全ての失敗（OOM/StreamTooLong/exit≠0/parse 失敗）は null へ（graph のみ suppress へ劣化・filtered log は別途成功）。
/// 戻り値は所有（成功時）。infallible（常に ?値を返す）。
fn fetchSubstrate(
    a: std.mem.Allocator,
    io: std.Io,
    cwd: Cwd,
    snapshot_tip: []const u8,
    log_limit: std.Io.Limit,
) ?topology.TopologySubstrate {
    var argv = cmds.revListParentsArgv(a, snapshot_tip) catch return null;
    defer argv.deinit(a);
    var res = process.runWithLimit(a, io, argv.args, cwd, log_limit) catch return null;
    defer res.deinit(a);
    if (res.exit_code != 0) return null;
    return topology.parse(a, res.stdout) catch null;
}
```

- [ ] **Step 3: runLogInt 成功分岐で substrate 取得**

`runLogInt` の成功分岐（:200-212）を以下へ置換（entries errdefer の後・request_tip dupe を substrate 計算より前へ分離）:

```zig
    const entries = log.parse(a, res.stdout) catch
        return mkLoadFailedOrSilent(a, cmd, "git log パース失敗", snapshot_tip);
    errdefer {
        for (entries) |*c| c.deinit(a);
        a.free(entries);
    }
    // ★B1: request_tip には rev-parse HEAD の結果を dupe して所有。
    const tip_dup = try a.dupe(u8, snapshot_tip.?);
    errdefer a.free(tip_dup);
    // ★phase 3b #2: filter 活性のとき substrate を取得（失敗は null・graph suppress へ劣化）。
    const substrate: ?topology.TopologySubstrate = if (!cmd.filter.isEmpty())
        fetchSubstrate(a, io, cwd, snapshot_tip.?, log_limit)
    else
        null;
    return .{ .log_loaded = .{
        .request_skip = cmd.skip,
        .request_max_count = cmd.max_count,
        .request_generation = cmd.generation,
        .request_tip = tip_dup,
        .is_unborn = false,
        .entries = entries,
        .substrate = substrate,
    } };
```

 unborn 分岐（:161-173）の LogLoaded リテラル（Task 4 で `.substrate = null` 仮追加済み）はそのまま維持（unborn は substrate 取得しない）。

- [ ] **Step 4: 結合テスト追加（実 tmp repo）**

`src/appcmd.zig` の log 結合テストセクション（`test "load_log returns log_loaded ..."` の後）へ追加:

```zig
test "load_log with author filter returns LogLoaded with substrate (phase 3b #2)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    // 3 commits（各1ファイル）。
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    try repo.writeFile(io, "b.txt", "b\n");
    try repo.git(a, io, &.{ "git", "add", "b.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c2" });
    try repo.writeFile(io, "c.txt", "c\n");
    try repo.git(a, io, &.{ "git", "add", "c.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c3" });
    var spec = FilterSpec.init();
    try spec.addCondition(a, .{ .author = try a.dupe(u8, "t") });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = spec,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    // filter 活性 -> substrate 非null・全3 commit 含む。
    try std.testing.expect(msg.log_loaded.substrate != null);
    try std.testing.expectEqual(@as(usize, 3), msg.log_loaded.substrate.?.entries.len);
}

test "load_log with empty filter returns LogLoaded with null substrate (phase 3b #2)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "a.txt", "a\n");
    try repo.git(a, io, &.{ "git", "add", "a.txt" });
    try repo.git(a, io, &.{ "git", "commit", "-q", "-m", "c1" });
    var msg = try runOwned(a, io, repo.cwd(), .{ .load_log = .{
        .skip = 0, .max_count = 100, .generation = 1, .filter = FilterSpec.init(),
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .log_loaded);
    try std.testing.expectEqual(@as(?@TypeOf(msg.log_loaded.substrate.?), null), msg.log_loaded.substrate);
}
```

- [ ] **Step 5: テスト実行**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 6: Commit**

```bash
git add src/appcmd.zig
git commit -m "feat(log): fetch topology substrate in runLogInt when filter active"
```

---

## Task 7: `update.zig` handleApplyFilter + handleLogLoaded 投影配線

**Files:**
- Modify: `src/update.zig`（import + `handleApplyFilter` :791 + `handleLogLoaded` :588-596 + テスト）

**Interfaces:**
- Consumes: `graph_project.project`/`freeDerived`（Task 2）, `Model.setTopologySubstrate`/`clearTopologySubstrate`（Task 5）, `topology.TopologySubstrate.clone`（Task 1）。
- Produces: filter 活性+substrate 有 → graph_state.valid（投影 computeAll）。

- [ ] **Step 1: import 追加**

`src/update.zig` import 群（:17 の後）へ追加:

```zig
const graph_project = @import("git/graph_project.zig");
const topology_mod = @import("git/topology.zig");
```

- [ ] **Step 2: handleApplyFilter の policy 変更**

`handleApplyFilter`（:791）: `model.graph_render_policy = .suppressed;` → `.auto;` へ変更:

```zig
    model.clearLogSnapshotTip();
    model.graph_render_policy = .auto; // ★phase 3b #2: graph 欲しい（substrate 無なら handleLogLoaded で suppressed へ）
    model.invalidateLogGraph();
```

- [ ] **Step 3: handleLogLoaded の graph 計算ブロック置換**

`handleLogLoaded`（:588-596）の `★B2: graph_render_policy==.suppressed なら graph 計算をスキップ` ブロックを以下へ置換:

```zig
    // ★phase 3b #2: filter 活性なら投影 graph、無 filter なら従来 computeAll。
    if (model.filter_state.isEmpty()) {
        // 無 filter: 従来（policy=.auto で computeAll・suppressed は到達しないが安全のためガード）。
        if (model.graph_render_policy != .suppressed) {
            const tip_const: ?[]const u8 = if (model.log_snapshot_tip) |t| t else null;
            const gs = graph_mod.computeAll(model.allocator, model.log_commits.items, model.log_request_generation, tip_const) catch {
                model.invalidateLogGraph();
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(gs);
        }
        return try loadCommitDetailForSelection(model);
    }
    // filter 活性:
    if (ll.substrate) |sub| {
        // substrate を Model へ deep-copy（Msg 所有・reducer は by-value で copy 必須）。
        const cloned = sub.clone(model.allocator) catch {
            model.clearTopologySubstrate();
            model.graph_render_policy = .suppressed;
            return try loadCommitDetailForSelection(model);
        };
        model.setTopologySubstrate(cloned);
    } else {
        model.clearTopologySubstrate();
        model.graph_render_policy = .suppressed;
        return try loadCommitDetailForSelection(model);
    }
    // 投影 + computeAll。
    const derived = graph_project.project(model.allocator, model.topology_substrate.?, model.log_commits.items) catch {
        model.invalidateLogGraph();
        model.graph_render_policy = .suppressed;
        return try loadCommitDetailForSelection(model);
    };
    defer graph_project.freeDerived(model.allocator, derived);
    const tip_const: ?[]const u8 = if (model.log_snapshot_tip) |t| t else null;
    const gs = graph_mod.computeAll(model.allocator, derived, model.log_request_generation, tip_const) catch {
        model.invalidateLogGraph();
        model.graph_render_policy = .suppressed;
        return try loadCommitDetailForSelection(model);
    };
    model.setLogGraphState(gs);
    model.graph_render_policy = .auto;
    return try loadCommitDetailForSelection(model);
```

**注意**: 既存の「空 guard」（:583-587）はそのまま残し、その後ろに本ブロックを置く（空 guard の `return .none` が空コミット時に抜けるのは維持）。

- [ ] **Step 4: テスト追加（filter+substrate → graph_state.valid）**

`src/update.zig` のテストセクションへ追加（helper 関数 `mkLogLoadedCommit` が無ければ、既存の log Commit 構築パターンを踏襅。実装ファイル内の既存ヘルパを再利用、無ければ下記 inline 構築）:

```zig
test "handleLogLoaded: filter + substrate -> graph projected valid (phase 3b #2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    m.log_request_generation = 1;
    // filter 活性
    try m.filter_state.addCondition(a, .{ .author = try a.dupe(u8, "t") });
    // substrate: D←C←B←A（全4）。visible = {D, A}。
    var sub = try topology_mod.parse(a, "D C\nC B\nB A\nA\n");
    // visible entries（表示用メタデータのみ・.parents は投影で無視）
    const log = @import("git/log.zig");
    var entries = try a.alloc(log.Commit, 2);
    entries[0] = .{
        .hash = try a.dupe(u8, "D"), .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "t"), .epoch_sec = 1,
        .subject = try a.dupe(u8, "d"), .refs = try a.dupe(u8, ""),
    };
    entries[1] = .{
        .hash = try a.dupe(u8, "A"), .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "t"), .epoch_sec = 2,
        .subject = try a.dupe(u8, "a"), .refs = try a.dupe(u8, ""),
    };
    var ll = msgs.Msg.LogLoaded{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
        .substrate = sub,
    };
    var cmd = try update(&m, .{ .log_loaded = ll });
    _ = &cmd;
    try std.testing.expect(m.log_graph_state == .valid);
    try std.testing.expectEqual(@as(usize, 2), m.log_graph_state.valid.rows.items.len);
    try std.testing.expectEqual(GraphRenderPolicy.auto, m.graph_render_policy);
    try std.testing.expect(m.topology_substrate != null);
}

test "handleLogLoaded: filter + no substrate -> suppressed (phase 3b #2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    m.log_request_generation = 1;
    try m.filter_state.addCondition(a, .{ .author = try a.dupe(u8, "t") });
    const log = @import("git/log.zig");
    var entries = try a.alloc(log.Commit, 1);
    entries[0] = .{
        .hash = try a.dupe(u8, "D"), .parents = try a.alloc([]u8, 0),
        .author = try a.dupe(u8, "t"), .epoch_sec = 1,
        .subject = try a.dupe(u8, "d"), .refs = try a.dupe(u8, ""),
    };
    var ll = msgs.Msg.LogLoaded{
        .request_skip = 0, .request_max_count = 100, .request_generation = 1,
        .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = entries,
        .substrate = null,
    };
    _ = try update(&m, .{ .log_loaded = ll });
    try std.testing.expectEqual(GraphRenderPolicy.suppressed, m.graph_render_policy);
    try std.testing.expectEqual(@as(?topology_mod.TopologySubstrate, null), m.topology_substrate);
}
```

- [ ] **Step 5: 既存 handleLogLoaded テストの整合確認**

`src/update.zig` 内で LogLoaded を直接構築する既存テストが `.substrate` を持たない場合、コンパイルエラーになる。grep で `Msg.LogLoaded{` / `.log_loaded = .{` を検索し、全てに `.substrate = null`（無 filter のテスト）を追加。

Run: `rg -n "\.log_loaded = \.|\Msg\.LogLoaded\{" src/update.zig src/appcmd.zig src/messages.zig`

- [ ] **Step 6: テスト実行**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 7: Commit**

```bash
git add src/update.zig
git commit -m "feat(log): project filtered commits to graph in handleLogLoaded"
```

---

## Task 8: `update.zig` handleLogPageLoaded 投影（paging）

**Files:**
- Modify: `src/update.zig`（`handleLogPageLoaded` :625-648）

**Interfaces:**
- Consumes: `graph_project.project`/`freeDerived`（Task 2）, `model.topology_substrate`（Task 5）。

- [ ] **Step 1: handleLogPageLoaded graph ブロック置換**

`handleLogPageLoaded`（:625-648）の `★B2: graph_render_policy==.suppressed なら graph 計算をスキップ` 〜 switch 終端を以下へ置換（filter 活性+substrate 有のとき投影で incremental/computeAll・それ以外は従来）:

```zig
    // ★phase 3b #2: filter 活性+substrate 有なら投影 graph。
    if (!model.filter_state.isEmpty() and model.topology_substrate != null) {
        const sub = model.topology_substrate.?;
        switch (model.log_graph_state) {
            .valid => {
                const derived = graph_project.project(model.allocator, sub, lpl.entries) catch {
                    model.invalidateLogGraph();
                    return try loadCommitDetailForSelection(model);
                };
                defer graph_project.freeDerived(model.allocator, derived);
                const new_state = graph_mod.computeIncremental(model.allocator, &model.log_graph_state, derived) catch {
                    model.invalidateLogGraph();
                    return try loadCommitDetailForSelection(model);
                };
                model.setLogGraphState(new_state);
            },
            .invalid => {
                // graph が無効化されていたら全 loaded commits で再投影 computeAll。
                const derived_all = graph_project.project(model.allocator, sub, model.log_commits.items) catch {
                    return try loadCommitDetailForSelection(model);
                };
                defer graph_project.freeDerived(model.allocator, derived_all);
                const tip_const: ?[]const u8 = if (model.log_snapshot_tip) |t| t else null;
                const gs = graph_mod.computeAll(model.allocator, derived_all, model.log_request_generation, tip_const) catch {
                    return try loadCommitDetailForSelection(model);
                };
                model.setLogGraphState(gs);
            },
        }
        return try loadCommitDetailForSelection(model);
    }
    // ★B2: graph_render_policy==.suppressed なら graph 計算をスキップ。
    if (model.graph_render_policy == .suppressed) {
        return try loadCommitDetailForSelection(model);
    }
    // phase 2 M-11: graph computation（.valid→incremental / .invalid→computeAll）。
    switch (model.log_graph_state) {
        .valid => {
            const new_state = graph_mod.computeIncremental(model.allocator, &model.log_graph_state, lpl.entries) catch {
                model.invalidateLogGraph();
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(new_state);
        },
        .invalid => {
            const tip_const: ?[]const u8 = if (model.log_snapshot_tip) |t| t else null;
            const gs = graph_mod.computeAll(model.allocator, model.log_commits.items, model.log_request_generation, tip_const) catch {
                return try loadCommitDetailForSelection(model);
            };
            model.setLogGraphState(gs);
        },
    }
    return try loadCommitDetailForSelection(model);
```

- [ ] **Step 2: テスト追加（paging 投影 incremental）**

`src/update.zig` テストセクションへ追加（初回 handleLogLoaded 後に handleLogPageLoaded で増分）:

```zig
test "handleLogPageLoaded: filter+substrate -> incremental projection (phase 3b #2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    m.view_mode = .log;
    m.log_request_generation = 1;
    try m.filter_state.addCondition(a, .{ .author = try a.dupe(u8, "t") });
    try m.setLogSnapshotTip("snap");
    // 初回 loaded: visible = {E, C}（substrate: E←D←C←B←A）。
    var sub = try topology_mod.parse(a, "E D\nD C\nC B\nB A\nA\n");
    const log = @import("git/log.zig");
    var e1 = try a.alloc(log.Commit, 2);
    e1[0] = .{ .hash = try a.dupe(u8, "E"), .parents = try a.alloc([]u8, 0), .author = try a.dupe(u8, "t"), .epoch_sec = 1, .subject = try a.dupe(u8, "e"), .refs = try a.dupe(u8, "") };
    e1[1] = .{ .hash = try a.dupe(u8, "C"), .parents = try a.alloc([]u8, 0), .author = try a.dupe(u8, "t"), .epoch_sec = 2, .subject = try a.dupe(u8, "c"), .refs = try a.dupe(u8, "") };
    var ll = msgs.Msg.LogLoaded{ .request_skip = 0, .request_max_count = 2, .request_generation = 1, .request_tip = try a.dupe(u8, "snap"), .is_unborn = false, .entries = e1, .substrate = sub };
    _ = try update(&m, .{ .log_loaded = ll });
    try std.testing.expect(m.log_graph_state == .valid);
    const rows_before = m.log_graph_state.valid.rows.items.len;
    // paging: visible = {A} 追加。
    m.log_page_requested = 2;
    var e2 = try a.alloc(log.Commit, 1);
    e2[0] = .{ .hash = try a.dupe(u8, "A"), .parents = try a.alloc([]u8, 0), .author = try a.dupe(u8, "t"), .epoch_sec = 3, .subject = try a.dupe(u8, "a"), .refs = try a.dupe(u8, "") };
    var lpl = msgs.Msg.LogPageLoaded{ .request_skip = 2, .request_max_count = 2, .request_generation = 1, .request_tip = try a.dupe(u8, "snap"), .entries = e2 };
    _ = try update(&m, .{ .log_page_loaded = lpl });
    try std.testing.expect(m.log_graph_state == .valid);
    try std.testing.expectEqual(rows_before + 1, m.log_graph_state.valid.rows.items.len); // 増分
}
```

- [ ] **Step 3: テスト実行**

Run: `zig build test --summary all`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add src/update.zig
git commit -m "feat(log): project filtered page incrementally in handleLogPageLoaded"
```

---

## Task 9: `update.zig` handleClearFilter + フルビルド green

**Files:**
- Modify: `src/update.zig`（`handleClearFilter` :807-822）

**Interfaces:**
- Consumes: `Model.clearTopologySubstrate`（Task 5）。

- [ ] **Step 1: handleClearFilter へ substrate 解放追加**

`handleClearFilter`（:807-822）の `clearFilterState` 後に追加:

```zig
fn handleClearFilter(model: *Model) !AppCmd {
    model.clearFilterState();
    model.clearTopologySubstrate(); // ★phase 3b #2: substrate 解放
    model.filter_modal_open = false;
    model.log_request_generation += 1;
    model.log_page_requested = null;
    model.log_has_more = false;
    model.clearLogSnapshotTip();
    model.graph_render_policy = .auto; // ★B2: graph 復活
    model.invalidateLogGraph();
    model.clearDetailOwner();
    try model.replaceDetailFiles(&.{});
    try model.setStr(&model.detail_diff, "");
    model.setLogLoadError("") catch {};
    try model.replaceLogCommits(&.{});
    return try buildLoadLogCmd(model);
}
```

- [ ] **Step 2: 既存 clear_filter テストの整合確認**

`src/update.zig` 内で clear_filter 後の topology_substrate を確認するテストが無ければ追加（任意・既存 clear_filter テストが green なら省略可）。最小確認テスト:

```zig
test "handleClearFilter: clears topology_substrate (phase 3b #2)" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    var sub = try topology_mod.parse(a, "C B\nB A\nA\n");
    m.setTopologySubstrate(sub);
    try std.testing.expect(m.topology_substrate != null);
    _ = try update(&m, .clear_filter);
    try std.testing.expectEqual(@as(?topology_mod.TopologySubstrate, null), m.topology_substrate);
    try std.testing.expect(m.filter_state.isEmpty());
}
```

- [ ] **Step 3: フルビルド + 全テスト green**

Run: `zig build test --summary all`
Expected: PASS（全テスト・518+ 新規テスト含む green）。

- [ ] **Step 4: リリースビルド確認（オプション・型検査強化）**

Run: `zig build`
Expected: 成功（コンパイルエラー無し）。

- [ ] **Step 5: Commit**

```bash
git add src/update.zig
git commit -m "feat(log): clear topology_substrate on clear_filter"
```

---

## Task 10: 手動検証（tmux pty）+ 最終レビュー

**Files:** 変更無し（検証のみ）。

- [ ] **Step 1: テスト用 repo 準備（分岐/マージ履歴付き）**

```bash
mkdir -p /tmp/gt-graph-test && cd /tmp/gt-graph-test && rm -rf .git *
git init -q && git config user.email t@t && git config user.name t
echo a > a.txt && git add . && git commit -qm c1
git checkout -q -b feature
echo b > b.txt && git add . && git commit -qm c2-feature
git checkout -q main
echo c > c.txt && git add . && git commit -qm c3-main
git merge -q --no-ff feature -m m4-merge
echo d > d.txt && git add . && git commit -qm c5
```

- [ ] **Step 2: TUI 起動 + フィルタ適用で graph 表示確認（author）**

`zig build run` を tmux 320x50 で起動し、log モード（`l`）→ `f` で filter modal → author=`t` → Enter。

期待:
- graph 列が表示される（`*`/`|`/`\` 等・宙に浮く辺無し）。
- `(graph hidden)` 理由行が**表示されない**。

- [ ] **Step 3: path フィルタで graph 表示確認**

filter modal → author 空・paths=`a.txt` → Enter。

期待: graph 表示（substrate から再導出・path 簡略化の影響無し）。

- [ ] **Step 4: paging で graph 連続確認**

100+ commit の repo で author フィルタ → 下スクロールで追加ロード → graph frontier が継続（破綻無し）。

- [ ] **Step 5: substrate 失敗の劣化確認（任意・stream_limit 小）**

一時的に `process.default_stream_limit` を小さくするか、巨大 repo で確認: graph 非表示 + `Filter: ... (graph hidden)` 理由表示・クラッシュ無し。（※ 実機困難なら skip・コードレビューで経路確認。）

- [ ] **Step 6: clear_filter で graph 復帰確認**

filter 適用中 → clear（`F` または modal）→ 全件 graph 復帰（通常 computeAll）。

- [ ] **Step 7: 最終 whole-branch レビュー（requesting-code-review 相当）**

`docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md` の受入基準 1-7 を全てチェック:
1. 各フィルタで graph 表示 ✓
2. 辺は visible 間のみ・非閉路 ✓
3. paging 連続 ✓
4. substrate 失敗で suppress+理由・クラッシュ無し ✓
5. clear_filter で graph 復帰・substrate 解放 ✓
6. `zig build test --summary all` 全 green ✓
7. tmux pty で 1-5 目視確認 ✓

- [ ] **Step 8: TODO.md 更新 + handoff**

`TODO.md:196` の `- [ ] フィルタ中の graph 維持...` を `- [x]` へ更新・実装詳細（spec/plan パス・テスト数）を追記。handoff ドキュメントを更新（次推奨 = phase 3b #1 branch フィルタ・B3 前提）。

- [ ] **Step 9: 最終 commit**

```bash
git add TODO.md
git commit -m "docs(todo): mark phase 3b #2 filter graph projection complete"
```

---

## 自己レビューチェック（plan 作成者）

- **Spec カバレッジ**: spec §3（topology/graph_project/commands/messages/model/appcmd/update）→ Task 1-9。§6 エッジ（大規模/substrate失敗/root/merge/shallow/unborn）→ 各 catch で null/degrade。§9 テスト戦略 → Task 1-9 の test + Task 10 pty。OK。
- **プレースホルダ**: 無し（全コード実体あり）。
- **型一貫性**: `topology.TopologySubstrate`（Task1）→ messages.LogLoaded.substrate（Task4）→ model（Task5）→ appcmd（Task6）→ update（Task7-9）。`graph_project.project`/`freeDerived`（Task2）。`revListParentsArgv`（Task3）。名前/型 全 task 間で一致。
- **所有権**: substrate は Msg 所有 → reducer で `clone` して Model へ（by-value msg 制約）。derived は一時（defer freeDerived）。OK。
