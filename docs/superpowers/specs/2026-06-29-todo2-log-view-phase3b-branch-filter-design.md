# TODO 2 phase 3b #1: ブランチフィルタ設計

- 日付: 2026-06-29（rev.1: codex レビュー MAJOR1/MINOR1/advisory2 全面反映版）
- 対象: `TODO.md`「TODO 2 phase 3b」残り **#1 ブランチフィルタ**（phase 3b 最後・`:195`）。
- 関連: phase3a spec §16/B3（`docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md:932-938`）・phase3b #2 graph 投影（`docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md`）・date/path spec（`docs/superpowers/specs/2026-06-22-todo2-log-view-phase3b-date-path-filter-design.md`）。

## 0. codex レビュー対応表（rev.0 → rev.1）

codex 独立レビュー（read-only sandbox・関連ソース参照）結果: **Issues Found**（MAJOR 1 / MINOR 1 / advisory 2）。方針（branch = 単一 revspec → snapshot_tip・B3 回避）は妥当と評価。反映:

| 指摘 | 重要度 | 内容 | 対応 |
|---|---|---|---|
| §3.3/§3.4 | MAJOR | `revParseVerifyArgv` が `git rev-parse --verify <rev>` で `--end-of-options` 無し。先頭 `-` reject は reducer（UX 層）のみで、argv builder（真の安全境界）が無防備。reducer を経由しない呼出経路/テストで `--all` 等が option として解釈され得る | **反映**: `git rev-parse --verify --end-of-options <rev>^{commit}` へ変更（§3.3）。reducer の先頭 `-` reject は「分かりやすい日本語エラー」用として残し、argv builder を真の安全境界へ（defense in depth・§3.4） |
| §3.3 | advisory | `rev-parse --verify <入力>` は blob/tree hash も解決し得る。その後 `git log <blob>` が exit 128 で失敗する（劣化だが安全）が、解決時点で弾く方が綺麗 | **反映**: `^{commit}` peel で commit 以外は解決失敗（§3.3）・MAJOR 対策と同一 argv で解消 |
| §2.3/§7 | MINOR | branch-only 投影を「恒等写像」と言い切っているが、paging 中の loaded subset は親が未ロードになり得るため厳密には恒等でない。#2 再利用の結論は妥当だが根拠が不正確 | **反映**: 「恒等写像」主張を撤回し、#2 の paging 全再投影自己補正（C1）へ根拠を寄せる（§2.3/§7） |
| §3.5 | advisory | `resolveBranchTip` のシグネチャ（`!?[]u8` vs `!Msg`）を実装判断に委ねると誤実装リスク | **反映**: 具体的な形（null→LogLoadFailed 正規化の小ヘルパ `branchLoadFailed` + runLogInt インライン分岐）へ固定（§3.5） |

---

## 1. 背景 & スコープ

phase 3b は 4 フィルタ種（author / date / path / branch）の実装。author/date/path は phase3a/3b で完了済み。**残りは branch のみ**（TODO.md:195）。

### 1.1 B3 和集合問題と本設計の解法（最大分岐）

phase3a §16/B3 が指摘した核心問題:
> `log_snapshot_tip` は**単一 tip 前提**。`--branches=<glob>` で複数 branch にマッチすると、`git log <snapshot_tip> --branches=...` は複数 tip の和集合を返すが、paging の単一 tip 照合（`handleLogPageLoaded` の `request_tip == log_snapshot_tip`・`update.zig:648-653`）と衝突する。substrate も複数 tip（`rev-list --parents <t1> <t2> ...`）へ拡張が必要。

**本設計の解法（phase3a §16 推奨案・最小 delta）**: branch 条件を argv への付加オプションではなく **revision（snapshot_tip）の選択**として扱う。

- branch 入力は**任意の git revspec**（branch 名 / tag / remote-tracking `origin/main` / hash / `HEAD~5` 等）。`git rev-parse --verify <入力>` で単一 hash へ解決し、**それ自体を snapshot_tip** とする。
- 以降の pipeline は **phase3b #2 インフラ完全不変**: `logArgv(snapshot_tip, filter)`・paging tip 照合・substrate `rev-list --parents <snapshot_tip>`・`graph_project.project`。
- `--branches=<glob>` は**使わない** → 複数 tip 和集合問題は構造的に発生しない（B3 解消）。

