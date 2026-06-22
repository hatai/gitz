# コミットログフィルタ（日付範囲 + パス）設計 — TODO 2 / phase 3b（rev.2）

- 日付: 2026-06-22（rev.2: codex レビュー M1-M4 / m1-m6 / n1-n3 全面反映版）
- 対象: `TODO.md`「TODO 2 phase 3b」のうち **日付範囲（`--since`/`--until`）+ パス（`-- <path>`・複数可）**。
  `FilterSpec` を **`FilterCondition` union のリスト**へ再構築し、author/since/until/paths を統一表現へ。
- 親設計:
  - `docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md`（rev.3・phase 3a 完了版）
  - `docs/superpowers/specs/2026-06-19-todo2-log-view-phase2-display-design.md`（rev.2・phase 2 完了版）
  - `docs/superpowers/specs/2026-06-18-todo2-log-view-phase1-design.md`（rev.9・phase 1 完了版）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（**zigzag/std の実 API はこれが正**）。
- スコープ外（phase 3b 残・別 spec）: ブランチフィルタ / フィルタ中の graph 維持 / StreamTooLong limit 注入 seam / busy lifecycle 完全修正。

> **記述方針**: phase 3a に倣い (a) データ構造は field 定義のみ、(b) Msg/AppCmd は tag+ペイロード field 定義のみ、(c) reducer arm は番号付きステップ（コード block 無し）、(d) 方針・判断根拠・注意点を dense に。実装コード（compile 可能な Zig block）は書かない。所有権ライフサイクル・errdefer 位置等の詳細は writing-plans / 実装フェーズへ委ねる。

---

## Status

**Draft for user spec-review**。codex レビュー（BLOCKER 0 / MAJOR 4 / MINOR 6 / NIT 3）全面反映済み。主な反映: M1（`input.Key` へ `shift_tab` variant 追加・§7.0）/ M2（`appendFilterOptions` + `appendPaths` の2関数分割・§5.1）/ M3（`addCondition` OOM 時 payload 自動 deinit・§1.1/§4.1）/ M4（`paths_to_string` 新設 + 往復対称テスト・§1.2/§13.1）。user 承認後、writing-plans へ移行する。

### codex レビュー対応表（rev.1 → rev.2）

| ID | 指摘（要約） | 反映節 |
|---|---|---|
| **M1** | Shift+Tab が現 `input.Key` 抽象で判定不能（modifiers 無し） | §7.0（`input.Key` へ `shift_tab` variant 追加 + `fromZigzagKey` 修飾キー判定）, §7.1, §13.5 |
| **M2** | `appendFilterArgs` 単一 helper では revision 前後の2挿入点を表現できない | §5.1（`appendFilterOptions` revision 前 + `appendPaths` revision 後 へ分割）, §5.2（構築順序明記） |
| **M3** | reducer の condition payload が addCondition OOM で leak する | §1.1（`addCondition` OOM 時 payload 自動 deinit）, §4.1 step 1-2（所有権ライフサイクル明記）, §13.2（payload leak テスト） |
| **M4** | `paths_to_string` ↔ `parsePaths` 往復テストが §13 に欠落 | §1.2（`paths_to_string` 定義 + 往復対称性）, §13.1（往復テスト） |
| **m1** | `addCondition` 重複 variant 挙動が未仕様化 | §1.1（「上書き（後勝ち）」へ固定）, §13.1 |
| **m2** | `(focus +% 1) % 4` は u2 へ fit せずコンパイルエラー | §4.3（`+%= 1` wrapping add のみ） |
| **m3** | `findVariant` 戻り値の借用/所有が曖昧 | §1.1（variant 別 accessor `getAuthor`/`getSince`/`getUntil`/`getPaths` へ変更）, §9.3 |
| **m4** | main の ApplyFilter 構築で部分 dupe 失敗時 rollback 未指定 | §9.2（`errdefer af.deinit(gpa)` + `ApplyFilter.deinit` メソッド）, §13.6 |
| **m5** | `parsePaths` 未閉じ quote 挙動が未仕様化 | §1.2（`error.UnterminatedQuote`）, §13.1 |
| **m6** | TZ 変動挙動は unit test で検証不可 | §13.7（手動検証専用 + README 注意書き要求） |
| **n1** | `filter.deinit(a)` の意味が変わる点に触れない | §3.3 |
| **n2** | path placeholder `"src/ *.zig"` は空白含み誤解されやすい | §9.1（`"path (space separated)"`） |
| **n3** | `max_path_runes` 1024 scalar と PATH_MAX 4096 byte の整合 | §1.2（整合注記） |

---

## Goal

TODO 2 phase 3b の部分マイルストーンとして、phase 3a（author フィルタ）の `FilterSpec` を **`FilterCondition` union のリスト**へ再構築し、その上に:

1. **日付範囲フィルタ**: `--since`/`--until`（ローカル TZ・`YYYY-MM-DD` と `YYYY-MM-DD HH:MM`）。
2. **パスフィルタ**: `-- <path>`（git デフォルト pathspec・複数パス可・空白区切り入力）。
3. **UI 拡張**: phase 3a の単一入力欄モーダルを **4入力欄（Author/Since/Until/Path）** へ拡張。Tab/Shift+Tab でフォーカス移動・Enter で全適用。

完了後、`TODO.md` phase 3b の「日付範囲」「パス」を部分チェック（phase 3b 残: ブランチ/graph 維持/StreamTooLong/busy lifecycle）。

---

## Background

### 現状（実コードから検証済みの事実）

| 項目 | 事実 | 出典 |
|---|---|---|
| `FilterSpec` 構造 | `author: ?[]u8` 単一 field。`setAuthor`/`clearAuthor`/`isEmpty`/`clone`/`eql`/`deinit` | `src/filter.zig:11-60` |
| `Msg.apply_filter` | `[]u8`（author 単一・main が `TextInput.getValue()` を dupe） | `src/messages.zig:62`, `:150` |
| `handleApplyFilter` | payload-first トランザクション（payload → FilterSpec 1つ構築 → Model swap → AppCmd clone） | `src/update.zig:691-731` |
| `logArgv`/`logPageArgv` | `filter.isEmpty()` で `--fixed-strings --author=<text>` を append。`logPageArgv` は `logArgv` へ転送 | `src/git/commands.zig:78-130` |
| モーダル UI | `App.filter_textinput: zz.TextInput`（1つ）+ `App.filter_modal: zz.Modal`。`g_view_modal` グローバル経由で `view.render` が `viewWithBackdrop` を返す | `src/main.zig:101-102,269-276,361-379`, `src/view.zig:28,721-731` |
| `syncFilterModal` | `filter_modal_open` の false→true 遷移で `filter_textinput.setValue(filter_state.author or "")` + `modal.show()`。毎フレーム `modal.body = filter_textinput.view(arena)` | `src/main.zig:361-379` |
| `handleModalKey` | Escape → `close_filter_modal`・Enter → main が `getValue()` を dupe して `Msg.apply_filter` 構築・それ以外 → `filter_textinput.handleKey(k)` | `src/main.zig:413-438` |
| `keyToMsgForModeWithModal` | モーダル中: Escape → `close_filter_modal`・それ以外（Enter/tab/q/r/L 含む）→ null（main へ委譲） | `src/input.zig:170-180` |
| graph policy | `graph_render_policy`。filter 適用で `.suppressed`、clear で `.auto` | `src/model.zig:70,120`, `src/update.zig:718,741` |
| フィルタ中の graph 非表示理由 | view が `Filter: author="..." (graph hidden)` をメタ行表示 | `src/view.zig:503` |
| phase 3a テスト | `apply_filter`/`clear_filter`/`open/close_filter_modal`/modal/focus 系で 454 tests passing | `src/update.zig:3073-3300` 等 |

### phase 3a からの主な破壊的変更（リリース直後なので影響小）

