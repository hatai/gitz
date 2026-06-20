# TODO 2 phase3a コミットログフィルタ（作者 MVP）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `f` キーでモーダルを開き作者名（partial）でコミットログを絞り込む。フィルタ中は graph を非表示し、paging 一貫性は `log_snapshot_tip`（rev-parse HEAD）で保証する。

**Architecture:** Elm 風・副作用隔離（`CLAUDE.md`）。純粋層（`filter.zig` 新設 / model / messages / update / appcmd / git/commands / git/process）を TDD → UI 層（input / view / main）を配線。フィルタは `git log --fixed-strings --author=<literal>`。graph は `graph_render_policy` で非表示。paging は `<snapshot_tip>` revision 明示限定で race 回避。

**Tech Stack:** Zig 0.16.0, zigzag v0.1.5（固定）, `std.process.run`, `std.Io.Limit`, `std.ArrayList` unmanaged, `std.testing.allocator`, `checkAllAllocationFailures`。

**Spec:** `docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md`（rev.3・codex 2 ラウンドレビュー済み）。各 Task の実装詳細（構造体 field・reducer ステップ・argv 形）は **spec の該当節** を正として参照すること。本 plan は「何を・どこで・どうテストするか」を示し、コードの完全な形は spec を見て展開する。

**規約（`CLAUDE.md`/`AGENTS.md`・全 Task で厳守）:**
- `std.ArrayList(T)` は unmanaged（`.empty` / `append(a, x)` / `toOwnedSlice(a)` / `deinit(a)`）
- 子プロセスは `std.process.run(gpa, io, opts)`（io 必須）・`opts.stdout_limit`/`stderr_limit` は `std.Io.Limit.limited(N)`/`.unlimited`・`Term.exited`（小文字 u8）
- テストは実装 `.zig` 内の `test {}` block・`std.testing.allocator` 必須・arena 関数は `std.heap.ArenaAllocator`・各ファイルに `test { std.testing.refAllDecls(@This()); }`
- 所有権: Msg/AppCmd ペイロードは複製所有・消費者が deinit・Model 文字列は persistent 所有・置換時に旧 free（トランザクショナル）
- **コード内にコメントを書かない**（`//!` ファイル doc と test block の説明文のみ可）
- テスト実行は常に `zig build test --summary all`（build.zig に `--test-filter` 未配線・AGENTS.md）

---

## File Structure

| File | 操作 | 責任 |
|---|---|---|
| `src/filter.zig` | **Create** | `FilterSpec`（author: ?[]u8 のみ・phase3b 拡張余地）・純粋・zigzag 非依存 |
| `src/root_test.zig` | Modify | `_ = @import("filter.zig");` 追加 |
| `src/model.zig` | Modify | Model へ `filter_state`/`filter_modal_open`/`log_load_error`/`log_snapshot_tip`/`graph_render_policy` 追加・**`log_paging_tip` 廃止**・ヘルパ・init/deinit |
| `src/messages.zig` | Modify | 新 Msg タグ・`LogLoaded` 拡張・新 `LogLoadFailed`/`LogLoadFailedSilent`・`LoadLog`/`LoadLogPage` へ filter・deinit switch 網羅更新 |
| `src/git/commands.zig` | Modify | `OwnedArgv`・`logArgv`/`logPageArgv` へ filter+snapshot_tip・`revParseHeadArgv`/`revParseHead`・`freeLogArgv`/`freeLogPageArgv` → `OwnedArgv.deinit` |
| `src/git/process.zig` | Modify（必要なら） | StreamTooLong 扱い・limit 注入（既存 RunError を確認して最小） |
| `src/appcmd.zig` | Modify | `runLogInt`（rev-parse HEAD → LogLoaded/Failed/Silent）・`runLogPageInt`（snapshot_tip+filter）・bad revision → LogPageFailed・StreamTooLong 正規化 |
| `src/update.zig` | Modify | `log_paging_tip`→`log_snapshot_tip` 全置換・`handleLogLoaded`/`handleLogPageLoaded` 拡張・`buildLoadLogCmd`・`apply_filter`/`clear_filter`/`open_filter_modal`/`close_filter_modal`/`handleLogLoadFailed`/`handleLogLoadFailedSilent`・`git_error`(log) load_log 廃止 |
| `src/input.zig` | Modify | `keyToMsgForLog` へ `f`/`F`・modal 優先・mouse 抑止 |
| `src/view.zig` | Modify | `renderLogMode` で modal 時 `viewWithBackdrop`・`renderLog` へ policy・graph 非表示理由・`log_load_error`・is_unborn/空一致切り分け |
| `src/main.zig` | Modify | `App` へ `filter_textinput`/`filter_modal`・handleKey routing・Enter で `apply_filter: []u8`・`open_filter_modal` で `setValue`・Modal show/hide 同期 |
| `docs/superpowers/plans/zigzag-api-notes.md` | Modify | L266-267, L278 を TextInput/Modal 実シグネチャへ（spec §15） |
| `TODO.md` | Modify | phase3「フィルタ UI」「作者」を部分チェック・phase3b 残明記 |

---

## Task 1: api-notes へ TextInput/Modal 実シグネチャ追記

**Spec:** §15  **Files:** Modify `docs/superpowers/plans/zigzag-api-notes.md`（L266-267, L278）

