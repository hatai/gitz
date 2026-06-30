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
    // out.items は ArrayList のバッファ裏付け slice。toOwnedSlice 前で append が一度も
    // 成功していないと未確保の .empty sentinel になり、freeDerived の a.free(slice) が
    // invalid free になる。log.zig:29-32 / projectedParents と同様、items 内容を deinit
    // した上で out.deinit(a) でバッファを解放する（public freeDerived は返却済み owned
    // slice 専用・ここでは使わない）。
    errdefer {
        for (out.items) |*c| c.deinit(a);
        out.deinit(a);
    }
    for (visible) |c| {
        const proj = try projectedParents(a, substrate, visible_set, &memo, c.hash);
        // perf phase1/M8: mkDerived 成功時に proj を consume するので、失敗時のみ proj を解放。
        // proj_consumed フラグで disarm（二重 free 回避）。
        var proj_consumed = false;
        defer {
            if (!proj_consumed) {
                for (proj) |p| a.free(p);
                a.free(proj);
            }
        }
        var derived = try mkDerived(a, c.hash, proj);
        // mkDerived 成功 → proj は derived.parents へ移譲済み。以降の失敗（out.append OOM）時は
        // derived.deinit が proj 含む全フィールドを解放するので proj 側 defer は disarm。
        proj_consumed = true;
        errdefer derived.deinit(a);
        try out.append(a, derived);
    }
    return out.toOwnedSlice(a);
}

/// C（hash）の実 parents を出発点に最近親可視祖先へ投影。重複排除済みの所有 hash slice を返す。
/// memo は最近親計算のメモ化表（呼出側が所有）→ ポインタ渡し（値渡しだと put が *self を要求し、
/// かつ書込みがコピーに逃げてメモ化が効かない）。
fn projectedParents(
    a: std.mem.Allocator,
    substrate: topology.TopologySubstrate,
    visible_set: std.StringHashMap(void),
    memo: *std.StringHashMap(?[]const u8),
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
                // dupe 成功後 out.append が OOM すると duped hash が out.items 未登録で
                // 孤立リークするため一旦変数へ取り errdefer で保護（project の append と同型）。
                const pdup = try a.dupe(u8, ah);
                errdefer a.free(pdup);
                try out.append(a, pdup);
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// X から第一親チェーンを辿り、最近親の可視祖先 hash を返す（無ければ null）。
/// メモ化: 各 commit hash -> ?可視祖先hash。X が substrate 無（shallow 等）なら null。
/// memo はポインタ渡し（put が *self を要求し、値渡しではメモ化がコピーに逃げるため）。
/// 反復実装（第一親チェーンを while で下降）・O(1) スタック（深い線形履歴でもスタック溢れしない）。
/// 2 パス: (1) チェーン末端まで下降して結果を決定、(2) 同チェーンを再下降して各ノードへ結果をメモ化。
fn nearestVisibleAncestor(
    substrate: topology.TopologySubstrate,
    visible_set: std.StringHashMap(void),
    memo: *std.StringHashMap(?[]const u8),
    hash: []const u8,
) ?[]const u8 {
    if (memo.get(hash)) |cached| return cached;
    // (1) 末端まで下降して結果を決定（visible / 実 root / substrate 外 = null）。
    var result: ?[]const u8 = null;
    var cur: []const u8 = hash;
    while (true) {
        if (memo.get(cur)) |cached| {
            result = cached;
            break;
        }
        if (visible_set.contains(cur)) {
            result = cur;
            break;
        }
        const idx = substrate.hash_index.get(cur) orelse {
            result = null;
            break;
        };
        const ps = substrate.entries[idx].parents;
        if (ps.len == 0) {
            result = null; // 実 root 到達・可視祖先無し
            break;
        }
        cur = ps[0]; // 第一親へ下降
    }
    // (2) 同第一親チェーンを再下降し、各非末端ノードへ結果をメモ化（全員同一結果を共有）。
    cur = hash;
    while (true) {
        if (memo.get(cur)) |_| break; // 既にメモ化済みの末端に到達 → 完了
        memo.put(cur, result) catch {}; // OOM は再計算を許容（安全側・非致命）
        if (visible_set.contains(cur)) break; // 可視末端（result == cur）
        const idx = substrate.hash_index.get(cur) orelse break; // substrate 外末端
        const ps = substrate.entries[idx].parents;
        if (ps.len == 0) break; // 実 root 末端
        cur = ps[0];
    }
    return result;
}

/// derived log.Commit を構築（hash/parents のみ実値・他は空）。
/// perf phase1/M8: `proj`（projectedParents が dupe 済みの所有 parents slice）を
/// **消費**して derived.parents へ（dupe しない・二重コピー廃止）。
/// 所有権: 成功時 proj は derived へ移譲（呼出側は proj を解放しない）。
/// 失敗時は fallible な dupe を proj より前に全て行うため proj は未触→呼出側が解放。
fn mkDerived(a: std.mem.Allocator, hash: []const u8, proj: [][]u8) std.mem.Allocator.Error!log.Commit {
    // まず fallible な dupe を全て（proj は触らない・失敗時は呼出側の defer が proj を解放）。
    const h = try a.dupe(u8, hash);
    errdefer a.free(h);
    const author = try a.dupe(u8, "");
    errdefer a.free(author);
    const subject = try a.dupe(u8, "");
    errdefer a.free(subject);
    const refs = try a.dupe(u8, "");
    errdefer a.free(refs);
    // ここから infallible: proj の所有権を derived.parents へ移譲（dupe 無し・M8）。
    return .{
        .hash = h,
        .parents = proj,
        .author = author,
        .epoch_sec = 0,
        .subject = subject,
        .refs = refs,
    };
}

// --- tests ---

/// テスト用 visible log.Commit 構築（hash/parents のみ実値）。
/// フィールドごとに errdefer を登録し部分 OOM でリークしない（log.zig の構築と同型）。
fn mkVisible(a: std.mem.Allocator, hash: []const u8) !log.Commit {
    const h = try a.dupe(u8, hash);
    errdefer a.free(h);
    const parents = try a.alloc([]u8, 0);
    errdefer a.free(parents);
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
    // a.alloc は要素をゼロ埋めしない。checkAllAllocationFailures 下で mkVisible が
    // 部分失敗すると未初期化 slot の deinit でクラッシュするため、vinit で初期化済み
    // 範囲のみ解放する（成功時 vinit==len で全要素、失敗時は途中まで）。
    var vinit: usize = 0;
    defer {
        for (visible[0..vinit]) |*c| c.deinit(a);
        a.free(visible);
    }
    visible[vinit] = try mkVisible(a, "D");
    vinit += 1;
    visible[vinit] = try mkVisible(a, "A");
    vinit += 1;
    const derived = try project(a, sub, visible);
    freeDerived(a, derived);
}

test {
    std.testing.refAllDecls(@This());
}