1. **`FilterSpec`**: `author: ?[]u8` → `conditions: std.ArrayList(FilterCondition)`（unmanaged）。
2. **`Msg.apply_filter`**: `[]u8` → `ApplyFilter`（4フィールド構造体）。
3. **`FilterSpec` API**: `setAuthor`/`clearAuthor` を `addCondition`/`removeVariant` 等のリスト操作へ置換。`isEmpty` は `conditions.items.len == 0`。
4. **`App` 構造体**: `filter_textinput: zz.TextInput`（1つ）→ 4つ（author/since/until/path）+ フォーカス index は Model 側（`filter_modal_focus: u2`）。
5. **`handleModalKey`**: Enter 時に 4欄から `ApplyFilter` payload を構築。Tab/Shift+Tab で `filter_focus_next`/`filter_focus_prev` Msg 発火。
6. **`logArgv`/`logPageArgv`**: author 専用展開を `appendFilterArgs`（conditions walk）へ置換。
7. **view**: モーダル body を4行構築。フォーカス中欄は `TextInput.view()`、他は `getValue()` 静的表示。

---

## Non-goals

- **ブランチフィルタ（`--branches`）**: snapshot_tip との和集合問題（B3）の解決が前提・別 spec。
- **フィルタ中の graph 維持**: nearest-visible-parent 投影 or Git history simplification・別 spec（M1/M2）。phase 3b も phase 3a と同様 `graph_render_policy=.suppressed` で**一律非表示**（since/until のみなら topology 保存される可能性が高いが、安全側で抑制・graph 維持は別タスクへ委ねる）。
- **StreamTooLong limit 注入 seam**: テスト容易化インフラ・別 spec（phase 3a §6.3 で catch→正規化のみ）。
- **busy lifecycle 完全修正**: runtime lifecycle のみで busy 管理・別 spec（M-N9）。
- **filter のファイル永続化・履歴（suggestions）・正規表現・case-insensitive**: phase 3a と同様メモリ上のみ。
- **オーバーレイ compositor**: `viewWithBackdrop` 全面置換を踏襲（m-N5）。
- **`--grep` 等の追加フィルタ種別**: 将来拡張。`FilterCondition` union へ variant 追加で対応可能（アプローチ B 選択の動機）。

---

## Architecture overview

Elm 風・副作用隔離（CLAUDE.md）を踏襲。純粋層（`filter.zig` 拡張 / `model.zig` / `messages.zig` / `update.zig` / `appcmd.zig` / `git/commands.zig`）を TDD → UI 層（`input.zig` / `view.zig` / `main.zig`）を配線、の順。

```
[ユーザ f] → open_filter_modal → model.filter_modal_open=true
   ↓ main.syncFilterModal: 4つの TextInput へ現 FilterSpec.conditions から各 variant を lookup して setValue
[入力: foo<Tab>2026-06-01<Tab><Tab>src/<Enter>]
   ↓ Tab → input.keyToMsgForModeWithModal → Msg.filter_focus_next（reducer が filter_modal_focus を更新）
   ↓ main: filter_modal_focus 変化検知 → 該当 TextInput.focus() / 他 blur()
   ↓ Enter → main.handleModalKey: 4欄から ApplyFilter payload 構築 → Msg.apply_filter
   ↓ update.handleApplyFilter: バリデーション → ApplyFilter から FilterCondition リストへ変換 → FilterSpec 構築 → Model swap
   ↓ AppCmd.load_log{filter} → appcmd.runLogInt → logArgv(skip,max,tip,filter)
   ↓ logArgv が appendFilterArgs で conditions を walk → --author/--since/--until/-- paths を展開
   ↓ git log 実行 → Msg.log_loaded → update.handleLogLoaded（graph_render_policy=.suppressed で graph スキップ）
   ↓ view.renderLogMode: graph 非表示理由 + log_load_error + modal 有無で viewWithBackdrop 分岐
```

---

## 1. Data structures

### 1.1 `FilterCondition` union と `FilterSpec` 再構築（`src/filter.zig`・純粋・TDD 対象）

**`FilterCondition` union の定義**:

| variant | payload 型 | 所有権 | 意味 |
|---|---|---|---|
| `.author` | `[]u8` | persistent 所有・dup 済み | 作者名 partial（ユーザ入力そのまま・`--fixed-strings --author=<literal>` で literal match） |
| `.since` | `[]u8` | persistent 所有 | 開始日（ユーザ入力そのまま・`YYYY-MM-DD` or `YYYY-MM-DD HH:MM`） |
| `.until` | `[]u8` | persistent 所有 | 終了日（同上） |
| `.paths` | `[][]u8` | persistent 所有（外側 slice + 各要素） | 複数パス（パース済み・git デフォルト pathspec） |

> **variant tag 型**: `enum { author, since, until, paths }`。`findVariant(tag)` 等で variant 指定に使う。

**`FilterSpec` 構造体の再構築**:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `conditions` | `std.ArrayList(FilterCondition)` | persistent 所有（unmanaged） | 条件リスト。モーダル4固定欄に対応し、各 variant は高々1つ（reducer が保証） |

**定数**:

| 定数 | 値 | 意味 |
|---|---|---|
| `max_author_runes` | `256` | phase 3a 継承・Unicode scalar 数 |
| `max_date_runes` | `16` | `YYYY-MM-DD HH:MM` の文字長 |
| `max_path_runes` | `1024` | path 入力欄の文字数上限（TextInput.setCharLimit と整合） |
| `max_path_count` | `16` | パス数上限・極端な入力対策 |

**方針（メソッド実装コードは書かない・ステップで記述）**:

- `init()`: `conditions` empty を返す（非失敗）。
- `isEmpty()`: `conditions.items.len == 0`。argv へ filter 系オプションを追加しない判定。
- `addCondition(a, cond)`: 指定 variant と同じ variant の既存 condition があれば**上書き**（旧を deinit して置換）・無ければ append。いずれも OOM で self 不変（append/置換は失敗時リスト不変）。★重複は API 側で「上書き（後勝ち）」へ正規化（codex m1）・reducer が呼び出し前に removeVariant する必要無し。
  - ★**payload leak 対策（codex M3）**: `addCondition` の呼出側は dup 済み payload を渡すが、append/置換の realloc が OOM すると payload がリストへ入らず呼出側へも戻らない。よって `addCondition` は**失敗時に payload を deinit してから error を返す**（強例外保証・呼出側は成功時のみ payload 所有権を移譲したと見做す）。実装: `conditions.append(a, cond) catch { deinitCondition(a, cond); return error.OutOfMemory; }`。これにより reducer の errdefer が簡潔になる。
- `removeVariant(a, tag)`: 指定 variant の condition を削除（deinit して詰める）。未存在は no-op。
- **variant 別 accessor（借用明示・codex m3）**: union を値返しすると `.paths` の内側 slice が所有/借用で曖昧になるため、variant 別の借用 accessor を提供:
  - `getAuthor() ?[]const u8`: `.author` condition があればその text（借用）・無ければ null。
  - `getSince() ?[]const u8` / `getUntil() ?[]const u8`: 同型。
  - `getPaths() []const []const u8`: `.paths` condition があればその list（借用・空可）・無ければ空 slice。
  - これらはモーダル再オープン時のプレフィル（§9.3）と view の理由表示（§8.2）で使う。argv 生成（§5）は conditions を直接 walk するので accessor を使わない。
- `clone(a)`: deep-copy・各 condition の payload を個別に dup（errdefer で順次 rollback）。
- `deinit(a)`: 各 condition を個別 free（paths は外側 + 各要素）。
- `eql(other)`: 順序込みで比較（デバッグ/テスト用・実用しない）。

> **`setAuthor`/`clearAuthor`（phase 3a）は廃止**: `addCondition(.{ .author = ... })`/`removeVariant(.author)` へ置換。phase 3a コードの全呼び出し site を更新（コンパイラが検知）。
>
> ★**`addCondition` の OOM 時 payload 自動解放**（codex M3）は、reducer のトランザクション性を壊さない核心仕様。呼出側は `addCondition(a, .{ .author = try a.dupe(u8, text) }) catch return error.OutOfMemory;` と書けば、OOM 時に dupe 済み text が leak しない（addCondition 内で deinit）。