- [ ] **Step 1:** `zigzag-api-notes.md` L266-267（TextInput stub）と L278（Modal 列挙）を、spec §15 の実シグネチャへ置換・拡充。`TextInput`（`init(allocator)`/`deinit`/`setValue`/`getValue() []const u8` borrowed/`setPlaceholder`/`setPrompt`/`setWidth`/`setCharLimit`/`setEchoMode`/`focus`/`blur`/`handleKey`・enter/escape は処理しない/`view(allocator)`）と `Modal`（`init`/`show`/`hide`/`isVisible`/`addButton`/`handleKey`・button_count==0 で enter は no-op/`view`/`viewWithBackdrop` 全面 canvas・透過しない/`renderBox`・Presets・`Result`/`Size`/`Backdrop`）を記載。overlay の罠（join 不可・全面置換）と button+TextInput 混在の注意も含める。
- [ ] **Step 2:** `zig build` で docs 変更がビルドを壊さないことを確認。
- [ ] **Step 3:** Commit: `git add docs/superpowers/plans/zigzag-api-notes.md && git commit -m "docs(api-notes): replace TextInput/Modal stubs with real signatures (M7)"`

---

## Task 2: FilterSpec 新設（`src/filter.zig`）

**Spec:** §1.1, §2  **Files:** Create `src/filter.zig` / Modify `src/root_test.zig`

- [ ] **Step 1:** `src/filter.zig` へ失敗テストを書く。`test "FilterSpec: isEmpty/setAuthor/clearAuthor/clone/eql/deinit"`（`std.testing.allocator`・`init`→`isEmpty==true`→`setAuthor("foo")`→`isEmpty==false`・`eql(clone)==true`・`deinit` でリーク無し）。`test "FilterSpec: setAuthor OOM leaves state unchanged"`（`std.testing.checkAllAllocationFailures` で `setAuthor` の dupe 失敗時 self 不変）。`test "FilterSpec: empty string normalizes to null"`。`test "FilterSpec: max_author_runes boundary (256 ok / 257 error)"`（`std.unicode.utf8CountCodepoints` で 256/257）。`test "FilterSpec: UTF-8 author preserved through clone"`（日本語）。`test { std.testing.refAllDecls(@This()); }`。
- [ ] **Step 2:** `src/root_test.zig` へ `_ = @import("filter.zig");` を追加（AGENTS.md・追加忘れるとテスト非実行）。
- [ ] **Step 3:** `zig build test --summary all` → FAIL（`FilterSpec` 未定義）。
- [ ] **Step 4:** `FilterSpec` を実装（spec §1.1 の field 定義 + メソッド）。field は `author: ?[]u8`（persistent 所有）のみ。定数 `max_author_runes: usize = 256`。メソッド: `init()`/`isEmpty()`/`setAuthor(a, value)`（空文字は `clearAuthor`・`utf8CountCodepoints` > 256 は `error.AuthorTooLong`・dup 成功後に旧 free・トランザクショナル）/`clearAuthor(a)`/`clone(a)`（errdefer で順次 rollback）/`eql(other)`/`deinit(a)`。`//!` doc comment で「phase3b 拡張ポイント（since/until/path/branches）」を明記。**コード内コメント禁止**。
- [ ] **Step 5:** `zig build test --summary all` → PASS。
- [ ] **Step 6:** Commit: `git add src/filter.zig src/root_test.zig && git commit -m "feat(filter): add FilterSpec with clone/deinit and OOM safety (M4/M-N7)"`

---

## Task 3: Model 拡張と `log_paging_tip` → `log_snapshot_tip` 一本化

**Spec:** §1.2, §1.3, §1.4  **Files:** Modify `src/model.zig`（L23-66 Model 構造体・L65 log_paging_tip・L67 init・deinit・ヘルパ L237-368）

- [ ] **Step 1:** `src/model.zig` の該当 test block へ失敗テスト追加。`test "Model: log_snapshot_tip set/clear"`・`test "Model: filter_state set/clear transactional"`・`test "Model: graph_render_policy default auto"`・`test "Model: log_load_error setStr"`・`test "Model: filter_modal_open default false"`（`std.testing.allocator`・各ヘルパ呼出とリーク検出）。phase2 の `log_paging_tip` テストがあれば `log_snapshot_tip` へ更新。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新 field/ヘルパ 未定義・`log_paging_tip` 参照残りはコンパイルエラー）。
- [ ] **Step 3:** Model 構造体（L44-65 付近）へ新 field 追加（spec §1.2）: `filter_state: FilterSpec`（`const filter_mod = @import("filter.zig");` を先頭へ）・`filter_modal_open: bool`・`log_load_error: []u8`・`log_snapshot_tip: ?[]u8`・`graph_render_policy: enum { auto, suppressed }`。**`log_paging_tip: ?[]u8`（L65）は削除**。`init`（L67）へデフォルト値追加。`deinit` へ `filter_state.deinit(a)`/`a.free(log_load_error)`/`log_snapshot_tip` free を追加。ヘルパ追加: `setFilterState(new_spec)`（旧 deinit → swap）/`clearFilterState()`/`setLogSnapshotTip(hash)`（setStr と同型・OOM で self 不変）/`clearLogSnapshotTip()`/`setLogLoadError(text)`。旧 `setLogPagingTip`/`clearLogPagingTip` は削除。
- [ ] **Step 4:** `zig build test --summary all` → `update.zig`/`appcmd.zig` が `log_paging_tip`/`setLogPagingTip` を参照してコンパイルエラー（想定内・Task 6/8 で解決）。**この Task では model.zig のみ修正し、他ファイルのビルドエラーは Task 6 で直すまで一時的に受け入れる**（コミットは `--no-verify` 不要・ローカルで `zig build test` が通らない段階）。代わりに model.zig 単体のテストのみ `zig test` で確認する場合は、一時的に update.zig の該当行を `log_snapshot_tip` へ書き換えてから実行（Task 6 で正式化）。**実用的には Task 3 と Task 6 を連続して実施し、両方コミット後に `zig build test` が通るようにする**。
- [ ] **Step 5:** Commit: `git add src/model.zig && git commit -m "refactor(model): unify log_paging_tip into log_snapshot_tip, add filter fields (B1/B2)"`