### 1.2 スコープ（IN / OUT）

**IN（本 spec 対象）**:
- 単一 revspec 入力 → hash 解決 → snapshot_tip。
- FilterSpec へ `branch` variant 追加。
- runLogInt の snapshot_tip 解決の branch 分岐。
- フィルタモーダル 5 欄化（Branch 先頭・index 0）。
- branch 解決失敗の typed error。
- 既存フィルタ（author/since/until/paths）との compose（`git log <branch_hash> --author=... -- <path>`）。

**OUT（将来拡張）**:
- 複数 branch / `--branches=<glob>`（和集合・所有集合・substrate 複数 tip 拡張）。
- `--grep`（コミットメッセージ検索・phase3a §16 別拡張ポイント）。

### 1.3 プロダクト判断（Open decisions・ユーザー承認済み）

1. **単一 branch**: 単一 revspec のみ。複数/glob は将来。
2. **任意 revspec 受理**: `git rev-parse --verify <入力>` が解決するもの全て（branch/tag/remote/hash/`HEAD~N`）。先頭 `-`（git option injection）と空は reject。ラベル「Branch:」。
3. **Branch 欄は index 0（先頭）**: revision スコープが最も基礎的・JetBrains Git Log フィルタ慣例。Author/Since/Until/Path は 1/2/3/4 へシフト。

---

## 2. branch フィルタの意味論

### 2.1 履歴のスコープ

`git log <branch_hash>` は branch tip から到達可能な全コミットを返す（標準的な「この branch の履歴」意味論）。`--topo-order`/`--pretty` 等は logArgv が既に付与済みなので、snapshot_tip = branch_hash で正しい log が得られる。

### 2.2 他フィルタとの compose

branch + author + date + path は全て直交し、`git log --topo-order ... <branch_hash> --fixed-strings --author=X --since=... --until=... -- <paths>` として正しく合成される。logArgv の appendFilterOptions（author/since/until）・appendPaths（`-- <paths>`）は snapshot_tip = branch_hash 上で動くため変更不要。

### 2.3 branch-only の graph 投影

branch-only（他フィルタ無し）でも `filter_state.isEmpty() == false` となり handleLogLoaded の**投影経路**に入る。substrate `rev-list --parents <branch_hash>` で全履歴 topology を取得し、`graph_project.project` が「最近親可視祖先」へ投影して derived `[]log.Commit` を既存 `computeAll` へ入力する。

> ★**「恒等写像」ではない**（codex MINOR 反映）: branch-only でも paging 中の `model.log_commits.items` は**loaded subset**（初回 100 件等）であり、最古 loaded commit の親が未ロードページにあるため下方閉包ではない。よって投影は厳密には恒等ではない。しかし **#2 の paging 自己補正（C1・`handleLogPageLoaded` が全 loaded commits を毎回再投影 + computeAll）** により、可視集合が増大する都度 cross-page の辺が正しく再接続される。branch-only は他フィルタと同様にこの機構で正しい graph が描画される（特例扱い不要）。substrate 取得も `rev-list --parents <snapshot_tip>` の従来呼出しで動く。

### 2.4 branch の所有権と logArgv の関係

branch 条件は FilterSpec に格納されるが、**logArgv/appendFilterOptions は branch を読まない**（revision として既に runLogInt で消費済み）。logArgv は author/since/until/paths のみを argv へ付加する。よって logArgv のシグネチャ・内部は一切変更しない（回帰安全）。

---

## 3. 純粋層の設計

### 3.1 `filter.zig`: branch variant

`FilterCondition` union へ `branch: []u8` を追加:

```zig
pub const FilterCondition = union(enum) {
    author: []u8,
    branch: []u8,   // ★phase 3b #1: branch/revspec（logArgv は無視・runLogInt が snapshot_tip 解決に使用）
    since: []u8,
    until: []u8,
    paths: [][]u8,
};
```