### 1.2 日付・パスヘルパ（同ファイル内・純粋・TDD 対象）

**`DateSpec` 構造体**（内部・テスト対象）:

| field | 型 | 意味 |
|---|---|---|
| `year` | `u16` | 西暦（1-9999） |
| `month` | `u4` | 月（1-12） |
| `day` | `u5` | 日（1-31・月/年で有効範囲変動） |
| `hour` | `?u5` | 時（0-23）・日付のみ入力時は null |
| `minute` | `?u6` | 分（0-59）・日付のみ入力時は null |

**`parseDate(input) !DateSpec`**:
- 受理フォーマット: `YYYY-MM-DD`（10文字）と `YYYY-MM-DD HH:MM`（16文字）。
- 不正フォーマット・範囲外（月13/日32等）・うるう年2/29 違反は `error.InvalidDateFormat`。
- 月の日数検証: `daysInMonth(year, month)` ヘルパで判定（うるう年込み・`std.time` の定数を利用）。

**`formatGitDate(a, ds, is_until_date_only) ![]u8`**:
- git へ渡す文字列を生成（呼出側が所有・free）。
- `is_until_date_only == true` のとき +1day した日付を生成（§2.2）。
- since 常に `YYYY-MM-DD 00:00:00`（HH:MM 指定時は `YYYY-MM-DD HH:MM:00`）。包含（git 標準）。
- until HH:MM 指定時: そのまま `YYYY-MM-DD HH:MM:00`（排他・git 標準）。
- until 日付のみ: +1day した `YYYY-MM-DD 00:00:00`（翌日 00:00:00 未満 = 当日 23:59:59 まで包含）。

**`daysInMonth(year, month) u5`**: うるう年判定込み（`year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)`）。2月は28/29。

**`addOneDay(ds) DateSpec`**: 月末/年末/うるう年境界を処理。例: 2026-12-31 → 2027-01-01、2026-02-28 → 2026-03-01、2024-02-28 → 2024-02-29。