> **注意:** この Task と Task 6 は密結合（`log_paging_tip` 廃止が update.zig/appcmd.zig に波及）。単独ではビルドが通らない。Task 6 まで進めてから `zig build test` で全体確認する。

---

## Task 4: messages.zig 拡張（新 Msg・LogLoaded 拡張・LoadLog/LoadLogPage filter）

**Spec:** §3  **Files:** Modify `src/messages.zig`（Msg union L8-56・LogLoaded L58-63・deinit L90-168・AppCmd L171-200・AppCmd.deinit L202-235）

- [ ] **Step 1:** 失敗テストを書く。`test "Msg.deinit: apply_filter frees payload"`・`test "Msg.deinit: log_loaded frees request_tip"`・`test "Msg.deinit: log_load_failed frees error_text and request_tip"`・`test "AppCmd.deinit: load_log frees filter"`・`test "AppCmd.deinit: load_log_page frees filter and tip_hash"`（`std.testing.allocator`・各 Msg/AppCmd を構築して `deinit`・リーク検出）。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新タグ/field 未定義）。
- [ ] **Step 3:** Msg union（L8）へ新タグ追加: `open_filter_modal`/`close_filter_modal`/`apply_filter: []u8`（所有・spec §3.1）/`clear_filter`/`log_load_failed: LogLoadFailed`/`log_load_failed_silent: LogLoadFailedSilent`。`LogLoaded`（L58-63）へ `request_tip: []u8`（所有）と `is_unborn: bool` を追加。新構造体 `LogLoadFailed { request_generation: u64, request_tip: ?[]u8, error_text: []u8 }` と `LogLoadFailedSilent { request_generation: u64 }`。`AppCmd.LoadLog`（L193）へ `filter: FilterSpec`、`LoadLogPage`（L194-199）へ `filter: FilterSpec` を追加（`const filter_mod = @import("filter.zig");` を先頭へ）。
- [ ] **Step 4:** `Msg.deinit` switch（L90-168）へ追加: `.log_loaded` へ `a.free(ll.request_tip);`（既存 entries 解放と併存）・`.log_load_failed => |llf| { a.free(llf.error_text); if (llf.request_tip) |t| a.free(t); }`・`.log_load_failed_silent => {}`・`.apply_filter => |text| a.free(text)`・`.open_filter_modal`/`.close_filter_modal`/`.clear_filter => {}`。`AppCmd.deinit` switch（L202-235）へ: `.load_log => |ll| ll.filter.deinit(a)`（phase2 `=> {}` から arm 独立化）・`.load_log_page => |llp| { a.free(llp.tip_hash); llp.filter.deinit(a); }`。**網羅 switch なので新タグを足すとコンパイラが deinit の分岐追加を強制する**（else 無し）。
- [ ] **Step 5:** `zig build test --summary all` → FAIL（appcmd/update が新 field 無しでリテラル構築するとコンパイルエラー・Task 5/6/8 で解決）。この Task では messages.zig のみ。Task 5-8 で呼出元を更新。
- [ ] **Step 6:** Commit: `git add src/messages.zig && git commit -m "feat(messages): add filter Msg/LogLoadFailed and filter in LoadLog/LoadLogPage (B1/B4/D1)"`

---

## Task 5: commands.zig（OwnedArgv + logArgv/logPageArgv + revParseHead）

**Spec:** §5  **Files:** Modify `src/git/commands.zig`（logArgv L60-81・logPageArgv L85-112・headState L193-218・freeLogArgv/freeLogPageArgv）

- [ ] **Step 1:** 失敗テストを書く。`test "logArgv: empty filter unchanged"`（filter.isEmpty なら既存 argv と一致・回帰）・`test "logArgv: author filter adds --fixed-strings --author"`（argv へ `--fixed-strings` と `--author=foo` が含まれる・順序）・`test "logArgv: snapshot_tip pinned as revision"`（argv へ `<snapshot_tip>` が revision として含まれる）・`test "logArgv: OOM rollback frees partial"`（`checkAllAllocationFailures` で owned の部分確保失敗時に leak 無し）・`test "logPageArgv: skip + snapshot_tip + filter"`・`test "revParseHeadArgv: form"`・`test "OwnedArgv.deinit: frees owned only"`（借用 path は free しない）。`std.testing.allocator`。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新関数/構造体 未定義）。
- [ ] **Step 3:** `OwnedArgv` 構造体を新設（spec §5.2）: `args: []const []const u8` と `owned: std.ArrayList([]const u8)`・`deinit(a)` は owned のみ free + args slice free。`logArgv(a, skip, max_count, snapshot_tip: []const u8, filter: FilterSpec) !OwnedArgv` へ変更（spec §5.2）: argv = `git -c core.quotePath=false log --topo-order --fixed-strings` + 必要なら `--skip=N` + `--max-count=N` + filter.author ありなら `--author=<raw>` + `<snapshot_tip>`（revision 明示限定）+ `--pretty=format:...` + `-z`（既存 format 维持）。各 `allocPrint` 直後に `errdefer` で owned/list の rollback。`logPageArgv(a, skip, max_count, snapshot_tip, filter) !OwnedArgv` も同様（`--topo-order --skip=N --max-count=100 <snapshot_tip>`）。`revParseHeadArgv() []const []const u8`（`git rev-parse --verify HEAD`・借用 static）と `revParseHead(a, io, cwd) !?[]u8`（unborn は exit 128 → null・spec §6.1）。`freeLogArgv`/`freeLogPageArgv` は削除（`OwnedArgv.deinit` へ統合）。`escapeRegexLiteral` は**作らない**（--fixed-strings 採用・M-N6）。
- [ ] **Step 4:** `zig build test --summary all` → FAIL（appcmd が旧 freeLogArgv や旧 logArgv シグネチャ呼び出しでコンパイルエラー・Task 8 で解決）。
- [ ] **Step 5:** Commit: `git add src/git/commands.zig && git commit -m "feat(commands): OwnedArgv + logArgv/logPageArgv with filter+snapshot_tip (D1/M11/B1)"`

