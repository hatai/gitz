# TODO 2 phase3b コミットログフィルタ（日付範囲 + パス）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `f` モーダルを4入力欄（Author/Since/Until/Path）へ拡張し、日付範囲（`--since`/`--until`・ローカル TZ）とパス（`-- <path>`・複数可）でコミットログを絞り込む。`FilterSpec` を `FilterCondition` union リストへ再構築し、author/since/until/paths を統一表現へ。

**Architecture:** Elm 風・副作用隔離（`CLAUDE.md`）。純粋層（`filter.zig` 拡張 / model / messages / update / git/commands）を TDD → UI 層（input / view / main）を配線。日付はローカル TZ・`YYYY-MM-DD` と `YYYY-MM-DD HH:MM`・until 日付のみは +1day で当日包含。パスは git デフォルト pathspec・複数可（空白区切り）。graph は phase 3a 同様 filter 有効時 `graph_render_policy=.suppressed`。

**Tech Stack:** Zig 0.16.0, zigzag v0.1.5（固定）, `std.ArrayList` unmanaged, `std.testing.allocator`, `checkAllAllocationFailures`, `std.unicode.utf8CountCodepoints`, `std.time`（Month 定数）。

**Spec:** `docs/superpowers/specs/2026-06-22-todo2-log-view-phase3b-date-path-filter-design.md`（rev.2・codex レビュー全面反映）。各 Task の実装詳細（構造体 field・reducer ステップ・argv 形・テスト計画）は **spec の該当節** を正として参照すること。本 plan は「何を・どこで・どうテストするか」を示し、コードの完全な形は spec を見て展開する。

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
| `src/filter.zig` | Modify（破壊的） | `FilterCondition` union（author/since/until/paths）+ `FilterSpec.conditions: ArrayList`・accessor 群・date/path helpers・純粋・zigzag 非依存 |
| `src/root_test.zig` | 変更無し | `filter.zig` は phase 3a で `@import` 済み |
| `src/model.zig` | Modify | Model へ `filter_modal_focus: u2` 追加・init/deinit |
| `src/messages.zig` | Modify（破壊的） | `Msg.apply_filter: []u8` → `ApplyFilter` 構造体・`filter_focus_next`/`filter_focus_prev` 新タグ・`ApplyFilter.deinit` メソッド・Msg.deinit 網羅更新 |
| `src/git/commands.zig` | Modify | `appendFilterOptions`（revision 前）+ `appendPaths`（revision 後）分割・`logArgv`/`logPageArgv` 内部更新 |
| `src/update.zig` | Modify（破壊的） | `handleApplyFilter` 再構築（ApplyFilter payload-first）・`handleFilterFocusNext`/`Prev`・`handleOpenFilterModal` focus リセット・既存 `setAuthor` 呼び出し全置換 |
| `src/appcmd.zig` | Modify（テストのみ） | `runLogInt`/`runLogPageInt` 実装は FilterSpec 構造変更を自動追従（変更不要）・**テスト（L1079/1102/1124/1142 の `spec.setAuthor`）を `addCondition(.{ .author = ... })` へ書換え**・since/until/paths 系 runLogInt 新テスト追加 |
| `src/input.zig` | Modify | `input.Key` へ `shift_tab` variant・`fromZigzagKey` 修飾キー判定・`keyToMsgForModeWithModal` へ tab/shift_tab |
| `src/view.zig` | Modify | モーダル body 4行構築・フォーカス中欄 `view()` / 他 `getValue()`・graph 非表示理由の conditions 反映 |
| `src/main.zig` | Modify（破壊的） | `App.filter_textinput` → 4つ（author/since/until/path）・`syncFilterModal`/`handleModalKey` 拡張・Enter で ApplyFilter 構築 |
| `TODO.md` | Modify | phase3b「日付範囲」「パス」を部分チェック・残明記 |
| `README.md` | Modify | フィルタ機能のキーマップ + TZ 注意書き |

> **★破壊的変更の波及**: `FilterSpec.author: ?[]u8` → `conditions: ArrayList` が `filter.zig`/`model.zig`/`messages.zig`/`update.zig`/`git/commands.zig`/`appcmd.zig`（テスト）/`view.zig`/`main.zig` へ波及。`root_test.zig` は filter/model/messages/update/commands/appcmd/input/view を import するため、これらの `.author`/`setAuthor` 参照が Task 1 で壊れる。**最初の green マイルストーンは Task 9（view.zig の `.author` 参照 + appcmd テスト修復後）**。phase 3a plan が Task 8 を「最初の green」と定義したのと同様に、本 plan は Task 1-9 を連続して実施し Task 9 の終わりで `zig build test` が通る。main.zig は Task 10 まで旧 API（root_test 非対象なので `zig build test` には影響しないが `zig build` 実行可能ビルドは Task 10 まで不可）。各 Task の commit は中間状態（テストビルド不可）を許容するが、Task 9 で整合してから push する。

**commit メッセージ規約**: review ID（spec 節/codex ID）は commit subject の末尾へ括弧付きで置く（例: `(D7/M3/m1)`）。phase 3a plan の実慣例（Task 2 Step 6 等）と整合。

---

## Task 1: filter.zig 再構築（FilterCondition union + FilterSpec.conditions + accessor 群）

**Spec:** §1.1  **Files:** Modify `src/filter.zig`（L1-136 全体を再構築）

> ★この Task で `FilterSpec.author: ?[]u8` を `conditions: ArrayList(FilterCondition)` へ変更するため、`model.zig`/`messages.zig`/`update.zig`/`git/commands.zig` が `setAuthor`/`.author` を参照してコンパイルエラーになる（Task 4/6/7 で解決）。Task 1 単独では `zig build test` 不可。filter.zig 単体のテストは Task 7 で全体が通るまで保留。