**`parsePaths(a, input) ![][]u8`**:
- 空白区切り・`"` で quote 対応（`"my dir/file"` → `my dir/file`）・`\<char>` エスケープ対応（`\"` → `"`、`\\` → `\`、`\ ` → ` `）。
- 空要素（連続空白・quote 内空）はスキップ。
- **未閉じ quote**（`"my dir` 等・行末まで閉じ `"` 無し）は `error.UnterminatedQuote`（codex m5）。
- 要素数 > `max_path_count` は `error.TooManyPaths`。
- 各要素バイト長 > 4096（PATH_MAX 相当）は `error.PathTooLong`。
- 呼出側が所有（外側 slice + 各要素）。

> ★**`max_path_runes` と PATH_MAX の整合**（codex n3）: path 入力欄の char_limit は `max_path_runes = 1024`（Unicode scalar 数）。日本語等の多バイトを含むと最大 1024 × 4 = 4096 byte。しかし `parsePaths` の各要素 PATH_MAX(4096 byte) チェックは**各パス毎**（欄全体ではない）。欄全体が 1024 scalar でも、空白区切りで split 後の各要素は ≤ 4096 byte を保つ（要素数 `max_path_count = 16` 以下なら各要素は欄全体の部分文字列 ≤ 4096 byte）。よって char_limit と PATH_MAX は整合。複数パス合計が 1024 scalar を超える場合は TextInput.setCharLimit が入力段階で弾く。

**`paths_to_string(a, paths) ![]u8`**（★codex M4・§9.3 モーダルプレフィル用・`parsePaths` の逆変換）:
- `[]const []const u8` → 空白区切り文字列（呼出側が所有・arena 推奨）。
- 空白/`"`/`\` を含むパスは再エスケープ（`my dir/file` → `"my dir/file"`、`a"b` → `"a\"b"` 等）。
- 空リスト → 空文字。
- ★**`parsePaths` との往復対称性**: `paths_to_string(parsePaths(s))` が正規化された s に等しいこと（空白/quote/`\` 含むパスで検証・§13.1 でテスト）。モーダル再オープン時のプレフィル（`[][]u8` → 文字列 → 再 split）でエスケープ非対称があると、開く度にパス表現が変化するのを防ぐ。

> **`src/root_test.zig` の `@import("filter.zig")` は phase 3a で追加済み**。新規 helper のテストは同ファイル内の `test {}` ブロックへ追加。

### 1.3 `Model` フィールド（phase 3a + 新規1つ）

`src/model.zig` の `Model` 構造体へ追加（phase 3a フィールドは不変）:

| field | 型 | デフォルト | 意味 |
|---|---|---|---|
| `filter_modal_focus` | `u2` | `0` | ★新規: モーダル中のフォーカス index（0=author, 1=since, 2=until, 3=path）。Model が持つことで input.zig の unit test でフォーカス遷移をカバー可能 |

`Model.init`（`src/model.zig:77`）へ `.filter_modal_focus = 0` を追加。`Model.deinit` は追加分無し（primitives）。

phase 3a フィールド（`filter_state`/`filter_modal_open`/`log_load_error`/`log_snapshot_tip`/`graph_render_policy`）は不変。`FilterSpec` の内部が `conditions` リストへ変わるだけなので、Model 側のヘルパ（`setFilterState`/`clearFilterState`/`setLogLoadError` 等）はシグネチャ同一で動作（`src/model.zig:392-404`）。

---

## 2. セマンティクス（日付 timezone / 境界 / パス pathspec）

### 2.1 日付 timezone（ローカル TZ・ユーザ判断）

- **方式**: ユーザ入力を環境 TZ（TZ 環境変数・通常 JST）で解釈し、git へは入力文字列を基に生成した `YYYY-MM-DD HH:MM:SS` 形式を**オフセット無し**で渡す（git が環境 TZ で解釈・git デフォルト）。
- **CI/SSH/cron 等での TZ 変動リスク**: spec へ明記。同じ入力でも環境 TZ が変わると結果が変わる可能性（phase 3a は UTC 固定だったが、ユーザ判断でローカル TZ へ変更）。
- **TZ 環境変数未設定**: git デフォルト（システム TZ or UTC）に従う。

### 2.2 日付境界包含（HH:MM 指定で排他・日付のみで当日包含）

- **HH:MM 指定時**: until はその時刻**未満**（排他・git 標準）。`--until=2026-06-01 12:00:00` → git は `12:00:00` 未満を含む。ユーザ入力そのまま（秒 `:00` 補完のみ）。
- **日付のみ指定時**: until は**当日包含**（+1day）。`--until=2026-06-02 00:00:00` として git へ渡す（翌日 00:00:00 未満 = 当日 23:59:59 まで含む）。
- **since**: 常に `00:00:00` 補完。`--since=2026-06-01 00:00:00`。HH:MM 指定時はその HH:MM:00。包含（git 標準）。
- **+1day 計算**: `addOneDay(ds)`（§1.2）で月末/年末/うるう年を処理。

### 2.3 パス pathspec（git デフォルト・複数可）

- **方式**: git デフォルト pathspec（wildcard `*`/`?`/`[abc]` 使用可・ディレクトリ prefix で配下マッチ）。
  - `src/` → src 配下全体。
  - `src/*.zig` → src 直下の .zig ファイル（`*` は `/` を含まない）。
  - `src/**/*.zig` は git pathspec デフォルトでは `**` が特別扱いされない（magic `:(glob)` が必要）。phase 3b では `**` 非サポート（ユーザが `src/` 等で配下を絞る）。
- **複数パス**: 空白区切り入力・`git log -- path1 path2` の和集合。
- **quote/エスケープ**: `parsePaths`（§1.2）が `"my dir/file"`・`\<char>` を処理。
- **空要素**: スキップ。
- **`--fixed-strings` の影響**: pathspec には無関係（`--fixed-strings` は `--author`/`--grep` 等の regex 系のみ）。

---

## 3. Msg & AppCmd changes（`src/messages.zig`）

### 3.1 新入力 Msg（フォーカス移動）

| tag | payload | 意味 |
|---|---|---|
| `filter_focus_next` | 無し | ★新規: Tab（モーダル中）・フォーカスを次欄へ |
| `filter_focus_prev` | 無し | ★新規: Shift+Tab（モーダル中）・フォーカスを前欄へ |

`Msg.deinit` switch へは `=> {}`（payload 無し）。

### 3.2 `apply_filter` の構造体化（★破壊的変更: `[]u8` → `ApplyFilter`）

`Msg`（`src/messages.zig:62`）の変更:

| tag | 変更 | payload |
|---|---|---|
| `apply_filter` | ★破壊的変更: `[]u8` → `ApplyFilter` 構造体 | 下記 |

**`ApplyFilter` 構造体**（main が4つの TextInput.getValue() を dupe して構築・Msg consumer が free）:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `author` | `?[]u8` | persistent 所有・null または dup 済み | null = 作者欄空 |
| `since` | `?[]u8` | 同上 | null = since 欄空 |
| `until` | `?[]u8` | 同上 | null = until 欄空 |
| `paths` | `[][]u8` | persistent 所有・空 slice 可 | 空 = path 欄空・main は欄全体を1要素 slice として dupe（split は reducer 側の parsePaths が実行） |

> **方針**: main は Enter 押下時に各 TextInput.getValue() を取得し、空文字なら `null`（paths は空 slice）、非空なら dup して格納。paths は**欄全体を1つの文字列**として1要素 slice へ格納（例: `"src/ test/"` → `["src/ test/"]`）。reducer が `parsePaths` で split・パースする（テスト容易性・main は純粋ロジックを持たない）。

`Msg.deinit` switch（`src/messages.zig:150`）の `.apply_filter` arm 変更:
- 旧: `.apply_filter => |text| a.free(text)`。
- 新: `.apply_filter => |af| { if (af.author) |x| a.free(x); if (af.since) |x| a.free(x); if (af.until) |x| a.free(x); for (af.paths) |p| a.free(p); a.free(af.paths); }`。

`open_filter_modal`/`close_filter_modal`/`clear_filter` は phase 3a と変更無し（payload 無し）。

### 3.3 `AppCmd`（phase 3a と同一）

`LoadLog.filter`/`LoadLogPage.filter` は `FilterSpec` なので、内部構造変更のみで AppCmd の field 定義は不変。`AppCmd.deinit` の `filter.deinit(a)`（`src/messages.zig:255-261`）もシグネチャ同一だが、**内部挙動が変わる**: phase 3a は `author: ?[]u8` を free するだけだったが、phase 3b は `conditions` リストの各 condition を再帰 free（paths は外側 + 各要素）する。実装者は `FilterSpec.deinit` が conditions 全体を解放することを確認すること（codex n1）。

---

## 4. Reducer changes（`src/update.zig`）

> **記述形式**: phase 3a に倣い各 arm を番号付きステップで記述（コード block 無し）。

### 4.1 `apply_filter` arm（★破壊的再構築・ApplyFilter payload-first・トランザクショナル）

**入力**: `Msg.apply_filter: ApplyFilter`（main が4欄から構築・Msg.deinit が free）。

**方針**: FilterSpec.conditions には「ユーザ入力生文字列」を保持（モーダル再オープン時のプレフィル整合性）。バリデーションは apply 時に実行し、argv 生成時に再度パースして git 用文字列を生成（2回パースだが、各ヘルパが単一責任でテスト容易）。

1. **バリデーションフェーズ（Model 不変保証）**:
   - `af.author` 非 null かつ空でなければ `std.unicode.utf8CountCodepoints` で `max_author_runes` チェック → 超過は `error.AuthorTooLong`。
   - `af.since` 非 null かつ空でなければ `parseDate` → 失敗は `error.InvalidDateFormat`。
   - `af.until` 同上。
   - `af.paths` 非空（len > 0）なら `parsePaths(a, af.paths[0])`（欄全体文字列を split）→ 失敗は伝播（`TooManyPaths`/`PathTooLong`/`UnterminatedQuote`）。★結果 `parsed_paths: [][]u8` を step 2 で addCondition へ渡すため**ローカル変数へ保持**。
   - 全て通過するまで Model は触らない。★このフェーズで確保した `parsed_paths` は、step 2 の paths addCondition 成功時に所有権が new_spec へ移譲・OOM 時は addCondition 内で自動 deinit（§1.1）・それ以前の OOM は parsed_paths 未確保なので leak 無し（codex M3）。
2. **FilterSpec 構築**:
   - `var new_spec = FilterSpec.init()` → `errdefer new_spec.deinit(a)`。
   - author 非 null かつ空でなければ `try new_spec.addCondition(a, .{ .author = try a.dupe(u8, text) })`。★`addCondition` は OOM 時 payload（dupe 済み text）を自動 deinit する（§1.1）ので、呼出側は `try` だけで leak 無し。
   - since/until 同様（各 variant 高々1つ・重複は addCondition が上書き）。
   - paths: `try new_spec.addCondition(a, .{ .paths = parsed_paths })`。★OOM 時 parsed_paths は addCondition 内で deinit。成功時は所有権が new_spec へ移譲（以降 parsed_paths は触らない）。
   - いずれかの addCondition が OOM した場合、既に new_spec へ入った condition は `errdefer new_spec.deinit(a)` で解放される。
3. **Model swap**（強例外保証・phase 3a と同型）:
   - `model.setFilterState(new_spec)`（`new_spec` の所有権を Model へ移譲・以後触らない）。
4. **AppCmd 用 clone**:
   - `const cmd_spec = try model.filter_state.clone(a)` → `errdefer cmd_spec.deinit(a)`。
   - clone 失敗時は `model.clearFilterState()` で強例外保証（空 filter へ戻す）。
5. **成功後の Model 更新**（全て非失敗操作・phase 3a と同一）:
   - `filter_modal_open = false` / `log_request_generation += 1` / `log_page_requested = null` / `log_has_more = false` / `clearLogSnapshotTip()` / `graph_render_policy = .suppressed`（★filter が1つでもあれば suppressed）/ `invalidateLogGraph()` / `clearDetailOwner()` / `replaceDetailFiles(&.{})` / `setStr(&detail_diff, "")` / `setStr(&log_load_error, "")` / `replaceLogCommits(&.{})`。
6. **AppCmd 構築**:
   - `return .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = model.log_request_generation, .filter = cmd_spec } }`。

**失敗時**（Model 不変・`log_load_error` へユーザ通知・★**モーダルを閉じない**）:

| エラー | `log_load_error` メッセージ |
|---|---|
| `AuthorTooLong` | `"作者名が長すぎます（256 Unicode scalar まで）"` |
| `InvalidDateFormat` | `"日付フォーマットが不正です（YYYY-MM-DD または YYYY-MM-DD HH:MM）"` |
| `TooManyPaths` | `"パス数が多すぎます（16 まで）"` |
| `PathTooLong` | `"パスが長すぎます（4096 バイトまで）"` |
| OOM | `"フィルタ適用に失敗（メモリ不足）"` |

何れも `setStr(&log_load_error, msg)` → `return .none`（モーダル閉じず・ユーザが修正して再 Enter 可能・phase 3a と整合）。

### 4.2 `clear_filter` arm（phase 3a と同一）

1. `clearFilterState()` / `filter_modal_open = false` / `log_request_generation += 1` / `log_page_requested = null` / `log_has_more = false` / `clearLogSnapshotTip()` / `graph_render_policy = .auto`（graph 復活）/ `invalidateLogGraph()` / `clearDetailOwner()` / `replaceDetailFiles(&.{})` / `setStr(&detail_diff, "")` / `setStr(&log_load_error, "")` / `replaceLogCommits(&.{})`。
2. `return try buildLoadLogCmd(model);`（filter は isEmpty・全件再取得）。

### 4.3 `filter_focus_next` / `filter_focus_prev` arms（★新設）

**`handleFilterFocusNext(model)`**:
- `model.filter_modal_focus +%= 1`（u2 の wrapping add・3→0 は自走・codex m2）。`% 4` は u2 へ fit しない comptime int となりコンパイルエラーなので使わない。
- `return .none`。

**`handleFilterFocusPrev(model)`**:
- `model.filter_modal_focus = if (model.filter_modal_focus == 0) 3 else model.filter_modal_focus - 1`（wrap around・u2 の減算は 0→3 を wrapping しないため明示分岐）。
- `return .none`。

> ★モーダル中のみ有効（input.zig が保証）。フォーカス index 変化は main が検知して各 TextInput の `focus()`/`blur()` を同期（§9.3）。

### 4.4 `open_filter_modal` / `close_filter_modal` arms（phase 3a とほぼ同一）

**`handleOpenFilterModal(model)`**:
- `model.filter_modal_open = true`。
- `model.filter_modal_focus = 0`（★新規: 開く度に author 欄へフォーカス・デフォルト）。
- `return .none`。
- ★差分: main が 4つの TextInput へ現 FilterSpec.conditions から各 variant を lookup して `setValue`（§9.3）。

**`handleCloseFilterModal(model)`**:
- `model.filter_modal_open = false`。TextInput の内容は破棄（次回 open 時に現 FilterSpec から再プレフィル）。
- `return .none`。

### 4.5 `handleLogLoaded` / `handleLogPageLoaded` / `handleLogLoadFailed`（phase 3a と同一）

phase 3a 仕様を維持（B1/B2/M-N8 等）。FilterSpec の内部が conditions リストへ変わるだけで、reducer は `graph_render_policy==.suppressed` の graph スキップ・`log_snapshot_tip` 照合等は変わらず。差分なし。

### 4.6 `buildLoadLogCmd` builder（phase 3a と同一）

`model.filter_state.clone(a)` → `.load_log` 構築。全 `load_log` 発火 site（`handleToggleViewMode`/`handleRequestRefreshLog`/`clear_filter`/bad revision recovery）で filter 伝播漏れ無し（M5）。

### 4.7 `git_error`（log 中・detail 系のみ）（phase 3a M-N9 最小対処と同一）

差分なし。

---

## 5. argv 生成（`src/git/commands.zig`）

### 5.1 `appendFilterOptions` / `appendPaths` プライベートヘルパ（★codex M2 で2関数へ分割）

★`logArgv` は options 系（`--author`/`--since`/`--until`）を revision（`<snapshot_tip>`）の**前**に・paths（`-- path...`）を revision の**後**へ置く必要がある（git 構文 `git log [options] [<revision>] [--] [<path>...]`）。単一 helper ではこの2挿入点を表現できないため、**2関数へ分割**する。

#### `appendFilterOptions(argv, owned, a, filter) !void`（revision 前・options 系）

1. `filter.isEmpty()` なら即 return。
2. **`--fixed-strings` の付与判定**: conditions を scan し `.author` が1つでもあれば `argv.append("--fixed-strings")`。★author 無ければ付けない（無意味・将来 grep 追加時は再検証）。
3. **conditions を variant 順に正規化ソート**（author → since → until）。paths はここでは扱わない。
4. 各 condition へ dispatch:
   - `.author => |text|`: `argv.append(try allocPrint("--author={s}", .{text}))`・`owned.append` で追跡。
   - `.since => |text|`: `parseDate(text) catch → error 伝播` → `formatGitDate(a, ds, false) → git_str` → `argv.append(try allocPrint("--since={s}", .{git_str}))`・`owned.append`。
   - `.until => |text|`: `parseDate(text) catch → error 伝播` → `formatGitDate(a, ds, is_until_date_only = (ds.hour == null)) → git_str` → `argv.append(try allocPrint("--until={s}", .{git_str}))`・`owned.append`。★日付のみ入力時は +1day で当日包含（§2.2）。
   - `.paths => {}`: ここでは無視（`appendPaths` で処理）。

#### `appendPaths(argv, owned, a, filter) !void`（revision 後・paths 系）

1. `filter` から `.paths` condition を lookup（accessor `getPaths()` で借用取得）。無ければ（空 slice）即 return。
2. `argv.append("--")`・`owned` には追跡しない（`"--"` は静的リテラル・free 不要）。
3. 各 path を append: `for (paths) |p| { const dup = try a.dupe(u8, p); try argv.append(dup); try owned.append(dup); }`。

> ★**2関数分割の理由**（codex M2）: revision 前後の2挿入点を表現するため。phase 3a は paths 無しだったので単一 helper で成立したが、phase 3b は paths 有り時に revision 後挿入が必要。`logArgv`/`logPageArgv` は `<snapshot_tip>` append の前後に分けてこの2関数を呼ぶ（§5.2）。

**所有権**: argv は `OwnedArgv`（persistent 所有・`deinit` で全 slice を free）。`allocPrint`/`dupe`/`formatGitDate` の結果は全て同じ allocator で確保し、`owned` リストへ追跡して所有権を一元化（`src/git/commands.zig:15-24` の既存パターン）。`appendFilterOptions`/`appendPaths` は `argv`/`owned` への `*std.ArrayList` 参照を受け取り、呼出側（`logArgv`）が構築中のリストへ追記する。

### 5.2 `logArgv` / `logPageArgv` のシグネチャ（phase 3a と同一・内部構造変更）

| 関数 | phase 3a シグネチャ | phase 3b 変更 |
|---|---|---|
| `logArgv(a, skip, max_count, snapshot_tip, filter) !OwnedArgv` | 変更無し | 内部の author 展開（`src/git/commands.zig:103-108`）を `appendFilterOptions` + `appendPaths` の2呼び出しへ置換 |
| `logPageArgv(a, skip, max_count, snapshot_tip, filter) !OwnedArgv` | 変更無し | 同上（`logArgv` へ転送なので自動追従） |

**`logArgv` 内部の argv 構築順序**（★codex M2・2挿入点を明示）:

1. `git -c core.quotePath=false log --topo-order` を append。
2. `--skip=N`（skip > 0 のみ）・`--max-count=M` を append。
3. **`appendFilterOptions(argv, owned, a, filter)`**（revision 前・author/since/until）。
4. `--pretty=format:... -z --decorate=short --no-color` を append。
5. `<snapshot_tip>` を append（revision）。
6. **`appendPaths(argv, owned, a, filter)`**（revision 後・`-- path...`）。

**argv 構造**（paths 無し・phase 3a 互換）:
```
git -c core.quotePath=false log --topo-order [--skip=N] --max-count=M
    [--fixed-strings --author=foo] [--since=...] [--until=...]
    --pretty=format:... -z --decorate=short --no-color <snapshot_tip>