---

## Task 6: update.zig 前半（log_paging_tip→log_snapshot_tip 全置換 + handleLogLoaded/PageLoaded + buildLoadLogCmd）

**Spec:** §4.1, §4.2, §4.5, §4.8  **Files:** Modify `src/update.zig`（git_error L253-277・dispatch L283-345・handleToggleViewMode L366-400・handleRequestRefreshLog L501-524・handleLogLoaded L548-592・handleLogPageLoaded L599-640・handleLogPageFailed L643-668）

- [ ] **Step 1:** 失敗テストを書く。`test "handleLogLoaded: stores snapshot_tip from request_tip"`・`test "handleLogLoaded: graph suppressed skips computeAll"`（`graph_render_policy=.suppressed` で `log_graph_state` が触られない）・`test "handleLogLoaded: clears log_load_error"`（M-N8）・`test "handleLogPageLoaded: rejects stale snapshot_tip"`・`test "buildLoadLogCmd: includes current filter_state"`・`test "handleRequestRefreshLog: clears snapshot_tip + keeps filter"`・`test "handleToggleViewMode: load_log via builder"`（`std.testing.allocator`・Model 構築→`update` 呼出→AppCmd と Model 状態検証）。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新ヘルパ/挙動 未実装）。
- [ ] **Step 3:** `log_paging_tip`/`setLogPagingTip`/`clearLogPagingTip` の全参照を `log_snapshot_tip`/`setLogSnapshotTip`/`clearLogSnapshotTip` へ置換（spec §1.2 移行ステップ）。`handleLogLoaded`（L548）を spec §4.1 ステップ 1-9 へ: stale reject（generation/skip==0）→ replaceLogCommits → **`setLogSnapshotTip(ll.request_tip)`**（OOM は clearLogSnapshotTip で継続）→ **`graph_render_policy==.suppressed` なら graph 計算スキップ**（`log_graph_state` 触らない）→ **`setLogLoadError("")`**（M-N8）→ restore hash/log_has_more/log_page_requested=null/detail_kind=.files → 空 guard → setDetailOwnerHash + load_commit_detail。`handleLogPageLoaded`（L599）を spec §4.2 へ: stale reject で **`request_tip==log_snapshot_tip`** 照合追加 → appendLogCommits → log_has_more → graph policy switch。`buildLoadLogCmd(model) !AppCmd` プライベートヘルパを新設（spec §4.5）: `model.filter_state.clone(a)` → `load_log{skip=0,max_count=100,generation,filter}`。`handleToggleViewMode`（L366）/`handleRequestRefreshLog`（L501）を `buildLoadLogCmd` 経由へ（generation+=1 → clearLogSnapshotTip → buildLoadLogCmd）。`git_error` arm（L253-277）の **log 中 `load_log` 発火分岐を削除**（spec §4.8・M3）。代わりに log 中 `git_error` は `setStr(&error_text, ...)` のみ（`.none`）。bad revision 回復は Task 8 で `LogPageFailed` arm 側へ。
- [ ] **Step 4:** `zig build test --summary all` → まだ FAIL（appcmd が旧シグネチャ・Task 8 で解決・apply_filter arms は Task 7）。ただし model/messages/commands/update のコンパイルエラーは解消し、update の新テストは一部 PASS。
- [ ] **Step 5:** Commit: `git add src/update.zig && git commit -m "refactor(update): replace log_paging_tip with log_snapshot_tip, add buildLoadLogCmd (B1/B2/M-N8)"`

---

## Task 7: update.zig 後半（apply_filter/clear_filter/open/close_filter_modal/handleLogLoadFailed/Silent + detail git_error stale reject）

**Spec:** §4.3, §4.4, §4.6, §4.7, §4.9  **Files:** Modify `src/update.zig`（dispatch L283-345 へ新 arm 追加・handleCommitDetailLoaded/handleDetailDiffLoaded L672-689）