- [ ] **Step 1:** `src/filter.zig` の既存テスト（L62-132）を新 API へ書き換えた失敗テストへ置換:
  - `test "FilterSpec: isEmpty/addCondition/removeVariant/clone/eql/deinit"`（`init`→`isEmpty==true`→`addCondition(.{ .author = try a.dupe(u8, "foo") })`→`isEmpty==false`→`getAuthor()` で `"foo"`→`clone` で `eql==true` かつ ptr 不同→`removeVariant(.author)` で `isEmpty==true`→`deinit` でリーク無し）
  - `test "FilterSpec: addCondition OOM leaves list unchanged and frees payload"`（`checkAllAllocationFailures` で append realloc 失敗時・conditions 不変・渡した payload が leak しない・codex M3）
  - `test "FilterSpec: duplicate variant overwrites (codex m1)"`（author addCondition 後に別 author addCondition → 後勝ち・len 増えず・旧 free）
  - `test "FilterSpec: accessor 群 (getAuthor/getSince/getUntil/getPaths) borrow"`（各 variant addCondition 後に accessor が借用 slice を返す・paths は空 slice デフォルト・codex m3）
  - `test "FilterSpec: max_author_runes constant preserved"`（`max_author_runes == 256`・reducer が参照）
  - `test "FilterSpec: UTF-8 author preserved through clone"`（日本語 author）
  - `test "FilterSpec: multi-variant (author+since+paths) clone/deinit no leak"`（複数 condition の deep-copy/eql）
  - `test { std.testing.refAllDecls(@This()); }`（既存維持）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`addCondition`/`getAuthor` 等未定義・他ファイルのコンパイルエラー）。filter.zig 単体のテスト実行は不可（全体ビルド依存）。
- [ ] **Step 3:** `src/filter.zig` を再構築（spec §1.1）。実装内容:
  - `FilterCondition = union(enum) { author: []u8, since: []u8, until: []u8, paths: [][]u8 }`。variant tag enum を暗黙。
  - `FilterSpec = struct { conditions: std.ArrayList(FilterCondition) }`（unmanaged）。
  - 定数 `max_author_runes: usize = 256`（phase 3a 継承・reducer が参照）・`max_date_runes: usize = 16`・`max_path_runes: usize = 1024`・`max_path_count: usize = 16`（spec §1.1）。
  - `pub fn init() FilterSpec`（`.conditions = .empty`）。
  - `pub fn isEmpty(self: FilterSpec) bool`（`conditions.items.len == 0`）。
  - `pub fn addCondition(self: *FilterSpec, a: std.mem.Allocator, cond: FilterCondition) std.mem.Allocator.Error!void`: 同 variant があれば**上書き**（旧を `deinitCondition(a, old)` して置換・`conditions.items[i] = cond; return`）・無ければ `conditions.append(a, cond) catch { deinitCondition(a, cond); return error.OutOfMemory; }`（★OOM 時 payload 自動 deinit・codex M3）。
  - `pub fn removeVariant(self: *FilterSpec, a: std.mem.Allocator, tag: std.meta.Tag(FilterCondition)) void`: 該当 condition を `deinitCondition` して `orderedRemove`（または swapRemove + 後でソート）・未存在は no-op。
  - `pub fn getAuthor(self: FilterSpec) ?[]const u8` / `getSince` / `getUntil`（各 variant lookup・借用 `[]const u8`・無しは null）。
  - `pub fn getPaths(self: FilterSpec) []const []const u8`（`.paths` lookup・借用・無しは空 slice `&.{}`）。
  - `pub fn clone(self: FilterSpec, a: std.mem.Allocator) std.mem.Allocator.Error!FilterSpec`: 各 condition を `cloneCondition(a, cond)` で deep-copy（`errdefer` で順次 rollback・paths は外側 + 各要素）。
  - `pub fn eql(self: FilterSpec, other: FilterSpec) bool`: 順序込みで各 condition を比較（デバッグ/テスト用）。
  - `pub fn deinit(self: *FilterSpec, a: std.mem.Allocator) void`: 各 condition を `deinitCondition(a, cond)` して `conditions.deinit(a)`。
  - プライベート `fn deinitCondition(a, cond)`（switch で各 variant payload を free・paths は外側 + 各要素）/ `fn cloneCondition(a, cond) !FilterCondition`（各 variant を dup・errdefer）。
  - `//!` doc comment を「phase 3b: FilterCondition union リスト（author/since/until/paths）」へ更新。**コード内コメント禁止**。
- [ ] **Step 4:** `zig build test --summary all` → まだ FAIL（model/messages/update/commands が `setAuthor`/`.author` 参照でコンパイルエラー・Task 4/6/7 で解決）。
- [ ] **Step 5:** Commit: `git add src/filter.zig && git commit -m "refactor(filter): FilterSpec to FilterCondition union list with accessors (D7/M3/m1/m3)"`

---

## Task 2: filter.zig へ date helpers 追加（parseDate/formatGitDate/daysInMonth/addOneDay/DateSpec）

**Spec:** §1.2, §2.1, §2.2  **Files:** Modify `src/filter.zig`（追記）

> 純粋ヘルパ・filter.zig 単体でテスト可能だが、filter.zig 全体のビルドは Task 1 の破壊的変更により Task 7 まで不可。テストは Task 7 で実行。

- [ ] **Step 1:** `src/filter.zig` へ date helper の失敗テストを追加:
  - `test "parseDate: YYYY-MM-DD (date only)"`（`"2026-06-22"` → `DateSpec{ year=2026, month=6, day=22, hour=null, minute=null }`）
  - `test "parseDate: YYYY-MM-DD HH:MM"`（`"2026-06-22 09:30"` → hour=9, minute=30）
  - `test "parseDate: invalid formats"`（`"2026-13-01"`→`InvalidDateFormat`・`"2026-02-30"`→err・`"2025-02-29"` 平年→err・`"2024-02-29"` うるう年→OK・`"2026/06/22"`→err・`"2026-6-1"` ゼロ埋め無し→err・空文字→err・`"2026-06-22 09"` HH のみ→err）
  - `test "daysInMonth: leap year boundaries"`（`daysInMonth(2024, 2)==29`・`daysInMonth(2026, 2)==28`・`daysInMonth(2026, 1)==31`・`daysInMonth(2026, 4)==30`）
  - `test "addOneDay: month/year boundaries"`（1/31→2/1・2/28→3/1 平年・2024-02-28→02-29 うるう年・12/31→1/1 年跨ぎ・`DateSpec` の hour/minute は保持）
  - `test "formatGitDate: since date-only 00:00:00"`（`try formatGitDate(a, ds_date_only, false)` → `"2026-06-22 00:00:00"`・★3引数で `a` 必須・codex M3）
  - `test "formatGitDate: since HH:MM"`（`try formatGitDate(a, ds_hhmm, false)` → `"2026-06-22 09:30:00"`)
  - `test "formatGitDate: until date-only +1day"`（`try formatGitDate(a, ds_date_only, true)` → `"2026-06-23 00:00:00"`・codex +1day）
  - `test "formatGitDate: until HH:MM unchanged"`（`try formatGitDate(a, ds_hhmm, false)` → `"2026-06-22 09:30:00"`・排他・git 標準）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`parseDate`/`formatGitDate` 等未定義）。