```

**argv 構造**（paths 有り・phase 3b 新規）:
```
git -c core.quotePath=false log --topo-order [--skip=N] --max-count=M
    [--fixed-strings --author=foo] [--since=...] [--until=...]
    --pretty=format:... -z --decorate=short --no-color <snapshot_tip>
    -- path1 path2 ...
```

> ★**paths は revision（snapshot_tip）の後に `--` と共に置く**（git 構文準拠）。phase 3a は paths 無しだったので `snapshot_tip` が最後だったが、phase 3b では paths 有り時に限り `--` + paths が末尾に追加される。
>
> ★**phase 3a 回帰テストについて**（codex M2）: §13.3 の author-only 回帰テストは argv の**存在**（`--fixed-strings`/`--author=foo` を含む）を検証する。phase 3a の位置（`--max-count` と `--pretty` の間）も維持されるため、現状の presence-only テスト（`src/git/commands.zig:425-440`）は通る。paths 無し時は `snapshot_tip` が末尾のまま（phase 3a と同一）。

### 5.3 argv 生成時のエラー処理

- `parseDate` 失敗: apply 時に検証済みなので理論上起きないが、安全側として `error.InvalidDateFormat` を `appcmd.runLogInt` へ伝播 → 既存の `LogLoadFailed`/`LogPageFailed` 正規化パスへ（phase 3a §6 と同型）。
- OOM: 同様に `LogLoadFailed`/`LogPageFailed` へ正規化。
- `formatGitDate` の +1day 計算失敗: 起き得ない（パース済み DateSpec への算術演算のみ）。

### 5.4 既存 `--topo-order` / `--skip` / `--max-count` / `<snapshot_tip>`（phase 2/3a と同一）

paging ロジックは不変。

---

## 6. appcmd（`src/appcmd.zig`・phase 3a と同一）

`runLogInt`/`runLogPageInt` は `logArgv`/`logPageArgv` へ filter を渡すだけなので、内部の FilterSpec 構造変更を自動追従。差分なし。

---

## 7. input（`src/input.zig`）

### 7.0 `input.Key` 抽象の拡張（★codex M1・前提）

現状 `input.Key` union（`src/input.zig:27-38`）は `char/enter/backspace/tab/escape/ctrl_s/ctrl_d/ctrl_u/down/up` のみで modifiers を持たない。`zz.KeyEvent`（api-notes L207-214）は `key: zz.Key` + `modifiers: { shift, ctrl, alt, ... }` を持つが、`fromZigzagKey`（`src/input.zig`）は `.tab → .tab` へ正規化し shift 情報を捨てるため、tab と shift+tab が区別不能。

**phase 3b の拡張**:

1. `input.Key` union へ `shift_tab` variant を追加。
2. `fromZigzagKey(k: zz.KeyEvent)` へ `k.key == .tab` の分岐を追加:
   - `k.modifiers.shift == true` → `.shift_tab`
   - それ以外 → `.tab`
   - ★api-notes（`docs/superpowers/plans/zigzag-api-notes.md` L207-214）の `zz.Key` union に `backtab` variant は無く、Shift+Tab は `KeyEvent{ .key = .tab, .modifiers = .{ .shift = true } }` として届く（実 API 確認済み・codex M1）。
3. 既存の `.tab` を処理する箇所（changes モードの `focus_next` 等）は、`.tab`/`.shift_tab` の両方を switch で明示的に扱う（網羅的 switch によりコンパイラが新 variant を強制）。

### 7.1 `keyToMsgForModeWithModal` の拡張（phase 3a + Tab/Shift+Tab）

phase 3a の `keyToMsgForModeWithModal`（`src/input.zig:170-184`・`keyToMsgForMode` の前に配置・M6）へ追加分:

- モーダル中:
  - `.tab` → `Msg.filter_focus_next`（★phase 3a は null で抑止していたが、phase 3b はフォーカス移動へ有効化）。
  - `.shift_tab` → `Msg.filter_focus_prev`（★§7.0 で追加した variant）。
  - `.enter` → `null`（main が4欄から ApplyFilter を構築・phase 3a と同じ）。
  - `.escape` → `Msg.close_filter_modal`（phase 3a と同じ）。
  - その他 → `null`（main が focus index の TextInput.handleKey へ委譲）。
- モーダル中は phase 3a と同じく `q`/`r`/`L`/mouse 抑止（main の `handleMouse` が `filter_modal_open` で return）。

---

## 8. view（`src/view.zig`）

### 8.1 `renderLogMode` のモーダル分岐拡張（phase 3a の4入力欄化）

phase 3a のモーダル描画（`viewWithBackdrop` 全面置換・`src/view.zig:721-731`）を、4入力欄へ拡張:

1. モーダルの body 文字列を4行で構築（`ctx.allocator` = フレーム arena・free 不要）:
   ```
   Author: <author_input の表示>
   Since:  <since_input の表示>
   Until:  <until_input の表示>
   Path:   <path_input の表示>
   ```
2. **フォーカス中の欄**: 該当 TextInput の `view(arena)` 結果を使う（cursor 位置に reverse ハイライト・編集中の見た目）。
3. **フォーカス外の欄**: 該当 TextInput の `getValue()` を静的に表示（reverse 無し・read-only 風）。これにより「フォーカスが1欄に限定」が視覚的に明確。
4. `model.filter_modal_focus` を見て分岐（どの欄を `view()` し、どれを `getValue()` で静的表示するか）。
5. モーダルの title: `"Filter commits"`（phase 3a の `"Filter by author"` から拡張）。footer: `"Tab: next  Shift+Tab: prev  Enter: apply  Esc: cancel"`（phase 3a の footer を拡張）。
6. ★モーダル表示中は base view を返さず `viewWithBackdrop` を返す（phase 3a m-N5 と同じ）。

### 8.2 フィルタ中の graph 非表示理由（phase 3a 拡張）

phase 3a は `Filter: author="..." (graph hidden)`（`src/view.zig:503`）を表示。phase 3b は conditions の内容に応じて理由文字列を構築:

- author のみ: `Filter: author="..." (graph hidden)`
- since/until のみ: `Filter: since=... until=... (graph hidden)`
- paths のみ: `Filter: paths=... (graph hidden)`
- 複合: 主要条件を列挙（長すぎる場合は truncate）。

> 詳細な文字列フォーマットは実装で詰めるが、「どの filter が有効か」をユーザへ伝えることが目的。

---

## 9. main（`src/main.zig`）

### 9.1 `App` 構造体の変更（4入力欄化）

phase 3a の `filter_textinput: zz.TextInput`（1つ・`src/main.zig:101`）を **4つへ分割**:

| field | placeholder | char_limit |
|---|---|---|
| `filter_author_input: zz.TextInput` | `"name or email"` | `max_author_runes = 256` |
| `filter_since_input: zz.TextInput` | `"YYYY-MM-DD"` | `max_date_runes = 16` |
| `filter_until_input: zz.TextInput` | `"YYYY-MM-DD"` | `max_date_runes = 16` |
| `filter_path_input: zz.TextInput` | `"path (space separated)"` | `max_path_runes = 1024` |

各 `init(persistent_allocator)` / `deinit()` / `setPlaceholder` / `setCharLimit`（`src/main.zig:269-276` の `filter_textinput` 初期化を4つへ拡張）。`filter_modal` は phase 3a と同一（title/body のみ更新）。

> ★**path placeholder の工夫**（codex n2）: 空白区切り複数パス可（§2.3）のため、placeholder に `"src/ *.zig"` 等の空白を含む例を置くと「2パス例」と誤解されやすい。`"path (space separated)"` のように注記付きで単数形にする。

### 9.2 `handleModalKey` の拡張（ApplyFilter payload 構築・Tab/Shift+Tab）

phase 3a の `handleModalKey`（`src/main.zig:413-438`）を拡張:

1. `keyToMsgForModeWithModal` を呼ぶ（input.zig）。
2. Msg が `filter_focus_next`/`filter_focus_prev`/`close_filter_modal` の場合 → `step(app, program, msg)` へ渡す（reducer が処理）。
3. Msg が `null` の場合:
   - `.enter` 押下時: 4つの `TextInput.getValue()` から `ApplyFilter` payload を構築 → `Msg.apply_filter` を生成して `step()` へ。
     - ★**構築中の rollback**（codex m4）: `var af = ApplyFilter{ .author = null, .since = null, .until = null, .paths = &.{} };` で初期化し、各欄の dupe を順次試行。OOM 時は `af.deinit(gpa)` で部分確保済みフィールドを解放してモーダル維持（`setLogLoadError("フィルタ適用に失敗（メモリ不足）")`）。★`ApplyFilter` に `deinit(a)` メソッドを新設（`Msg.deinit` の `.apply_filter` arm と同じ解放ロジック・`src/messages.zig:150` の arm をメソッドへ切り出す形）。
     - author/since/until: 空文字なら `null`、非空なら `gpa.dupe(u8, value)`。
     - paths: 空文字なら `gpa.alloc([]u8, 0)`（★空 slice も free 対象・`&.{}` 静的空配列は free でクラッシュするので必ず alloc）、非空なら `gpa.alloc([]u8, 1)` へ `gpa.dupe(u8, value)` を格納（欄全体を1要素 slice・reducer が parsePaths で split）。
     - OOM 時: モーダル維持して `setLogLoadError("フィルタ適用に失敗（メモリ不足）")`（phase 3a と同じ・`src/main.zig:425-429`）。
   - `.escape` は input.zig で Msg 化済み。
   - それ以外（文字/BS/矢印等）: `model.filter_modal_focus` に応じた TextInput の `handleKey(key)` へ委譲。

### 9.3 `syncFilterModal` の拡張（4欄プレフィル・フォーカス同期）

phase 3a の `syncFilterModal`（`src/main.zig:361-379`）を拡張:

1. **`filter_modal_open` の false→true 遷移検知**: 4つの TextInput へ現 `FilterSpec.conditions` から variant 別 accessor（§1.1）で値を取得して `setValue`:
   - `filter_author_input.setValue(spec.getAuthor() orelse "")`
   - `filter_since_input.setValue(spec.getSince() orelse "")`
   - `filter_until_input.setValue(spec.getUntil() orelse "")`
   - `filter_path_input.setValue(paths_to_string(a, spec.getPaths()) catch "")`（accessor `getPaths()` が `[]const []const u8` を返す・空 slice なら `paths_to_string` は空文字を返す・§1.2）。
   - `filter_modal.show()`。
   - ★accessor は借用（`?[]const u8` / `[]const []const u8`）を返すので、`setValue`（内部で dup）に渡した後は触らない（codex m3・union 値返しの所有権曖昧さを排除）。
2. **`filter_modal_open` の true→false 遷移検知**: `filter_modal.hide()`。
3. **`filter_modal_focus` の変化検知**（毎フレーム）: focus index に応じ、該当 TextInput のみ `focus()`、他を `blur()`。
4. **毎フレーム modal.body へ4行構築**（`ctx.allocator` arena）:
   - `filter_modal_focus` を見て、フォーカス中欄は `view(arena)`、他は `getValue()` で静的表示。
   - 4行を `\n` で join して `modal.body` へ設定。
   - `viewmod.g_view_modal = &app.filter_modal`（phase 3a と同じ）。

> `paths_to_string` の定義は §1.2 参照（accessor `getPaths()` から文字列化・往復対称性テストも §13.1）。

### 9.4 `handleMouse`（phase 3a と同一）

`filter_modal_open` 時は背面 pane への routing をスキップ（`src/main.zig:443`）。モーダル外クリックは無視。差分なし。

---

## 13. テスト計画（TDD・実装と同じ `.zig` 内の `test {}` ブロック）

### 13.1 `filter.zig` の新規テスト

**`parseDate`**:
- 正常系: `2026-06-22`（日付のみ・hour/minute null）・`2026-06-22 09:30`（HH:MM）。
- 異常系: `2026-13-01`（月範囲外）・`2026-02-30`（日範囲外）・`2026-06-22 25:00`（時範囲外）・`2025-02-29`（平年うるう日違反）・`2024-02-29`（うるう年 OK）・`2026/06/22`（区切り違反）・`2026-6-1`（ゼロ埋め無し）・空文字・`2026-06-22 09`（HH のみ）。

**`formatGitDate`**:
- since 日付のみ: `2026-06-22 00:00:00`。
- since HH:MM: `2026-06-22 09:30:00`。
- until 日付のみ（+1day）: `2026-06-23 00:00:00`。
- until HH:MM（そのまま）: `2026-06-22 09:30:00`。
- **+1day 境界**: 1/31→2/1、2/28→3/1（平年）、2024-02-28→02-29（うるう年）、12/31→1/1（年跨ぎ）。

**`daysInMonth` / `addOneDay`**: 各月の日数・うるう年・月末/年末境界。

**`parsePaths`**:
- 単一パス `src/`。
- 複数パス `src/ test/`。
- quote `"my dir/file"` → `my dir/file`。
- エスケープ `src/\ *.zig`（空白エスケープ）→ `src/ *.zig`。
- 連続空白スキップ。
- 要素数上限（17 個で `TooManyPaths`）。
- 要素長上限（4097 バイトで `PathTooLong`）。
- 空文字入力 → 空 slice。
- ★**未閉じ quote**（codex m5）: `"my dir`（閉じ `"` 無し）→ `error.UnterminatedQuote`。

**`paths_to_string`**（★codex M4・§1.2 新設）:
- 単一パス → `src/`。
- 複数パス → `src/ test/`。
- 空白含むパス → `"my dir/file"`（quote で囲む）。
- quote/`\` 含むパス → `"a\"b"`（エスケープ）。
- 空リスト → 空文字。
- ★**`parsePaths` との往復対称性**（codex M4）: `paths_to_string(parsePaths(s))` が正規化された s に等しいこと（`src/`・`"my dir/file"`・`a\"b` 等の多様な入力で検証）。モーダル再オープン時のプレフィル整合性を担保。