- [ ] **Step 1:** 失敗テストを書く。`test "apply_filter: payload-first transactional success"`（payload "foo" → filter_state.author=="foo"・generation+1・log_snapshot_tip cleared・graph_render_policy==.suppressed・load_log 発火・filter 一致）・`test "apply_filter: OOM on clone clears filter_state"`（FailingAllocator で clone 失敗→`clearFilterState`・Model は空 filter へ・`log_load_error` 通知）・`test "apply_filter: AuthorTooLong sets log_load_error"`（257 Unicode scalar → Model 不変・error 表示）・`test "clear_filter: resets to auto + isEmpty filter + load_log"`・`test "open_filter_modal/close_filter_modal: toggle flag"`・`test "handleLogLoadFailed: stale reject by generation"`・`test "handleLogLoadFailed: sets log_load_error + clears snapshot_tip when no tip"`・`test "detail git_error: stale owner hash rejected"`（M-N9）。`std.testing.allocator`。`checkAllAllocationFailures` は `apply_filter` の OOM 伝播経路（FilterSpec 構築・clone）のみへ使用。OOM 回復（clearFilterState）は `FailingAllocator` の特定 fail index で検証（m-N3）。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新 arm 未実装）。
- [ ] **Step 3:** dispatch（L283-345）へ新 arm 追加: `.apply_filter => |text| return try handleApplyFilter(model, text)`/`.clear_filter => return try handleClearFilter(model)`/`.open_filter_modal => { model.filter_modal_open = true; return .none; }`/`.close_filter_modal => { model.filter_modal_open = false; return .none; }`/`.log_load_failed => |llf| return try handleLogLoadFailed(model, llf)`/`.log_load_failed_silent => |llfs| return try handleLogLoadFailedSilent(model, llfs.request_generation)`。各 handler を spec §4.3/§4.4/§4.6 のステップ通りに実装。**`handleApplyFilter`（spec §4.4）**: payload から FilterSpec 構築（`setAuthor`・AuthorTooLong は log_load_error へ）→ `model.setFilterState(new_spec)`（swap）→ `model.filter_state.clone(a)` で cmd_spec 確保（OOM なら `clearFilterState` で強例外保証）→ commit phase（filter_modal_open=false・generation+=1・log_page_requested=null・log_has_more=false・clearLogSnapshotTip・graph_render_policy=.suppressed・invalidateLogGraph・clearDetailOwner/replaceDetailFiles(&.{})/detail_diff=""・log_load_error=""・replaceLogCommits(&.{})）→ `load_log{filter=cmd_spec}`。`handleLogLoadFailed`（spec §4.3）: stale reject（generation）→ setLogLoadError(error_text) → log_page_requested=null → replaceLogCommits(&.{})/clearDetailOwner 等 → snapshot_tip は request_tip があれば保存・無ければ clear → `.none`。`handleLogLoadFailedSilent`: generation 照合のみ。`handleClearFilter`（spec §4.6）: clearFilterState・generation+=1・clearLogSnapshotTip・graph_render_policy=.auto・invalidateLogGraph・replaceLogCommits(&.{})・`buildLoadLogCmd`。detail git_error（spec §4.8・M-N9）: `git_error` arm で log 中は無条件 `.none`（busy を触らない）・detail 系の失敗は `detail_owner_hash` 照合で弾く（実装で `git_error` に owner 情報を持たせるか、log 中無視で安全側へ倒す）。
- [ ] **Step 4:** `zig build test --summary all` → appcmd（Task 8）が未対応なら一部 FAIL。update.zig のテストは、appcmd の LogLoaded/Failed を手構築して流すので PASS 可能。
- [ ] **Step 5:** Commit: `git add src/update.zig && git commit -m "feat(update): add apply_filter/clear_filter/filter_modal/log_load_failed arms (M4/M-N7/B4/M-N9)"`

---

## Task 8: appcmd.zig（runLogInt/runLogPageInt 拡張 + StreamTooLong）

**Spec:** §6  **Files:** Modify `src/appcmd.zig`（load_log L107-108・runLogInt L155-196・mkPageFailed* L199-219・runLogPageInt L221-260・freeLogArgv/freeLogPageArgv L262-284）

- [ ] **Step 1:** 失敗テストを書く。`TmpRepo`（既存 L298-322）で複数作者のコミットを作り: `test "runLogInt: filter by author returns matching only"`・`test "runLogInt: sets request_tip from rev-parse HEAD"`・`test "runLogInt: is_unborn true for empty repo"`・`test "runLogInt: bad regex impossible with --fixed-strings"`（literal で `[` もそのまま一致 or 空結果）・`test "runLogInt: StreamTooLong → LogLoadFailed"`・`test "runLogPageInt: uses snapshot_tip + filter"`・`test "runLogPageInt: bad revision (exit 128) → LogPageFailed"`（M3）。`std.testing.allocator`。subprocess を含むため `checkAllAllocationFailures` は**使わない**（m-N3・非決定性）。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新挙動 未実装）。
- [ ] **Step 3:** `runLogInt`（L155）を spec §6.1 へ拡張: `headState` tri-state（既存 L193-218 再利用）で unborn 判定 → unborn は `LogLoaded{request_tip="", is_unborn=true, entries=&.{}}` → `.ok` なら `revParseHead(a, io, cwd)` で snapshot_tip 取得（OOM/失敗は `LogLoadFailed` or `LogLoadFailedSilent`）→ `logArgv(a, 0, 100, snapshot_tip, filter)` → `process.run`（`error.StreamTooLong` を catch して `LogLoadFailed` へ正規化・MINOR7）→ `log.parse`（失敗は `LogLoadFailed`）→ `LogLoaded{request_tip=snapshot_tip, is_unborn=false, entries, generation, request_skip=0, request_max_count=100}`。`runLogPageInt`（L221）を spec §6.2 へ: `logPageArgv(a, skip, 100, tip_hash, filter)` → `process.run`（StreamTooLong → LogPageFailed）→ exit==128 は bad revision → `LogPageFailed{error_text="tip が期限切れです"}`（M3・`git_error` ではなく LogPageFailed へ）→ parse → `LogPageLoaded{request_tip=dupe(tip_hash), entries, ...}`。`mkPageFailed*`（L199-219）と同等の `mkLoadFailed`/`mkLoadFailedSilent` ヘルパを新設（OOM 極限は Silent）。`freeLogArgv`/`freeLogPageArgv`（L262-284）呼出を `OwnedArgv.deinit` へ全置換（旧関数削除）。
- [ ] **Step 4:** `zig build test --summary all` → PASS（純粋層すべて完了・全体ビルドとテストが通る最初のマイルストーン）。
- [ ] **Step 5:** Commit: `git add src/appcmd.zig && git commit -m "feat(appcmd): runLogInt with rev-parse HEAD + filter, typed failures (B1/B4/M3/MINOR7)"`

> **マイルストーン:** ここで純粋層（filter/model/messages/commands/update/appcmd）が完結。`zig build test --summary all` が全通過する。以降 Task 9-11 は UI 配線（refAllDecls + 手動 pty 検証）。