定数・ヘルパ:
- `pub const max_branch_runes: usize = 256;`（author と同値・branch 名/revspec は通常 ASCII 短いが、remote-tracking 等も考慮して十分な上限）。
- `pub fn getBranch(self: FilterSpec) ?[]const u8`（getAuthor と同型・最初の branch variant を借用返し）。
- `deinitCondition`: `.branch => |t| a.free(t)` を追加（author/since/until と同一処理）。
- `cloneCondition`: `.branch => |t| .{ .branch = try a.dupe(u8, t) }` を追加。
- `conditionEql`: `.branch => |t| std.mem.eql(u8, t, b_cond.branch)` を追加。

`addCondition` の variant dedup（同 tag は後勝ち上書き）は `std.meta.activeTag` で動くため、branch も既存仕組みで独立処理される（変更不要・codex m1 踏襲）。OOM 時 payload 自動 deinit（codex M3）も既存仕組みで branch に効く。

### 3.2 `messages.zig`: ApplyFilter.branch

`Msg.ApplyFilter` 構造体へ `branch: ?[]u8` を追加:

```zig
pub const ApplyFilter = struct {
    branch: ?[]u8,   // ★phase 3b #1
    author: ?[]u8,
    since: ?[]u8,
    until: ?[]u8,
    paths: [][]u8,
    pub fn deinit(self: *ApplyFilter, a: std.mem.Allocator) void {
        if (self.branch) |x| a.free(x);   // ★追加
        if (self.author) |x| a.free(x);
        ...
    }
};
```

`Msg.deinit` の `.apply_filter` arm は `af.deinit(a)` で吸収（既存構造・変更不要）。新規テストで branch 付き ApplyFilter の deinit を検証。

### 3.3 `git/commands.zig`: revParseVerify

phase3a は `revParseHeadArgv()`（static・`HEAD` 固定）+ 高レベル `revParseHead(a, io, cwd) !?[]u8`。branch 解決用に**汎化した revspec 解決**を追加。★codex MAJOR/advisory 反映: argv に `--end-of-options`（option injection 防御・真の安全境界）と `^{commit}` peel（blob/tree を弾いて commit のみ受理）を入れる。

**純粋 argv builder**（`logArgv`/`appendFilterOptions` と同型の owned 追跡パターン・revspec から `"<rev>^{commit}"` を生成し owned へ）:
```zig
/// `git rev-parse --verify --end-of-options <rev>^{commit}` argv（branch/revspec 解決用）。
/// ★--end-of-options: 先頭 `-` の入力を option ではなく revspec として扱い injection を防ぐ（真の安全境界・実証済み）。
/// ★^{commit}: blob/tree hash を弾き commit のみ受理（peel 失敗は exit≠0 → null・実証済み）。
/// 実証: `main^{commit}`→exit0 / blob→exit128 / `--all` は eoo 無しだと ref 一覧が stdout へ漏れるが有りだと exit128・stdout 空。
pub fn revParseVerifyArgv(a: std.mem.Allocator, revspec: []const u8) !OwnedArgv {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(a);
    var owned: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned.items) |s| a.free(s);
        owned.deinit(a);
    }
    try list.appendSlice(a, &.{ "git", "rev-parse", "--verify", "--end-of-options" });
    // rev_with_peel を生成し owned へ（appendFilterOptions の git_str と同型・二重 free 回避）。
    const rev_with_peel = std.fmt.allocPrint(a, "{s}^{{commit}}", .{revspec}) catch return error.OutOfMemory;
    owned.append(a, rev_with_peel) catch {
        a.free(rev_with_peel);
        return error.OutOfMemory;
    };
    try list.append(a, rev_with_peel);
    return .{ .args = try list.toOwnedSlice(a), .owned = owned };
}
```

> ★**所有権**（既存パターン踏襲）: `rev_with_peel` は `owned` へ追跡され `OwnedArgv.deinit` が free。`list` にも同じポインタが入るが args slice は free しない（owned が 1 回だけ free・二重 free 無し）。`owned.append` 失敗時は手動 free して返す（owned errdefer が触らない段階）。ユーザーが既に `^{commit}` を含む入力（例 `main^{commit}`）を渡しても `main^{commit}^{commit}` となり peel は冪等（実証済み・commit→commit は no-op）なので安全。`--end-of-options` は合法 revspec（branch/tag/hash/`HEAD~5`/`origin/main` 等・いずれも先頭非 `-`）には影響しない（実証済み）。