**`FilterSpec` API（再構築後）**:
- `init`/`isEmpty`/`addCondition`/`removeVariant`/`clone`/`deinit`/`eql`・variant 別 accessor（`getAuthor`/`getSince`/`getUntil`/`getPaths`）。
- 各 variant の所有権・deep-copy。
- ★**`addCondition` 重複上書き**（codex m1）: 同 variant を2回 addCondition すると後勝ち（旧 deinit・新へ置換）・conditions.items.len は増えない。
- ★**`addCondition` OOM 時 payload 自動 deinit**（codex M3）: append realloc 失敗時、引数の payload が leak しない（`checkAllAllocationFailures` で各 variant の addCondition OOM を検証）。
- OOM（`checkAllAllocationFailures` は OOM を伝播する helper のみ）。
- 既存 phase 3a テスト（author-only）を新 API（`addCondition(.{ .author = ... })`/`getAuthor()`）へ書き換え・同じ挙動を検証。

### 13.2 `update.zig` のテスト

- `apply_filter` 正常系: author-only/since-only/until-only/paths-only/全組み合わせ・各条件が `FilterSpec.conditions` へ正しく格納。
- `apply_filter` バリデーション: `AuthorTooLong`/`InvalidDateFormat`（since/until）/`TooManyPaths`/`PathTooLong` → `log_load_error` へ正しいメッセージ・Model 不変・モーダル閉じず（`filter_modal_open` true のまま）。
- `apply_filter` トランザクション: OOM 時の Model 不変（`clearFilterState` で強例外保証）。
- ★**`apply_filter` payload leak テスト**（codex M3）: author addCondition 成功後・paths addCondition が OOM する順序で、parsed_paths が leak しない（addCondition が OOM 時 payload を自動 deinit・`checkAllAllocationFailures` で各 addCondition の OOM 点を検証・`std.testing.allocator` が leak を検出）。
- `apply_filter` → `load_log` 発火: filter clone が AppCmd へ移譲・Model.filter_state と一致。
- `clear_filter`: 全 condition クリア・`graph_render_policy=.auto` 復活・buildLoadLogCmd 経由。
- `filter_focus_next`/`filter_focus_prev`: wrap around（3→0, 0→3）・モーダル中のみ有効（input 側で保証・reducer は無条件で wrap）。
- `open_filter_modal`: `filter_modal_focus = 0` へリセット。
- 既存 phase 3a テストの回帰: author-only ApplyFilter で同じ挙動（`ApplyFilter{ .author = "foo", .since = null, .until = null, .paths = &.{} }` へ書き換え）。