---

## Task 9: input.zig（f/F キー + modal 優先 + mouse 抑止）

**Spec:** §7  **Files:** Modify `src/input.zig`（keyToMsgForMode L158-163・keyToMsgForLog L173-235・fromZigzagMouseForMode L297-313）

- [ ] **Step 1:** 失敗テストを書く。`test "keyToMsgForLog: f → open_filter_modal"`・`test "keyToMsgForLog: F → clear_filter"`・`test "modal open: Enter → apply_filter (payload via main)"`（input は `apply_filter` を返さず、main が TextInput.getValue を dupe して送る設計・input は Enter を `null` で返し main へ委譲するか、専用 Msg で「submit」を示す。spec §7.1 の採用案を具体化）・`test "modal open: Esc → close_filter_modal"`・`test "modal open: q/r/L/tab suppressed"`（M6）・`test "mouse: modal open suppresses pane routing"`（spec §7.2）。`std.testing.allocator`。input 関数は純粋なので直接テスト可。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新挙動 未実装）。
- [ ] **Step 3:** `keyToMsgForLog`（L173）へ `'f' => .open_filter_modal`（log モード・focus==.changes）と `'F' => .clear_filter` を追加。**modal visible の前判定**（spec §7.1・M6）: `keyToMsgForMode`（L158）の前に modal 判定を置く（`keyToMsgForModeWithModal(view_mode, focus, detail_kind, filter_modal_open, key)` を新設・または main 側で `filter_modal_open` 時に先に分岐）。modal 中は `enter`/`escape` 以外を `null` へ（main が TextInput.handleKey へ委譲）・`escape` → `.close_filter_modal`・`enter` は `null`（main が apply_filter 構築）・`q`/`r`/`L`/`tab` 等 global mapping も抑制。`fromZigzagMouseForMode`（L297）/`handleMouse` で modal visible 時は背面 pane routing をスキップ（モーダル外クリックは無視・spec §19 デフォルト）。
- [ ] **Step 4:** `zig build test --summary all` → PASS（input は純粋）。
- [ ] **Step 5:** Commit: `git add src/input.zig && git commit -m "feat(input): add f/F keys, modal-priority key routing, mouse suppression (M6)"`

---

## Task 10: view.zig（renderLogMode modal 分岐 + graph 非表示理由 + log_load_error + unborn）

**Spec:** §8  **Files:** Modify `src/view.zig`（renderStatus L343-363・renderLog L434-506・render/renderLogMode L644-682）

- [ ] **Step 1:** view 関数は zigzag 依存で `refAllDecls` のみ。代わりに純粋部分（`computeLogLayout` 等）があればテスト追加。主目視検証は Task 13 の pty。
- [ ] **Step 2:** `zig build` でコンパイル確認。
- [ ] **Step 3:** `renderLogMode`（L671）で `model.filter_modal_open` 時は **base view を返さず `modal.viewWithBackdrop(ctx.allocator, term_w, term_h)` を返す**（spec §8.1/MINOR5/m-N5・全面置換・背景見えない）。modal の body は `filter_textinput.view(ctx.allocator)` の結果を事前に `modal.body` へ設定（main 側で同期・Task 11）。`renderLog`（L434）の `show_graph` 判定（L447）へ `and model.graph_render_policy == .auto` を追加（spec §1.3/B2）。`graph_render_policy==.suppressed` で graph 列を表示せず、代わりにメタ行 or status bar へ `Filter: author="<raw>" (graph hidden)` を表示（spec §8.2）。`log_load_error` が非空なら log ペインへ `(error) <text>` を表示（spec §8.3）。空結果は `is_unborn` で `(no commits)` / filter 適用中は `(no matching commits)` を切り分け（m-N1）。`filter_textinput` の `setPlaceholder("Filter by author…")`/`setPrompt("author: ")` を main の init で（Task 11）。
- [ ] **Step 4:** `zig build` → PASS（コンパイル）。`zig build test --summary all` → PASS。
- [ ] **Step 5:** Commit: `git add src/view.zig && git commit -m "feat(view): modal overlay via viewWithBackdrop, graph-hidden reason, error/unborn display (B2/MINOR1/MINOR5/m-N1)"`

---

## Task 11: main.zig（App へ TextInput/Modal + handleKey routing + setValue 同期）

**Spec:** §9  **Files:** Modify `src/main.zig`（App L95-109・dispatchSideEffect L153-175・reapWorker L216-235・RuntimeModel.init L258-266・deinit L292-308・drainQueue/textarea.setValue L324・handleKey L339-355・handleMouse L358-409）

- [ ] **Step 1:** `zig build` でコンパイル確認（UI 結合・refAllDecls）。手動検証は Task 13。
- [ ] **Step 2:** `App` 構造体（L95）へ `filter_textinput: zz.TextInput` と `filter_modal: zz.Modal` を追加。`init`（L95 付近）で `zz.TextInput.init(ctx.persistent_allocator)`（`setCharLimit(256)`・`setPlaceholder`/`setPrompt`）と `zz.Modal.init()`（`title="Filter by author"`・button 無し）。`deinit`（L292）で `filter_textinput.deinit()`/`filter_modal.deinit()`（Modal に deinit がなければ noop・実 API 確認）。`handleKey`（L339）で **`model.filter_modal_open` 時のキー routing**（spec §9.2/M6/M-N7）: `escape` → `Msg.close_filter_modal`・`enter` → `const v = app.filter_textinput.getValue(); const dup = try a.dupe(u8, v); return step(.{ .apply_filter = dup });`（payload・Msg consumer が free）・それ以外は `app.filter_textinput.handleKey(k)` へ委譲（TextArea 横取り L352-355 と同パターン）して `return`（Msg 送らない）。`drainQueue`（L324 付近）で `model.filter_modal_open` の遷移を検知し、`true` になったら `app.filter_textinput.setValue(model.filter_state.author orelse "")` + `app.filter_modal.show()`（spec §9.3・編集継続）、`false` になったら `app.filter_modal.hide()`（show/hide と model.filter_modal_open 同期）。毎フレーム `app.filter_modal.body = app.filter_textinput.view(ctx.allocator)`（Modal の body へ TextInput 描画を反映・Task 10 の viewWithBackdrop が body を描画）。
- [ ] **Step 3:** `zig build` → PASS。`zig build test --summary all` → PASS。
- [ ] **Step 4:** Commit: `git add src/main.zig && git commit -m "feat(main): wire TextInput/Modal, apply_filter payload, show/hide sync (M6/M7/M-N7)"`