- [ ] **Step 3:** `src/filter.zig` へ date helper を実装（spec §1.2, §2.2）:
  - `pub const DateSpec = struct { year: u16, month: u4, day: u5, hour: ?u5, minute: ?u6 }`。
  - `pub const DateError = error{ InvalidDateFormat, OutOfMemory }`（`parseDate` 用）。
  - `pub fn parseDate(input: []const u8) DateError!DateSpec`: 長さ 10（YYYY-MM-DD）or 16（YYYY-MM-DD HH:MM）で分岐・各フィールド parse・`std.fmt.parseInt` で範囲外は err・`daysInMonth` で日数検証（spec §1.2）。
  - `pub fn daysInMonth(year: u16, month: u4) u5`: うるう年判定（`year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)`）で 2 月 28/29・他月は固定テーブル（spec §1.2）。
  - `pub fn addOneDay(ds: DateSpec) DateSpec`: `day+1 > daysInMonth` なら月繰り上がり・12 月→年繰り上がり（spec §1.2）。
  - `pub fn formatGitDate(a: std.mem.Allocator, ds: DateSpec, is_until_date_only: bool) std.mem.Allocator.Error![]u8`: `is_until_date_only` なら `addOneDay(ds)` して `YYYY-MM-DD 00:00:00`・HH:MM 指定なら `YYYY-MM-DD HH:MM:00`（spec §2.2）・`std.fmt.allocPrint`。
- [ ] **Step 4:** `zig build test --summary all` → まだ FAIL（Task 1 の破壊的変更による他ファイルエラー）。filter.zig の date helper は Task 7 で検証。
- [ ] **Step 5:** Commit: `git add src/filter.zig && git commit -m "feat(filter): add date helpers parseDate/formatGitDate/addOneDay (§1.2/§2.2)"`

---

## Task 3: filter.zig へ path helpers 追加（parsePaths/paths_to_string）

**Spec:** §1.2, §2.3  **Files:** Modify `src/filter.zig`（追記）

- [ ] **Step 1:** `src/filter.zig` へ path helper の失敗テストを追加:
  - `test "parsePaths: single path"`（`"src/"` → `["src/"]`）
  - `test "parsePaths: multiple paths"`（`"src/ test/"` → `["src/", "test/"]`）
  - `test "parsePaths: quoted path with space"`（`"\"my dir/file\""` → `["my dir/file"]`）
  - `test "parsePaths: escape backslash-space"`（`"src/\\ *.zig"` → `["src/ *.zig"]`）
  - `test "parsePaths: consecutive whitespace skipped"`（`"a   b"` → `["a", "b"]`）
  - `test "parsePaths: empty input"`（`""` → 空 slice）
  - `test "parsePaths: too many paths"`（17 個 → `error.TooManyPaths`）
  - `test "parsePaths: path too long"`（4097 バイト要素 → `error.PathTooLong`）
  - `test "parsePaths: unterminated quote"`（`"\"my dir"` → `error.UnterminatedQuote`・codex m5）
  - `test "paths_to_string: single"`（`["src/"]` → `"src/"`）
  - `test "paths_to_string: multiple"`（`["src/", "test/"]` → `"src/ test/"`）
  - `test "paths_to_string: quotes path with space"`（`["my dir/file"]` → `"\"my dir/file\""`)
  - `test "paths_to_string: escapes quote/backslash"`（`["a\"b"]` → `"\"a\\\"b\""`)
  - `test "paths_to_string: empty list"`（`&.{}` → `""`）
  - `test "paths_to_string ∘ parsePaths roundtrip symmetric"`（`"src/ \"my dir/file\" a\\\"b"` を parsePaths → paths_to_string → 同じ正規化文字列・codex M4）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`parsePaths`/`paths_to_string` 未定義）。