**高レベル**（`revParseHead` と同型・exit≠0 は null）:
```zig
/// revspec を commit hash へ解決（呼出側 free）。exit≠0（不明 branch/rev・blob/tree・peel 失敗）は null。
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

`logArgv`/`logPageArgv`/`appendFilterOptions`/`appendPaths` は**一切触らない**（branch は revision 側で処理・logArgv 回帰安全）。

### 3.4 `update.zig`: handleApplyFilter の branch バリデーション

`handleApplyFilter`（§4.4 payload-first トランザクショナル）へ branch バリデーションを追加。author/since/until のバリデーション群と**同じ構造**（失敗時はモーダル閉じず `log_load_error` へ）:

```zig
if (af.branch) |text| {
    if (text.len > 0) {
        // 先頭 `-` は git option injection（例: "--all" が rev として渡ると危険）→ reject。
        // ★codex MAJOR: argv builder（revParseVerifyArgv の --end-of-options）が真の安全境界だが、
        //   ここで弾くことで「分かりやすい日本語エラー」を先に出す（defense in depth・UX 層）。
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

バリデーション通過後、FilterSpec 構築フェーズで:
```zig
if (af.branch) |text| {
    if (text.len > 0) {
        try new_spec.addCondition(a, .{ .branch = try a.dupe(u8, text) });
    }
}
```

**バリデーションは構文のみ**（空・先頭 `-`・長さ）。**存在確認はしない**（reducer は純粋・git 非到達のため。存在確認は appcmd の rev-parse で行う・§3.5）。空文字は null 正規化（branch 条件を作らない・author 等と同様）。

`buildLoadLogCmd` は filter_state 全体を clone するため、branch も自動伝播（**変更不要**）。

### 3.5 `appcmd.zig`: runLogInt の snapshot_tip 解決分岐

`runLogInt`（§6.1）の snapshot_tip 解決を branch 有無で分岐:

現状（`appcmd.zig:197-201`）:
```zig
const snapshot_tip = cmds.revParseHead(a, io, cwd) catch
    return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
if (snapshot_tip == null) return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
```

新仕様（★codex advisory 反映: 具体的な形へ固定）:
```zig
const branch = cmd.filter.getBranch();
const snapshot_tip: ?[]u8 = if (branch) |b| blk: {
    // branch 有り: rev-parse --verify --end-of-options <b>^{commit} で解決。
    const resolved = cmds.revParseVerify(a, io, cwd, b) catch
        return mkLoadFailedOrSilent(a, cmd, "ブランチ/リビジョンの解決に失敗", null);
    if (resolved == null) return branchLoadFailed(a, cmd, b);  // 不明/非 commit → LogLoadFailed
    break :blk resolved;
} else
    cmds.revParseHead(a, io, cwd) catch
        return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
if (snapshot_tip == null) return mkLoadFailedOrSilent(a, cmd, "HEAD 解決失敗", null);
defer a.free(snapshot_tip.?);
```

**`branchLoadFailed` ヘルパ**（★codex advisory: 解決不能を LogLoadFailed へ正規化する小ヘルパ・具体化）:
```zig
/// branch 解決失敗（exit≠0: 不明な branch/revspec・blob/tree・peel 失敗）→ branch 名入りの LogLoadFailed。
/// メッセージ dupe の OOM は mkLoadFailedSilent へ fallback（強例外保証・既存 mkLoadFailedOrSilent と同型）。
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

> ★**設計判断**: `revParseVerify` は `!?[]u8`（RunError を伝播・exit≠0 は null）。runLogInt が null を `branchLoadFailed` で LogLoadFailed へ正規化し、RunError を `mkLoadFailedOrSilent` へ。これにより runLogInt の「ここより後は infallible（`defer a.free(snapshot_tip.?)` 以降）」境界（§6.1 既存）を崩さない。ヘルパは既存 `mkLoadFailed*` ファミリと同じ Msg 構築パターンで一貫。

**headState チェックは先頭のまま**（unborn/err 短絡は不変）。unborn リポジトリで branch 指定時 → headState が `.unborn` を返し、unborn 空結果（`request_tip=""`, `is_unborn=true`）へ短絡する。unborn リポジトリに branch は存在しないため、これは妥当（branch フィルタは実質無効化・ユーザーには `(no commits)` 表示）。

**substrate 取得は不変**: `runLogInt:229-232` の `if (!cmd.filter.isEmpty()) fetchSubstrate(...)` は branch-only でも isEmpty()==false で substrate を取得。snapshot_tip = branch_hash で従来呼出しが動く（§2.3）。

---

## 4. UI 層の設計

### 4.1 `model.zig`: filter_modal_focus 型拡張

現状 `filter_modal_focus: u2`（0-3・4 欄）。**`u3`（0-7・5 欄は 0-4 を使用）へ拡張**。model の init/deinit/test の `u2` 参照を `u3` へ更新。

★**wrap ロジックの gotcha（核心）**: 現状 `handleFilterFocusNext` は `model.filter_modal_focus +%= 1`（u2 wrapping add）。u2 では `3 +%= 1 == 0`（オーバーフローで wrap）が、**u3 では `4 +%= 1 == 5`** となり wrap しない（5 は空の 6 欄目へ飛ぶ・バグ）。よって**明示的 bound へ変更**:

```zig
const filter_field_count: u3 = 5;  // Branch/Author/Since/Until/Path

fn handleFilterFocusNext(model: *Model) !AppCmd {
    model.filter_modal_focus =
        if (model.filter_modal_focus == filter_field_count - 1) 0
        else model.filter_modal_focus + 1;
    return .none;
}
fn handleFilterFocusPrev(model: *Model) !AppCmd {
    model.filter_modal_focus =
        if (model.filter_modal_focus == 0) filter_field_count - 1
        else model.filter_modal_focus - 1;
    return .none;
}
```

`% 4` 等の comptime 割算は使わない（date-path spec §4.3 codex m2 と同様・u3 へ fit しない）。既存テスト `filter_focus_next: wraps 3→0` は `wraps 4→0` へ更新。

### 4.2 `input.zig`: 変更不要

`filter_focus_next`/`filter_focus_prev`/`shift_tab`/`tab`/`close_filter_modal` は既存 Msg のまま（reducer 側で wrap・入力正規化は不変）。モーダル open 時の global key 抑止（M6）も不変。

### 4.3 `view.zig`: filterReasonText へ branch セグメント

`filterReasonText`（§8.2）へ branch を**先頭**セグメントとして追加（field 順序と一致・Branch が index 0）:

```zig
fn filterReasonText(a, filter) []const u8 {
    if (filter.isEmpty()) return "";
    ...
    buf.appendSlice(a, "Filter:") catch return "Filter:";
    if (filter.getBranch()) |text| {
        const part = std.fmt.allocPrint(a, " branch=\"{s}\"", .{text}) catch return "Filter:";
        defer a.free(part);
        buf.appendSlice(a, part) catch return "Filter:";
    }
    if (filter.getAuthor()) |text| { ... }  // 既存
    ...
}
```

形式: `Filter: branch="main" author="..." since=... until=... paths=...`。`logEmptyKind`・renderLog の suppressed メタ行ロジックは不変（branch も filter 非空扱い・branch-only は投影成功で policy=.auto なのでメタ行は出ない）。

### 4.4 `main.zig`: 5 欄 TextInput

`App` へ `filter_branch_input: zz.TextInput` を追加（index 0・他は 1-4 へシフト）。初期化（`§9.1` 相当）:
```zig
g_app.filter_branch_input = zz.TextInput.init(ctx.persistent_allocator);
g_app.filter_branch_input.setCharLimit(256);          // max_branch_runes と一致
g_app.filter_branch_input.setPlaceholder("branch or rev");
```

以下の関数を 5 欄（Branch=index 0）へ拡張:
- **`syncFilterModal`**: open 時に `filter_branch_input.setValue(fs.getBranch() orelse "")` を追加（他欄は index 1-4 へ）。
- **`syncFocus`**: `switch (focus) { 0 => branch.focus(), 1 => author.focus(), 2 => since.focus(), 3 => until.focus(), 4 => path.focus() }`。
- **`focusTextInput`**: 同様の switch で `*zz.TextInput` を返す。
- **`buildModalBody`**: `"Branch: {s}\nAuthor: {s}\nSince:  {s}\nUntil:  {s}\nPath:   {s}"`（Branch 先頭・フォーカス欄のみ `.view(a)`・他は getValue）。
- **`applyFilterFromModal`**: `af.branch` を dupe（空なら null）し `Msg.apply_filter` へ積む。OOM 時の rollback（`af.deinit(gpa)` + `setLogLoadError`）は既存パターンを踏襲。

`deinit` で `filter_branch_input.deinit()` を追加。

---

## 5. argv 構築順序 & snapshot_tip 解決のデータフロー

### 5.1 apply_filter → load_log → runLogInt の流れ

1. `f` キー → `open_filter_modal`（focus=0 = Branch 欄）。
2. ユーザー入力 → Enter → `applyFilterFromModal` が `ApplyFilter{ branch, author, since, until, paths }` を dupe 構築 → `Msg.apply_filter`。
3. `handleApplyFilter`: branch バリデーション（§3.4）→ FilterSpec 構築（branch 含む）→ Model swap → `load_log`（filter = clone・branch 含む）発行。generation 更新・snapshot_tip クリア・graph_render_policy=.auto。
4. `appcmd.runLogInt`: headState → snapshot_tip 解決（§3.5: branch 有りなら `rev-parse --verify <branch>`・無ければ HEAD）→ `logArgv(snapshot_tip, filter)` → `git log --topo-order ... <snapshot_tip> --author=... -- <paths>` → `log_loaded`（request_tip = snapshot_tip・substrate = branch 有 filter 時に取得）。
5. `handleLogLoaded`: snapshot_tip 設定 → filter 非空なので投影経路 → substrate clone → `graph_project.project` → `computeAll`（derived）→ graph 描画。

### 5.2 paging の一貫性

`handleLogLoaded` が `log_snapshot_tip` = branch_hash を設定。paging（`handleLogCursorDown` の R17 trigger）は `model.log_snapshot_tip` から `tip_hash` を dupe → `runLogPageInt` → `logPageArgv(tip_hash=branch_hash, filter)` → `git log <branch_hash> --skip=N ...`。`handleLogPageLoaded` の `request_tip == log_snapshot_tip`（branch_hash）照合が**成功**（単一 tip・B3 解消）。substrate も branch_hash で再投影（#2 の全再投影自己補正 C1）。

### 5.3 clear_filter / mode toggle / refresh での保持

branch 条件も他フィルタと同様に FilterSpec の一部として保持（M5）。`clear_filter`（`F`）は全条件（branch 含む）を解放。`toggle_view_mode`/`request_refresh`/bad revision recovery でも filter 保持（`buildLoadLogCmd` が filter_state を clone するため branch も伝播）。

---

## 6. エラー処理

### 6.1 branch 解決失敗の経路

| 失敗種 | 検出 | Msg | ユーザー体験 |
|---|---|---|---|
| 不明な branch/revspec（exit≠0） | `revParseVerify` → null | `log_load_failed`（"ブランチ/リビジョン '<入力>' が見つかりません"） | `log_load_error` 表示・commits 空。filter_state に branch 残存 → `f` で再編集可 |
| rev-parse spawn/OOM | `revParseVerify` → RunError | `log_load_failed`（"ブランチ/リビジョンの解決に失敗"） | 同上 |
| メッセージ dupe OOM | `allocPrint` 失敗 | `log_load_failed_silent`（generation 照合のみ） | 安全側（silent） |

### 6.2 構文バリデーション失敗（reducer・モーダル維持）

- 先頭 `-` → `log_load_error`「先頭に - は使えません」・モーダル閉じず。
- 256 rune 超 → `log_load_error`・モーダル閉じず。
- 空 → null 正規化（branch 条件無し・他フィルタのみ適用）。

### 6.3 filter_state 残存と再編集

branch 解決失敗後、`filter_state` には branch が保持される（handleApplyFilter が load_log 発行前に swap 済み）。ユーザーは `f` でモーダルを再展開すると Branch 欄に失敗した入力がプレフィルされる（syncFilterModal が getBranch を setValue）→ 修正して再適用、または `F` で全クリア。author 等の既存フィルタと同じ UX（M5）。

---

## 7. graph 投影との整合（phase3b #2 不変性の検証）

| 箇所 | branch フィルタ時の挙動 | #2 インフラへの影響 |
|---|---|---|
| `fetchSubstrate` | snapshot_tip = branch_hash で `rev-list --parents <branch_hash>` | **不変**（呼出しシグネチャ同一） |
| `graph_project.project` | visible = branch のフィルタ結果（loaded subset・下方閉包とは限らない）。#2 の「最近親可視祖先」投影 + paging 全再投影（C1）で正しい graph | **不変**（visible 集合の定義が変わるのみ・ロジック不変） |
| `handleLogLoaded` 投影経路 | `filter_state.isEmpty()==false` で投影 computeAll | **不変**（branch も isEmpty を false にする） |
| `handleLogPageLoaded` 全再投影 | 同上・C1 自己補正 | **不変** |

結論: branch フィルタは #2 の substrate/投影/paging を**一切変更せず**再利用する。新規コードは runLogInt の snapshot_tip 解決分岐のみ。

---

## 8. テスト計画（TDD・純粋層 → UI）

### 8.1 `filter.zig`
- `FilterSpec: branch addCondition/getBranch/clone/eql/deinit`（author と同型）。
- `FilterSpec: duplicate branch overwrites`（codex m1 踏襲・後勝ち）。
- `FilterSpec: branch + author + paths multi-variant clone no leak`。
- `addCondition OOM no payload leak (M3)` へ branch variant を追加（既存 checkAllAllocationFailures helper へ branch を足すか、branch 専用 helper）。
- `max_branch_runes constant = 256`。

### 8.2 `git/commands.zig`
- `revParseVerifyArgv: git rev-parse --verify --end-of-options <rev>^{commit}`（★codex MAJOR/advisory: `--end-of-options` + `^{commit}` peel・revspec は `"<rev>^{commit}"` として owned へ 1 文字列・形式検証・owned.items.len==1・`--end-of-options` が rev の直前）。

### 8.3 `appcmd.zig`（実一時 repo・`TmpRepo` 使用）
- `load_log with branch filter returns branch tip's commits + substrate`（repo で `git branch dev` 作成 → load_log with `.branch = "dev"` → log_loaded・request_tip は dev の tip・substrate 非null）。
- `load_log with non-existent branch returns LogLoadFailed`（`.branch = "no-such-branch"` → log_load_failed・error_text に branch 名含む）。
- `load_log with blob/tree hash returns LogLoadFailed`（★codex advisory: ファイルへ hash で commit した blob を `.branch = "<blob-hash>"` → `^{commit}` peel 失敗 → log_load_failed・「見つかりません」）。
- `load_log with annotated tag resolves to commit`（tag → `^{commit}` peel → commit の log_loaded・オプション検証）。
- `load_log with branch + author composes`（branch dev + author → 両方適用された log_loaded）。
- 回帰: 既存の `load_log returns log_loaded with 3 commits`・`load_log with author filter returns LogLoaded with substrate` は不変（branch 無し = HEAD 解決）。

### 8.4 `update.zig`
- `apply_filter: branch only validates and stores`（branch="dev" → filter_state.getBranch=="dev"・load_log 発行）。
- `apply_filter: branch leading dash rejected`（branch="-all" → log_load_error・モーダル維持・filter_state.isEmpty）。
- `apply_filter: branch too long rejected`（>256 rune → log_load_error）。
- `apply_filter: branch empty normalizes to null`（branch="" → branch 条件無し）。
- `filter_focus_next: wraps 4→0 (u3)`（5 欄・focus=4 → 0）。
- `filter_focus_prev: wraps 0→4`。
- `open_filter_modal: resets focus to 0`（既存・u3 で 0）。
- 回帰: 既存 `filter_focus_next: wraps 3→0` は `4→0` へ更新。

### 8.5 `view.zig`
- `filterReasonText: branch only`（`Filter: branch="main"`）。
- `filterReasonText: all variants`（branch + author + since + until + paths）。
- 回帰: 既存 `filterReasonText` テストへ branch ケース追加。

### 8.6 `messages.zig`
- `Msg.apply_filter (ApplyFilter) deinit frees all fields incl branch`。
- `ApplyFilter.deinit method callable standalone`（branch 付き）。

### 8.7 全体
- `zig build test --summary all`（Debug 既定）で既存 542 + 新規 green。
- `zig build`（main.zig の型検査）。
- tmux pty（実端末）で: branch 適用 → 該当 branch の log + graph 表示・paging・clear_filter 復帰・不明 branch のエラー表示・Branch 欄 Tab/Shift+Tab cycle（5 欄）を目視。

---

## 9. リスク & mitigation

| Risk | 重要度 | mitigation | 根拠 |
|---|---|---|---|
| u2→u3 の wrap バグ（`+%=1` が wrap しない） | 高 | 明示的 bound（§4.1・`filter_field_count` 定数）・テスト `wraps 4→0` | date-path §4.3 codex m2 の u2 教訓・u3 では必須 |
| branch 先頭 `-` の option injection | 中 | argv builder の `--end-of-options`（真の安全境界・§3.3）+ reducer の先頭 `-` reject（UX 層・§3.4）の二重防御（codex MAJOR） | `revParseVerifyArgv` が `git rev-parse --verify --end-of-options <rev>^{commit}` を生成。reducer を経由しない呼出経路/テストでも安全 |
| blob/tree hash が revspec として渡る | 低 | `^{commit}` peel で解決時点で弾く（codex advisory）→「見つかりません」。peel 無しだと `git log <blob>` が exit 128 で後段失敗（劣化だが安全）だったのが解決時点の綺麗なエラーへ | `git rev-parse --verify --end-of-options <rev>^{commit}` |
| revspec に `^main`/`..` 等の range 演算子が渡る | 低 | `--end-of-options` + `^{commit}` で range 演算子は妥当な単一 commit へ解決不能 → exit≠0 →「見つかりません」 | git rev-parse --verify の単一 object 要求 semantics |
| branch 解決失敗後の filter_state 残存で再適用ループ | 低 | `f` で再編集・`F` で全クリア（既存 UX・§6.3） | author 等と同様・M5 |
| unborn repo で branch 指定時の挙動 | 低 | headState 先頭のまま・unborn 短絡（§3.5） | unborn に branch は存在しないため妥当 |
| branch-only で投影が graph を壊す | 低 | paging subset は下方閉包でないが #2 の全再投影自己補正（C1）で正しく描画（§2.3） | テストで投影結果の整合を確認 |
| branch 解決失敗後の filter_state 残存で再適用ループ | 低 | `f` で再編集・`F` で全クリア（既存 UX・§6.3） | author 等と同様・M5 |
| unborn repo で branch 指定時の挙動 | 低 | headState 先頭のまま・unborn 短絡（§3.5） | unborn に branch は存在しないため妥当 |
| branch-only で投影が graph を壊す | 低 | paging subset は下方閉包でないが #2 の全再投影自己補正（C1）で正しく描画（§2.3） | テストで投影結果の整合を確認 |

---

## 10. 完了条件

- [ ] branch フィルタ適用で該当 branch/rev の log + graph が表示される（投影経由・policy=.auto）。
- [ ] paging が branch snapshot で一貫（tip 照合成功・B3 解消）。
- [ ] branch + author/since/until/paths の compose が正しい。
- [ ] 不明 branch で typed error 表示・`f`/`F` で回復。
- [ ] Branch 欄 Tab/Shift+Tab cycle が 5 欄で正しく動く（u3 wrap）。
- [ ] clear_filter / mode toggle / refresh で branch 保持・解除。
- [ ] `zig build test --summary all` で既存 + 新規 green・`zig build` 成功。
- [ ] tmux pty で上記を目視。
- [ ] TODO.md:195 のチェックボックスを `[x]` へ・実装詳細追記。
- [ ] README のフィルタ説明へ Branch 欄（任意 revspec 受理）を追記。

---

## 11. phase3a §16 拡張ポイントの残り

本 spec は branch のみ実装。`--grep`（コミットメッセージ検索）は phase3a §16 の別拡張ポイント。`--fixed-strings` は `--author`/`--grep` に影響するため、`--grep` 追加時に再検証が必要（phase3a §2/M8）。本 spec では扱わない。