### 13.3 `git/commands.zig` のテスト

- `appendFilterArgs`（logArgv/logPageArgv 経由で検証）:
  - author-only → `--fixed-strings --author=foo`（phase 3a 回帰）。
  - since-only → `--since=2026-06-01 00:00:00`。
  - until-only（日付のみ）→ `--until=2026-06-02 00:00:00`（+1day）。
  - until-only（HH:MM）→ `--until=2026-06-01 12:00:00`（そのまま）。
  - paths-only → 末尾に `-- src/ test/`（snapshot_tip の後）。
  - 全組み合わせ → variant 順ソートの冪等性。
  - `--fixed-strings` 付与判定（author 無ければ付かない・since/until/paths のみなら付かない）。
  - paths の位置（`--` は snapshot_tip の後）。
- 既存 phase 3a テストの回帰（author-only で同 argv）。

### 13.4 `model.zig` のテスト

- `filter_modal_focus` のデフォルト 0・`init`/`deinit` でリーク無し。
- `setFilterState`/`clearFilterState` が conditions リスト版 FilterSpec で動作。

### 13.5 `input.zig` のテスト

- **`input.Key` への `shift_tab` variant**（★codex M1・§7.0）: `fromZigzagKey(KeyEvent{ .key = .tab, .modifiers = .{ .shift = true } })` → `.shift_tab`・`fromZigzagKey(KeyEvent{ .key = .tab, .modifiers = .{} })` → `.tab`。修飾キー無しの `.tab` が従来どおり changes モード等の `focus_next` へマップされる回帰。
- `keyToMsgForModeWithModal`: モーダル中 `.tab` → `filter_focus_next`・`.shift_tab` → `filter_focus_prev`・`.enter` → null・`.escape` → `close_filter_modal`・他 → null。
- phase 3a 回帰: モーダル中 `q`/`r`/`L` 抑止。