- [ ] **Step 3:** `src/filter.zig` へ path helper を実装（spec §1.2, §2.3）:
  - `pub const PathError = error{ TooManyPaths, PathTooLong, UnterminatedQuote, OutOfMemory }`。
  - `pub fn parsePaths(a: std.mem.Allocator, input: []const u8) PathError![][]u8`: ステートマシン（通常/quote/escape）でトークン分割・空白区切り・`"` で quote・`\` で次文字エスケープ・未閉じ quote は `UnterminatedQuote`・空トークン skip・要素数 > `max_path_count` で `TooManyPaths`・各要素 > 4096 byte で `PathTooLong`・`std.ArrayList([]u8)` で蓄積して `toOwnedSlice`（spec §1.2）。
  - `pub fn paths_to_string(a: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error![]u8`: 各パスが空白/`"`/`\` を含むなら `"` で囲んで内部エスケープ（`"`→`\"`・`\`→`\\`）・空白区切り join（spec §1.2・parsePaths の逆変換）。
- [ ] **Step 4:** `zig build test --summary all` → まだ FAIL（Task 1 の破壊的変更）。filter.zig の path helper は Task 7 で検証。
- [ ] **Step 5:** Commit: `git add src/filter.zig && git commit -m "feat(filter): add path helpers parsePaths/paths_to_string with roundtrip (M4/m5)"`

---

## Task 4: messages.zig（ApplyFilter 構造体化 + filter_focus_next/prev + ApplyFilter.deinit）

**Spec:** §3.1, §3.2  **Files:** Modify `src/messages.zig`（Msg union L60-65・deinit L150・ApplyFilter 新構造体）

- [ ] **Step 1:** `src/messages.zig` へ失敗テストを追加:
  - `test "Msg.apply_filter (ApplyFilter) deinit frees all fields"`（author/since/until 非 null + paths 非空で ApplyFilter 構築 → `deinit` で全 free・リーク無し）
  - `test "Msg.apply_filter (ApplyFilter) deinit with nulls and empty paths"`（全 null/空 paths でも安全・空 paths は `alloc([]u8, 0)` を free）
  - `test "Msg.filter_focus_next/prev deinit is no-op"`（payload 無し）
  - `test "ApplyFilter.deinit method callable standalone"`（Msg の外で `ApplyFilter{...}.deinit(a)` が呼べる・main の rollback 用・codex m4）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`ApplyFilter`/`filter_focus_next` 未定義）。
- [ ] **Step 3:** `src/messages.zig` を実装（spec §3.1, §3.2）:
  - `ApplyFilter` 構造体を `Msg` の外（`pub const`）へ定義: `pub const ApplyFilter = struct { author: ?[]u8, since: ?[]u8, until: ?[]u8, paths: [][]u8, pub fn deinit(self: *ApplyFilter, a: std.mem.Allocator) void { ... } }`（deinit は author/since/until 非 null free + paths 各要素 free + paths slice free・codex m4）。
  - Msg union（L60-65）の `apply_filter: []u8` を `apply_filter: ApplyFilter` へ変更。`filter_focus_next`/`filter_focus_prev`（payload 無し）を追加。
  - `Msg.deinit` switch（L150）の `.apply_filter => |text| a.free(text)` を `.apply_filter => |*af| af.deinit(a)` へ変更。`.filter_focus_next`/`.filter_focus_prev => {}` を追加。
  - ★既存テスト `test "Msg.apply_filter deinit frees owned payload"`（L502-506・`Msg{ .apply_filter = try a.dupe(u8, "山田") }`）を `Msg{ .apply_filter = .{ .author = try a.dupe(u8, "山田"), .since = null, .until = null, .paths = try a.alloc([]u8, 0) } }` へ書き換え。
  - ★**M1**: 既存 `test "AppCmd.load_log owns filter..."`/`"AppCmd.load_log_page owns tip_hash and filter..."`（L454-474・`spec.setAuthor(a, "foo"/"bar")`）を `spec.addCondition(a, .{ .author = try a.dupe(u8, "foo"/"bar") })` へ書き換え。
- [ ] **Step 4:** `zig build test --summary all` → FAIL（update/main が旧 `apply_filter: []u8` リテラルでコンパイルエラー・Task 7/10 で解決）。
- [ ] **Step 5:** Commit: `git add src/messages.zig && git commit -m "feat(messages): ApplyFilter struct + filter_focus_next/prev + ApplyFilter.deinit (§3/m4)"`

---

## Task 5: model.zig（filter_modal_focus: u2 追加）

**Spec:** §1.3  **Files:** Modify `src/model.zig`（Model 構造体 L72-75・init L122-126）

- [ ] **Step 1:** `src/model.zig` へ失敗テストを追加:
  - `test "Model.filter_modal_focus initializes to 0"`（`init` 後 `filter_modal_focus == 0`）
  - `test "Model.filter_modal_focus survives init/deinit no leak"`（primitives・リーク無し）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`filter_modal_focus` 未定義）。
- [ ] **Step 3:** Model 構造体（L72-75 の phase 3a block）へ `filter_modal_focus: u2` を追加。`init`（L122-126）へ `.filter_modal_focus = 0` を追加。`deinit` は追加分無し（primitives）。
  - ★既存 `setFilterState`/`clearFilterState`/`setLogLoadError`（L392-404）は FilterSpec 構造変更後もシグネチャ同一で動作（conditions リストを内部で扱う・Task 1 で FilterSpec.deinit/clone が conditions を処理）。変更不要。
  - ★**M1**: 既存 `test "Model.setFilterState swaps and frees old (transactional)"`（L956-970・`spec.setAuthor(a, "foo"/"bar")` + `m.filter_state.author.?` assertion）を `spec.addCondition(a, .{ .author = try a.dupe(u8, "foo"/"bar") })` + `m.filter_state.getAuthor().?` へ書き換え。
- [ ] **Step 4:** `zig build test --summary all` → FAIL（Task 1 の破壊的変更・Task 7 で解決）。model.zig の `filter_modal_focus` テストは Task 7 で検証。
- [ ] **Step 5:** Commit: `git add src/model.zig && git commit -m "feat(model): add filter_modal_focus u2 field (§1.3)"`

---

## Task 6: git/commands.zig（appendFilterOptions + appendPaths 分割）

**Spec:** §5.1, §5.2  **Files:** Modify `src/git/commands.zig`（logArgv L78-117・logPageArgv L122-130）

- [ ] **Step 1:** `src/git/commands.zig` へ失敗テストを追加（既存 phase 3a テスト L374-498 を拡張）:
  - `test "logArgv: author filter adds --fixed-strings --author"`（phase 3a 回帰・新 API: `addCondition(.{ .author = ... })` で構築した FilterSpec）
  - `test "logArgv: since-only filter adds --since"`（`addCondition(.{ .since = "2026-06-01" })` → `--since=2026-06-01 00:00:00` 含む）
  - `test "logArgv: until date-only adds +1day --until"`（`addCondition(.{ .until = "2026-06-01" })` → `--until=2026-06-02 00:00:00` 含む）
  - `test "logArgv: until HH:MM unchanged"`（`addCondition(.{ .until = "2026-06-01 12:00" })` → `--until=2026-06-01 12:00:00` 含む）
  - `test "logArgv: paths-only appends -- after snapshot_tip"`（`addCondition(.{ .paths = ... })` → argv 末尾（snapshot_tip の後）に `--` + 各 path・codex M2）
  - `test "logArgv: all variants sorted by variant order"`（author+since+until+paths 全 addCondition → argv が author→since→until の順・paths は末尾・冪等性）
  - `test "logArgv: --fixed-strings only when author present"`（since/until/paths のみなら `--fixed-strings` 無し）
  - `test "logArgv: empty filter unchanged (phase 3a regression)"`（`FilterSpec.init()` で phase 3a と同一 argv・paths 無し時 snapshot_tip が末尾）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`appendFilterOptions`/`appendPaths` 未定義・`setAuthor` 呼び出しでコンパイルエラー）。
- [ ] **Step 3:** `src/git/commands.zig` を実装（spec §5.1, §5.2）:
  - `fn appendFilterOptions(list: *std.ArrayList([]const u8), owned: *std.ArrayList([]const u8), a: std.mem.Allocator, filter: FilterSpec) !void`: spec §5.1（revision 前）。`isEmpty` なら return・author があれば `--fixed-strings` append・conditions を variant 順（author→since→until）で処理・paths は無視。
  - `fn appendPaths(list: *std.ArrayList([]const u8), owned: *std.ArrayList([]const u8), a: std.mem.Allocator, filter: FilterSpec) !void`: spec §5.1（revision 後）。`getPaths()` が空なら return・`--` append・各 path を dupe して append（owned へ追跡）。
  - `logArgv`（L78）を更新: 既存 `if (!filter.isEmpty()) { --fixed-strings --author }` ブロック（L103-108）を `try appendFilterOptions(&list, &owned, a, filter);` へ置換。`<snapshot_tip>` append（L115）の後に `try appendPaths(&list, &owned, a, filter);` を追加（spec §5.2 構築順序・codex M2）。
  - `logPageArgv`（L122）は `logArgv` へ転送なので自動追従。
  - ★既存 `setAuthor` を使うテスト（L425-498）を `addCondition(.{ .author = ... })` へ書き換え。
- [ ] **Step 4:** `zig build test --summary all` → FAIL（appcmd/update が旧シグネチャ・Task 7 で解決）。commands.zig の新テストは Task 7 で検証。
- [ ] **Step 5:** Commit: `git add src/git/commands.zig && git commit -m "feat(commands): split appendFilterOptions/appendPaths, since/until/paths in argv (M2)"`

---

## Task 7: update.zig（handleApplyFilter 再構築 + focus arms + 既存 setAuthor 全置換）+ appcmd.zig テスト書換え

**Spec:** §4.1, §4.2, §4.3, §4.4, §4.6, §4.7, §6  **Files:** Modify `src/update.zig`（dispatch L337-340・handleApplyFilter L691-731・handleClearFilter L734-748・handleOpenFilterModal L752-754・新 arms・phase 3a テスト L3013-3300）・`src/appcmd.zig`（テスト L1079/1102/1124/1142 の setAuthor 書換え + 新テスト）

> ★appcmd.zig の実装（`runLogInt`/`runLogPageInt`）は FilterSpec を logArgv へ渡すだけなので構造変更を自動追従（実装変更不要）。**テストのみ setAuthor → addCondition 書換え + since/until/paths 系新テスト**が必要。この Task で純粋層（filter/model/messages/commands/update/appcmd）が整合するが、view.zig の `.author` 参照が未修復のため `zig build test` は Task 9 まで不可。

- [ ] **Step 1:** `src/update.zig` の phase 3a テスト（**L3013-3300**: buildLoadLogCmd 系 L3013-3071 + apply_filter 系 L3073-3300）を新 API へ書き換え + 新規テスト追加:
  - `test "apply_filter: payload-first transactional success (author only)"`（`Msg{ .apply_filter = .{ .author = "foo", .since = null, .until = null, .paths = &.{} } }` → `load_log` 発火・`filter_state.getAuthor()` で `"foo"`・graph suppressed・phase 3a 回帰）
  - `test "apply_filter: since only validates and stores"`（`Msg{ .apply_filter = .{ .author = null, .since = "2026-06-01", .until = null, .paths = &.{} } }` → `filter_state.getSince()` で `"2026-06-01"`）
  - `test "apply_filter: paths only parses and stores"`（`.paths = [1][]u8{"src/ test/"}` → `filter_state.getPaths()` で `["src/", "test/"]`）
  - `test "apply_filter: all variants combined"`（author+since+until+paths 全設定）
  - `test "apply_filter: InvalidDateFormat sets log_load_error, modal stays open"`（`.since = "2026-13-01"` → `log_load_error` にメッセージ・`filter_modal_open == true`・Model 不変・codex D8）
  - `test "apply_filter: AuthorTooLong sets log_load_error"`（256 超過）
  - `test "apply_filter: TooManyPaths / PathTooLong / UnterminatedQuote"`（各エラー）
  - `test "apply_filter: OOM leaves Model unchanged (clearFilterState fallback)"`（clone OOM で空 filter へ戻す・phase 3a 回帰）
  - `test "apply_filter: addCondition OOM no payload leak"`（`checkAllAllocationFailures`・author 成功後 paths addCondition OOM で parsed_paths leak 無し・codex M3）
  - `test "clear_filter: resets to auto + isEmpty + load_log"`（phase 3a 回帰）
  - `test "filter_focus_next: wraps 3→0"`（u2 wrapping・codex m2）
  - `test "filter_focus_prev: wraps 0→3"`
  - `test "open_filter_modal: resets focus to 0"`（§4.4）
  - `test "apply_filter then clear_filter: graph policy suppressed → auto"`（phase 3a 回帰）
  - ★既存 buildLoadLogCmd/handleRequestRefreshLog/handleLogCursorDown 系テスト（L3013-3071）の `spec.setAuthor` → `addCondition(.{ .author = ... })`・`cmd.load_log.filter.author.?` → `cmd.load_log.filter.getAuthor().?` へ書換え。
  - ★**appcmd.zig のテスト書換え**（B1）: `src/appcmd.zig` の既存 setAuthor テスト（`runLogInt: filter by author`/`empty filter result`/`test[er`/`山田` UTF-8・L1079/1102/1124/1142 付近）を `addCondition(.{ .author = ... })` へ書換え。since/until/paths 系 runLogInt 新テスト（`runLogInt: since filter`/`runLogInt: until filter +1day`/`runLogInt: paths filter`）を追加。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（新 arms/挙動 未実装・appcmd テスト未書換え）。
- [ ] **Step 3:** `src/update.zig` を実装（spec §4.1-§4.7）:
  - dispatch switch（L337-340）の `.apply_filter => |text|` を `.apply_filter => |af| return try handleApplyFilter(model, af)` へ（キャプチャ変数 `|text|` → `|af|` へ改名・codex m4）。`.filter_focus_next => return try handleFilterFocusNext(model)` / `.filter_focus_prev => return try handleFilterFocusPrev(model)` を追加。
  - `handleApplyFilter`（L691）を `fn handleApplyFilter(model: *Model, af: ApplyFilter) !AppCmd` へ再構築（spec §4.1）: バリデーションフェーズ（author `utf8CountCodepoints`・since/until `parseDate`・paths `parsePaths(a, af.paths[0])` → 失敗は `log_load_error` へメッセージ・モーダル閉じず・Model 不変・`.none`）→ `var new_spec = FilterSpec.init()` へ各 addCondition（OOM 時 addCondition が payload 自動 deinit）→ `setFilterState(new_spec)` → `clone`（OOM で clearFilterState fallback）→ commit phase（phase 3a 同一）→ `load_log`。
  - `handleClearFilter`（L734）は phase 3a と同一（`clearFilterState` が conditions を処理・変更不要・確認のみ）。
  - `handleFilterFocusNext(model) !AppCmd`: `model.filter_modal_focus +%= 1`（u2 wrapping・codex m2）→ `.none`。
  - `handleFilterFocusPrev(model) !AppCmd`: `model.filter_modal_focus = if (model.filter_modal_focus == 0) 3 else model.filter_modal_focus - 1` → `.none`。
  - `handleOpenFilterModal`（L752）へ `model.filter_modal_focus = 0` を追加（§4.4）。
  - `handleCloseFilterModal`（L758）は変更無し。
  - `buildLoadLogCmd`（L365）は `filter_state.clone` が conditions を処理・変更不要。
  - ★**appcmd.zig の実装は変更不要**（runLogInt/runLogPageInt は filter を logArgv へ渡すだけ・テスト書換えのみ）。
- [ ] **Step 4:** `zig build test --summary all` → まだ FAIL（view.zig が `.author` 参照でコンパイルエラー・Task 9 で修復）。純粋層（filter/model/messages/commands/update/appcmd）は整合したが view が root_test に含まれるため全体ビルド不可。★最初の green マイルストーンは Task 9（view 修復後）。
- [ ] **Step 5:** Commit: `git add src/update.zig src/appcmd.zig && git commit -m "feat(update): handleApplyFilter ApplyFilter payload + focus arms + appcmd tests (§4/D8/m2/m4)"`

> **注意:** Task 7 完了時点で純粋層（filter/model/messages/commands/update/appcmd）は整合したが、**`view.zig` が `model.filter_state.author` 参照（L360/L502）+ view テスト（setAuthor）でコンパイルエラー**。view.zig は `root_test.zig:17` で import されるため `zig build test` は Task 9（view 修復）まで通らない。★`main.zig` は Task 10 まで旧 API（filter_textinput 1つ・handleModalKey の `apply_filter = dup`）だが、root_test 非対象なので `zig build test` には影響しない（`zig build` 実行可能ビルドは Task 10 まで不可）。**最初の green マイルストーンは Task 9**（view 修復後・phase 3a plan の Task 8 = 最初の green と同様）。

---

## Task 8: input.zig（input.Key へ shift_tab + fromZigzagKey 修飾キー + keyToMsgForModeWithModal 拡張）

**Spec:** §7.0, §7.1  **Files:** Modify `src/input.zig`（Key union・fromZigzagKey・keyToMsgForModeWithModal L170-184）

- [ ] **Step 1:** `src/input.zig` へ失敗テストを追加:
  - `test "fromZigzagKey: tab without shift → .tab"`（`KeyEvent{ .key = .tab, .modifiers = .{} }` → `.tab`）
  - `test "fromZigzagKey: tab with shift → .shift_tab"`（`KeyEvent{ .key = .tab, .modifiers = .{ .shift = true } }` → `.shift_tab`・codex M1）
  - `test "keyToMsgForModeWithModal: tab → filter_focus_next"`（モーダル中）
  - `test "keyToMsgForModeWithModal: shift_tab → filter_focus_prev"`（モーダル中）
  - `test "keyToMsgForModeWithModal: enter → null"`（main が ApplyFilter 構築・phase 3a 回帰）
  - `test "keyToMsgForModeWithModal: escape → close_filter_modal"`（phase 3a 回帰）
  - `test "keyToMsgForMode: tab in changes mode → focus_next (regression)"`（モーダル外の `.tab` が従来 `focus_next`・phase 3a 回帰）
  - `test "keyToMsgForMode: shift_tab in changes mode is no-op"`（非モーダルの `.shift_tab` → `null`・codex m1）
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`.shift_tab` 未定義）。
- [ ] **Step 3:** `src/input.zig` を実装（spec §7.0, §7.1）:
  - `Key` union へ `shift_tab` variant を追加（`char/enter/backspace/tab/shift_tab/escape/ctrl_s/ctrl_d/ctrl_u/down/up`）。
  - `fromZigzagKey`（zigzag KeyEvent → Key）の `.tab` 分岐へ modifiers チェックを追加: `k.key == .tab` で `if (k.modifiers.shift) .shift_tab else .tab`（spec §7.0・api-notes `Modifiers` L206・`Key` union L207-213・`KeyEvent` L214 で `zz.Key` に `backtab` 無し・Shift+Tab は `modifiers.shift` で届く・codex m5）。
  - `keyToMsgForModeWithModal`（L170-184）へ `.tab => .filter_focus_next`・`.shift_tab => .filter_focus_prev` を追加（モーダル中）。
  - ★**m1**: 既存の changes/diff/log モードの Key switch は `else => null` を持つため、`shift_tab` variant 追加でコンパイラは強制しない（新 variant は暗黙に `else` へ落ちる）。**非モーダル時の `.shift_tab` は no-op（null）** へ仕様化。変更系（changes/diff モード）の `.tab`（`focus_next` 等）への回帰は、`else` が吸収するので明示的な分岐追加は不要だが、意図を test で明示（`test "keyToMsgForMode: shift_tab in changes mode is no-op"`）。
- [ ] **Step 4:** `zig build test --summary all` → input.zig テスト PASS（他の UI ファイルは Task 9-10 で解決）。
- [ ] **Step 5:** Commit: `git add src/input.zig && git commit -m "feat(input): shift_tab variant + fromZigzagKey modifier + modal tab/shift_tab (M1/§7)"`

---

## Task 9: view.zig（4入力欄モーダル body + graph 非表示理由の conditions 反映）

**Spec:** §8.1, §8.2  **Files:** Modify `src/view.zig`（renderLogMode モーダル分岐・graph 非表示理由 L501-505）

> ★view.zig のモーダル body 構築は main から渡される TextInput 描画文字列に依存。Task 9 は body 4行構築ロジック（main が各欄の view()/getValue() を渡す前提）と graph 非表示理由の拡張。実際の TextInput 4つ所有は Task 10（main）。Task 9 は view 側の描画ロジック（body 文字列組み立て・graph 理由）に集中。

- [ ] **Step 1:** `src/view.zig` へ失敗テストを追加（純粋ヘルパがあれば unit test、無ければ手動検証対象として明記）:
  - `test "filterReasonText: author only"`（FilterSpec が author のみ → `"Filter: author=\"foo\" (graph hidden)"`）
  - `test "filterReasonText: since/until"`（→ `"Filter: since=... until=... (graph hidden)"`）
  - `test "filterReasonText: paths"`（→ `"Filter: paths=... (graph hidden)"`）
  - `test "filterReasonText: combined truncated"`（複数条件・長すぎる場合は主要条件列挙 + truncate）
  - ※モーダル body 4行構築は TextInput 依存で unit test 困難 → §13.7 tmux pty 手動検証対象。
- [ ] **Step 2:** `zig build test --summary all` → FAIL（`filterReasonText` 未定義）。
- [ ] **Step 3:** `src/view.zig` を実装（spec §8.1, §8.2）:
  - `fn filterReasonText(a: std.mem.Allocator, filter: FilterSpec) ![]u8`: conditions を walk して理由文字列を構築（author/since/until/paths の有無で分岐・spec §8.2）。`getAuthor`/`getSince`/`getUntil`/`getPaths` accessor を使用。
  - ★**既存 `model.filter_state.author` 参照の修復（B2 の核心）**: `src/view.zig:360`（`renderStatus` の filter_indicator）と `src/view.zig:502`（`renderLog` の graph hidden 理由）の `.author` 参照 + view.zig テスト（L1090/L1100 setAuthor）を `filterReasonText` / `getAuthor()` accessor へ置換。これで view.zig のコンパイルエラーが解消し `zig build test` が通る（最初の green マイルストーン）。
  - 既存 graph 非表示理由（L501-505 の `Filter: author="..." (graph hidden)`）を `filterReasonText` へ置換。
  - ★**m3**: モーダル body 4行構築（spec §8.1）は **main 側（Task 10 syncFilterModal）へ移譲**（TextInput 所有が main のため・spec §8.1 から §9.3 step 4 へ責任移動）。view 側は `g_view_modal.body`（main が設定）をそのまま `viewWithBackdrop` で描画する既存構造を維持。view の変更は `filterReasonText` 導入 + `.author` 参照修復のみ。
- [ ] **Step 4:** `zig build test --summary all` → PASS（★最初の green マイルストーン・view.zig の `.author` 参照修復で root_test 全体がビルド通過・phase 3a + phase 3b 純粋層/UI input/view テスト全通過）。main.zig は Task 10 まで旧 API（root_test 非対象・`zig build` 実行可能は Task 10 まで不可）。
- [ ] **Step 5:** Commit: `git add src/view.zig && git commit -m "feat(view): filterReasonText for multi-variant graph-hidden reason (§8.2)"`

---

## Task 10: main.zig（App 構造体4欄化 + syncFilterModal/handleModalKey 拡張）★全体ビルド通過

**Spec:** §9.1, §9.2, §9.3, §9.4  **Files:** Modify `src/main.zig`（App L101-102・RuntimeModel.init L266-276・syncFilterModal L361-379・handleModalKey L413-438・handleKey L383-406）

> ★この Task の完了で UI 層が新 API へ完全移行し `zig build test --summary all` が全体通過。

- [ ] **Step 1:** main.zig は UI 層で unit test 不可（グローバル g_app・zigzag 依存）。代わりに §13.7 tmux pty 手動検証項目を plan へ明記し、この Task ではビルド通過 + 手動検証 checklist を Step 4 で実施:
  - 手動検証 checklist（§13.7）: `f` → モーダル4欄・プレフィル / Tab/Shift+Tab フォーカス / Enter で filter 適用・graph 非表示 / `F` clear・graph 復活 / バリデーションエラーでモーダル維持 / 日本語 / since/until 境界 / 複数パス・quote。
- [ ] **Step 2:** `zig build` → FAIL（`filter_textinput` 1つ・`handleModalKey` の `apply_filter = dup` が旧 API・コンパイルエラー）。
- [ ] **Step 3:** `src/main.zig` を実装（spec §9.1-§9.4）:
  - `App` 構造体（L101）の `filter_textinput: zz.TextInput` を `filter_author_input`/`filter_since_input`/`filter_until_input`/`filter_path_input: zz.TextInput` の4つへ分割。
  - `RuntimeModel.init`（L266-276）で4つの TextInput を `zz.TextInput.init(ctx.persistent_allocator)` + 各 `setPlaceholder`/`setCharLimit`（author=256・since/until=16・path=1024・spec §9.1・placeholder `"path (space separated)"` codex n2）。
  - ★**m2**: 現状 `src/main.zig:272` が `setPrompt("author: ")` を呼ぶが、モーダル body 4行構築（`"Author: <input>"` 等）でラベルを付けるため**TextInput の prompt は重複する**。よって4欄とも `setPrompt` を呼ばない（廃止）・ラベルは body 行で付ける。
  - `syncFilterModal`（L361）を拡張（spec §9.3）: false→true 遷移で4つの TextInput へ `getAuthor`/`getSince`/`getUntil`/`paths_to_string(getPaths())` で setValue・`filter_modal.show()`。true→false で hide。毎フレーム `filter_modal_focus` 変化で該当 TextInput のみ `focus()`・他 `blur()`。毎フレーム modal.body へ4行構築（フォーカス中欄は `view(arena)`・他は `getValue()` 静的表示・`\n` join）・`g_view_modal = &filter_modal`。
  - `handleModalKey`（L413）を拡張（spec §9.2）: `keyToMsgForModeWithModal` 呼出 → Msg が `filter_focus_next`/`filter_focus_prev`/`close_filter_modal` なら `step()`・Msg が null で `.enter` なら4つの getValue() から `ApplyFilter` 構築（`var af = ApplyFilter{...}; errdefer af.deinit(gpa);` codex m4・author/since/until 空なら null・paths 空なら `alloc([]u8, 0)`・非空なら1要素 slice）→ `Msg.apply_filter` で `step()`・他は `filter_modal_focus` の TextInput.handleKey へ委譲。
  - `handleKey`（L383）の `app.model.filter_modal_open` チェックは維持（phase 3a）。
  - `App.deinit`（L324）の `filter_textinput.deinit()` を4つの deinit へ。
  - `RuntimeModel` リテラル（L565 の `filter_modal = undefined`）は維持・4つの TextInput も `undefined`（init で生成）。
- [ ] **Step 4:** `zig build` → PASS。`zig build test --summary all` → PASS（★全体通過・phase 3a + phase 3b 全テスト）。手動検証 checklist（Step 1）を tmux pty で実施（§13.7）。
- [ ] **Step 5:** Commit: `git add src/main.zig && git commit -m "feat(main): 4-input filter modal, ApplyFilter payload, focus sync (§9/M4/m4/n2)"`

---

## Task 11: TODO.md + README（phase3b チェック + TZ 注意書き）

**Spec:** §13.7, §16  **Files:** Modify `TODO.md`（phase 3b L189-195）・`README.md`（フィルタ説明）

- [ ] **Step 1:** `TODO.md` の phase 3b（L189-195）の「日付範囲」と「パス」チェックボックスを `[x]` へ。完了コメント（spec/plan パス・実装概要・純粋層→UI 配線）を追記。phase 3b 残（ブランチ/graph 維持/StreamTooLong/busy lifecycle）は `[ ]` のまま明記。
- [ ] **Step 2:** `README.md` のキーマップ/フィルタ説明へ phase 3b 機能（`f` モーダル4欄・Tab/Shift+Tab・`F` clear・日付フォーマット・パス複数指定）と **TZ 注意書き**（「フィルタの日付は環境 TZ（通常 JST）で解釈・CI/SSH 等で TZ が変わると結果が変わる可能性」・codex m6）を追記。
- [ ] **Step 3:** `zig build test --summary all` → PASS（docs 変更でビルド影響無し・確認）。
- [ ] **Step 4:** Commit: `git add TODO.md README.md && git commit -m "docs: mark phase3b date+path filter complete, add TZ note to README (§13.7/§16)"`

---

## Self-Review

**1. Spec coverage（spec 各節 → Task）:**
- §1.1 FilterCondition/FilterSpec → Task 1 ✓
- §1.2 date/path helpers（parseDate/formatGitDate/parsePaths/paths_to_string/DateSpec）→ Task 2/3 ✓
- §1.3 Model.filter_modal_focus → Task 5 ✓
- §2.1-§2.3 セマンティクス → Task 2（date TZ/境界）/ Task 3（path pathspec）の実装 + Task 11（README TZ 注記）✓
- §3.1-§3.3 Msg/AppCmd → Task 4 ✓
- §4.1-§4.7 reducer → Task 7 ✓
- §5.1-§5.3 argv → Task 6 ✓
- §6 appcmd → 実装（runLogInt/runLogPageInt）は自動追従・**テスト書換え + since/until/paths 新テストは Task 7** ✓
- §7.0-§7.1 input → Task 8 ✓
- §8.1-§8.2 view → Task 9（§8.1 body 構築は §9.3 Task 10 main へ移譲・m3）✓
- §9.1-§9.4 main → Task 10 ✓
- §13 テスト計画 → 各 Task の Step 1 ✓
- §16 phase3b 残 → Task 11 で TODO.md 明記 ✓
- §19 Open product decisions → 全 Task で D1-D13 反映 ✓

**2. Placeholder scan:** TBD/TODO/「適切に」「similar to」無し。各 Step に具体的テスト名・実装内容・コマンドあり。

**3. Type consistency:** `addCondition`/`getAuthor`/`getSince`/`getUntil`/`getPaths`/`removeVariant`（Task 1）→ Task 4/6/7/9/10 で同一名称使用。`ApplyFilter` 構造体 + `deinit` メソッド（Task 4）→ Task 7/10 で同一。`appendFilterOptions`/`appendPaths`（Task 6）→ Task 6 内で logArgv 呼出。`shift_tab` variant（Task 8）→ Task 8 内で fromZigzagKey/keyToMsgForModeWithModal 使用。`filterReasonText`（Task 9）→ Task 9 内で使用。整合確認済み。

**4. 密結合 Task:** Task 1-9 は FilterSpec 構造変更で密結合（filter/model/messages/update/commands/appcmd/input/view 全てが `.author`/`setAuthor` を参照・root_test import 対象）。**最初の green マイルストーンは Task 9**（view.zig `.author` 参照修復 + appcmd テスト書換え後）。Task 10 は main 移行（root_test 非対象・`zig build` 実行可能は Task 10 で通過）。各 Task の冒頭で注記済み・phase 3a plan の「Task 8 = 最初の green」パターンと整合。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-todo2-log-view-phase3b-date-path-filter.md`. 実装は **Subagent-Driven（推奨・Task ごとに fresh subagent + review）** または **Inline Execution（executing-plans・チェックポイント付きバッチ）** の何れか。