---

## Task 12: TODO.md 更新（phase3a 部分チェック）

**Spec:** §Goal  **Files:** Modify `TODO.md`（phase 3 Sub Tasks L178-180）

- [ ] **Step 1:** `TODO.md` の phase 3「phase 3（フィルタ機能）— 未実装」（L178）を「phase 3a（フィルタ UI + 作者）— 完了 (2026-06-20)」へ変更。「フィルタ UI（`f` キーでモーダル展開・JetBrains 風）」と「ブランチ / 作者 / 日付 / パス での絞り込み」のうち**作者**を `[x]` へ。phase3b 残（日付/パス/ブランチ・graph 維持・複数 branch）を明記し、spec/plan へのリンクを張る。
- [ ] **Step 2:** Commit: `git add TODO.md && git commit -m "docs: mark phase3a (author filter) complete, phase3b remaining"`

---

## Task 13: 全体ビルド + テスト + tmux pty 手動検証

**Spec:** §12 完了条件  **Files:** なし（検証のみ）

- [ ] **Step 1:** `zig build test --summary all` → 全 PASS（リーク無し・`std.testing.allocator`）。
- [ ] **Step 2:** `zig build` → バイナリ生成成功。
- [ ] **Step 3:** tmux pty で手動検証（AGENTS.md・`tmux new-session -x W -y H` → `send-keys` → `capture-pane -p`）:
  - git リポジトリ内で `zig-out/bin/git-tui` 起動 → `L` で log モード → `f` でモーダル open（base 見えない・viewWithBackdrop）→ 作者名入力 → `Enter` → フィルタ適用（線形一覧・graph 非表示・`Filter: author="..." (graph hidden)` 表示）→ `j/k` で選択 → `F` or モーダル再 open → `Ctrl+U` + `Enter` or `F` で解除 → graph 復帰。
  - 境界: 空一致（`(no matching commits)`）・unborn（`(no commits)`・別 repo）・無効文字 `[`（literal でそのまま or 空結果・エラー出ない）・UTF-8 作者・bad revision（外部で branch 削除→`r` で回復・filter 保持）・16MiB 超過（巨大履歴 repo・StreamTooLong → LogLoadFailed 表示）。
- [ ] **Step 4:** 検証メモをコミット（必要なら `docs/` へ QA 記録 or commit message へ）。Commit: `git commit --allow-empty -m "test(phase3a): verify filter UI via tmux pty (graph hidden, unborn, UTF-8, bad-rev)"`（または発見したバグを fix commit）。

---

## codex レビュー反映の実装時注意（plan rev.2・codex 指摘の運用カバー）

codex が plan へ指摘した点を、実装（subagent-driven-development）で各 Task に反映すること。設計（spec）の欠陥ではなくタスク編成・明記不足の指摘。