### 13.6 `messages.zig` のテスト

- `Msg.apply_filter` deinit: `ApplyFilter` の各フィールド（author/since/until/paths）が正しく free される。
- `Msg.filter_focus_next`/`filter_focus_prev` deinit は no-op。
- ★**`ApplyFilter.deinit` メソッド**（codex m4・§9.2）: `Msg.deinit` の `.apply_filter` arm と同じ解放ロジックをメソッドへ切り出し・main の構築中 rollback からも呼べる。空 `paths`（`alloc([]u8, 0)`）の free も含む。

### 13.7 UI 層は tmux pty 検証（手動）

- `f` → モーダル4欄表示・プレフィル確認（現 filter が各欄へ反映）。
- Tab/Shift+Tab でフォーカス移動・reverse ハイライト追従。
- 各欄へ入力 → Enter → filter 適用・graph 非表示・理由表示（`Filter: ... (graph hidden)`）。
- `F` → clear・graph 復活。
- バリデーションエラー時のメッセージ表示・モーダル閉じず。
- 日本語 author/パス（UTF-8）。
- since/until の日付のみと HH:MM の境界動作（実 git で検証）。
- 複数パス（`src/ test/`）・quote 含むパス（`"my dir/file"`）。
- ★**TZ 挙動は手動検証専用**（codex m6）: TZ は環境変数依存で unit test から制御困難。CI では検出できないため、§2.1 の TZ 変動リスクを README のキーマップ/フィルタ説明へ注意書きとして要求する（「フィルタの日付は環境 TZ（通常 JST）で解釈・CI/SSH 等で TZ が変わると結果が変わる可能性」）。unit test スコープ外を明示。

---

## 16. phase 3b 残（他タスク・別 spec）

本 spec は「日付範囲 + パス」のみ。phase 3b の残タスク:

- [ ] **ブランチフィルタ（`--branches`）**: snapshot_tip との和集合問題（B3）の解決が前提。単一 branch は hash 解決して snapshot_tip へ・複数 branch は所有集合。spec §16/B3。
- [ ] **フィルタ中の graph 維持**: `graph.zig` の nearest-visible-parent 投影 or Git history simplification。phase 3b も一律 suppressed で回避。M1/M2/B2。
- [ ] **StreamTooLong の limit 注入 seam**: テスト容易化・`git/process.zig`・spec §6.3。phase 3a は catch で LogLoadFailed/LogPageFailed へ正規化のみ。
- [ ] **busy lifecycle 完全修正**: runtime lifecycle のみで busy 管理・reducer で busy を触らない。M-N9。phase 3a は log 中 git_error 無視で最小対処。

> `FilterCondition` union 化（アプローチ B）は、これら将来タスクで variant 追加（`.branch`/`.grep` 等）を容易にする。

---

## 17. Risks

- **モーダル4欄のフォーカス管理複雑化**: phase 3a の1欄から4欄へ。`filter_modal_focus` の Model 管理と main の `focus()`/`blur()` 同期がずれると、reverse ハイライトがフォーカスと不一致になる。毎フレーム同期（§9.3 step 3）で担保・tmux pty 検証で確認。
- **paths 再エスケープの変換ロス**: `[][]u8` → 空白区切り文字列（モーダルプレフィル用）→ 再 split の往復で、エスケープが非対称だと文字列が変わる。`paths_to_string` と `parsePaths` の往復テストで対称性を担保。
- **2回パースの冗長性**: apply 時のバリデーションと argv 生成時のパース。各ヘルパが単一責任でテスト容易だが、実行時オーバーヘッド（無視できる程度・filter 適用はユーザ操作起点）。
- **argv 生成時の parseDate 失敗**: apply 時検証済みだが、安全側として LogLoadFailed/LogPageFailed へ正規化（§5.3）。
- **TZ 変動リスク**: CI/SSH/cron 等で TZ が変わると同じ入力で結果が変わる（§2.1）。spec/README へ明記。
- **`--fixed-strings` と将来 grep の相互作用**: phase 3b は author のみなので問題ない。grep 追加時は `--fixed-strings` が grep にも影響するため再検証（phase 3a と同じ注意）。

---

## 18. 将来課題

- **オーバーレイ compositor**: base view を透けて見せる・m-N5。
- **filter のファイル永続化**: アプリ再起動跨ぎ。
- **filter 履歴（suggestions）**: `TextInput.setSuggestions`。
- **case-insensitive author**: `--regexp-ignore-case` 追加。
- **`--grep`/`--invert-grep`**: FilterCondition へ variant 追加で対応可能（アプローチ B の利点）。
- **`**` glob サポート**: `:(glob)` magic prefix。
- **busy lifecycle 完全修正**: M-N9。

---

## 19. Open product decisions（ユーザー承認済み・覆可能）

| ID | 判断 | 根拠 |
|---|---|---|
| **D1** | 対象: 日付範囲 + パス（ブランチ/graph/StreamTooLong/busy は別 spec） | ユーザーブレインストーミング（複数選択） |
| **D2** | UI: 複数入力欄の単一モーダル（4欄・Tab 移動） | ユーザーブレインストーミング（推奨選択） |
| **D3** | timezone: ローカル TZ（環境 TZ・ユーザー修正で UTC から変更） | ユーザーブレインストーミング（dismiss → 修正指示） |
| **D4** | フォーマット: YYYY-MM-DD と YYYY-MM-DD HH:MM 両方 | ユーザーブレインストーミング |
| **D5** | 境界: HH:MM 指定で until 排他・日付のみで当日包含（+1day） | ユーザーブレインストーミング |
| **D6** | pathspec: git デフォルト・複数パス可（空白区切り） | ユーザーブレインストーミング |
| **D7** | アプローチ: FilterCondition union リスト（B・拡張性優先） | ユーザーブレインストーミング（推奨 A を覆し B 選択） |
| **D8** | バリデーション失敗時: モーダル閉じず（ユーザが修正して再試行） | phase 3a と整合 |
| **D9** | FilterSpec: ユーザ入力生文字列保持・apply 時と argv 生成時の2回パース | テスト容易性・単一責任 |
| **D10** | paths parse: reducer 側で実行（main は dupe のみ） | テスト容易性 |
| **D11** | graph policy: filter 1つでもあれば suppressed（since/until のみも抑制） | phase 3a 方針踏襲・安全側 |
| **D12** | フォーカス index: Model 側（`filter_modal_focus: u2`）で管理 | input.zig の unit test カバー |
| **D13** | フォーカス外欄: getValue() 静的表示（reverse 無し） | フォーカス限定の視覚的明確化 |