1. **各 commit は green（ビルド+テスト通過）を目指す**: Task 3（model の `log_paging_tip` 廃止）と Task 6（update の同参照置換）は密結合・中間ビルド不通になるため、**同一 commit シーケンスへ統合**して進める（Task 3→Task 6 を連続実施し、Task 6 の終了で green）。Task 4（messages）→Task 5（commands）→Task 8（appcmd）も同様で、Task 8 の終了で純粋層が全体 green（最初のマイルストーン）。subagent-driven-development の review checkpoint は、これら「green になる境界」（Task 2 後・Task 6 後・Task 8 後・Task 11 後）で置く。
2. **`handleLogCursorDown`（load_log_page 送信側）の filter clone を忘れず追加**（Task 6）: spec §4.5 の `buildLoadLogCmd` は `load_log`（初回/refresh）用。`load_log_page`（paging）は `handleLogCursorDown`（`src/update.zig:408-423`）内で `model.filter_state.clone(a)` して `LoadLogPage{tip_hash=model.log_snapshot_tip の dupe, filter=<clone>, ...}` を構築する。`tip_hash` は `model.log_snapshot_tip orelse model.log_commits.items[0].hash`（初回未確定時のフォールバック・spec §1.4）。
3. **bad revision reducer**（Task 6/7/8 連携）: Task 8 の `runLogPageInt` が exit==128 を `LogPageFailed{error_text="tip が期限切れです"}` へ（M3）。Task 6 の `handleLogPageFailed`（`src/update.zig:643-668`）で generation 照合 + `clearLogSnapshotTip`（次回 LoadLog で再解決・filter 保持）+ `log_load_error` 通知（spec §6.2/§4.2/§11）。
4. **typed detail failures**（Task 7 で方針確定）: `Msg.git_error` に owner 情報を持たせて stale reject するか、**log 中の `git_error` を無条件 `.none`（busy を触らない）で安全側へ倒す**かを実装時に一つに決める（spec §4.8/M-N9）。推奨は後者（最小対処・busy 完全修正は将来）。detail 系成功結果は既存 `detail_owner_hash` 照合で弾かれる。
5. **StreamTooLong のテスト可能 seam**（Task 8）: `src/git/process.zig` の `std.process.run` の `stdout_limit`（16MiB・`std.Io.Limit.limited`）を、テスト時に小さく注入できるよう関数引数 or config へ切り出す（spec §6.3/MINOR7）。これで 16MiB 超過の `LogLoadFailed`/`LogPageFailed` 正規化を重い実 repo なしで検証。
6. **worker 競合 harness の決定論化**（Task 6 または専用ステップ）: `src/main.zig` の `dispatchSideEffect`/`reapWorker`（L153-175, L216-235）の state machine（busy/pending/latest-wins）を pure helper へ抽出し、実 thread + 33ms tick に依存しない単体テストへ（spec §14.2/m-N4）。page in-flight 中の filter 変更・detail in-flight 中の filter 変更・連続 apply・filter 解除で、旧成功/旧失敗結果が新状態を変えないことを検証。
7. **spec §14.3 テスト境界を各 Task へ配分**: 分岐履歴での作者 paging・100/101 件（EOF 判定）・空一致・unborn・detached HEAD・filter 変更中の旧 page 成功/失敗破棄・OOM clone・UTF-8 作者・modal global-key/mouse 抑止・regex 不可（--fixed-strings で `[` も literal）・branch 削除（bad revision）を、該当 Task（Task 2/7/8/9）のテストへ明示的に追加。
8. **コメント規約**: CLAUDE.md/AGENTS.md に「コードコメント禁止」の規約は**無い**。所有権・race・stale gate の**非自明な invariant** は既存コードスタイル（`src/update.zig:402-407`, `src/main.zig:153-175` 等）に倣いコメントで残す。自明な逐語コメントは避ける。
9. **コミットメッセージ**: review ID（`(B1/M4/M-N7)` 等）は subject でなく **body へ**移す（履歴読者に意味不明のため）。subject は `feat(filter): add FilterSpec with clone/deinit` 等、module/利用者視点の内容に。
10. **Task 12（TODO.md 更新）は Task 13（pty 検証）後に実施**: 検証で不具合が出た場合に完了記録が先行しないよう順序を入れ替え。

---

## Self-Review Notes

### Spec coverage（spec §1-§20 → Task 対応）
- §1.1 FilterSpec → Task 2 ✓
- §1.2 Model fields・log_paging_tip 廃止 → Task 3 ✓
- §1.3 graph_render_policy → Task 3（field）+ Task 6（reducer skip）+ Task 10（view 参照）✓
- §1.4 log_snapshot_tip race 回避 → Task 3（field）+ Task 5（revParseHead・revision 明示）+ Task 8（runLogInt）✓
- §1.5 zz.TextInput/Modal API → Task 1（api-notes）+ Task 10/11（使用）✓
- §2 作者意味論（--fixed-strings）→ Task 2（max_author_runes）+ Task 5（argv）✓
- §3 Msg/AppCmd → Task 4 ✓
- §4.1/4.2 handleLogLoaded/PageLoaded → Task 6 ✓
- §4.3 LogLoadFailed/Silent → Task 7 ✓
- §4.4 apply_filter payload-first → Task 7 ✓
- §4.5 buildLoadLogCmd → Task 6 ✓
- §4.6 clear_filter → Task 7 ✓
- §4.7 open/close_filter_modal → Task 7 ✓
- §4.8 git_error(log) 廃止 + detail stale reject → Task 6（git_error）+ Task 7（detail owner）✓
- §4.9 stale-reject → Task 6/7 ✓
- §5 commands → Task 5 ✓
- §6 appcmd → Task 8 ✓
- §7 input → Task 9 ✓
- §8 view → Task 10 ✓
- §9 main → Task 11 ✓
- §10 所有権 → 全 Task（規約）✓
- §11 エラー → Task 7/8 ✓
- §12 完了条件 → Task 13 ✓
- §13 TDD breakdown → 全 Task 構成 ✓
- §14 テスト境界 → 各 Task のテスト（checkAllAllocationFailures/FailingAllocator/tmpRepo/pty）✓
- §15 api-notes → Task 1 ✓
- §16 phase3b → Task 12（TODO 明記）✓
- §17 Risks → 各 Task の注意・Task 7 OOM 回復・Task 10 viewWithBackdrop ✓
- §18 将来課題 → Task 12（TODO 明記）✓
- §19 Open decisions → デフォルト採用（Task 2/5/9/10/11 に埋め込み・ユーザー spec レビューで承認済み）✓

### Placeholder scan
"TBD"/"TODO"/"add ..."/"similar to"/"etc" のプレースホルダーは使用していない。各 Task の実装詳細は spec 該当節を正として参照（spec が完全なステップ/構造体定義を持つため）。コードの完全な形は spec を見て展開する（実装者が spec を行き来する手間はあるが、spec rev.3 が詳細なので迷わない）。

### Type consistency
- `log_snapshot_tip` / `setLogSnapshotTip` / `clearLogSnapshotTip`: Task 3/6/8 で統一 ✓
- `graph_render_policy: enum { auto, suppressed }`: Task 3/6/10 で統一 ✓
- `max_author_runes`: Task 2/11 で統一 ✓
- `FilterSpec` / `filter_state`: Task 2/3/4/6/7 で統一 ✓
- `Msg.apply_filter: []u8`: Task 4/9/11 で統一 ✓
- `LogLoadFailed` / `LogLoadFailedSilent`: Task 4/7/8 で統一 ✓
- `OwnedArgv`: Task 5/8 で統一 ✓
- `buildLoadLogCmd`: Task 6/7 で統一 ✓
