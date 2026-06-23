# StreamTooLong limit 注入 seam 設計 — TODO 2 / phase 3b 残

- 日付: 2026-06-23
- 対象: `TODO.md`「TODO 2 phase 3b 残」の **StreamTooLong の limit 注入 seam（テスト容易化）**。
  log 系経路（`runLogInt`/`runLogPageInt`）の `error.StreamTooLong` → `LogLoadFailed`/`LogPageFailed` 正規化が
  **正しいことをテスト可能にする**インフラ。16MiB の実 git 出力を作らず、小さな limit で StreamTooLong を再現する。
- 親設計:
  - `docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md`（rev.3・§6.3 で本 seam を「推奨」と記載）
  - `docs/superpowers/specs/2026-06-22-todo2-log-view-phase3b-date-path-filter-design.md`（rev.2・スコープ外として明記）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（**zigzag/std の実 API はこれが正**）。
- スコープ外（phase 3b 残・別 spec）: ブランチフィルタ / フィルタ中の graph 維持 / busy lifecycle 完全修正。

> **記述方針**: phase 3a/3b spec に倣い、(a) シグネチャは field/引数定義のみ、(b) 方針・判断根拠・注意点を dense に。
> compile 可能な Zig block は書かない。所有権ライフサイクル等の実装詳細は writing-plans / 実装フェーズへ委ねる。

---

## Status

**Draft for user spec-review**。ブレインストーミングで対象（#3）・アプローチ（A）・各論まで合意済み。
codex 独立レビュー済み（**READY**・BLOCKER 0 / MINOR 2 / NIT 2 を全反映）。主な反映:
StreamTooLong 前提を Zig 0.16 std ソースで実証（§6・truncate せず error・strict `>`）/ MINOR-1（直接呼びテストの payload 明示 deinit・特に `LoadLogPage.tip_hash`・§4.2）/
MINOR-2（1 コミット必須理由＝head 解決通過・§4.2）/ NIT-2（`default_stream_limit` 非対称適用コメント・§1.1）。
user 承認後、writing-plans へ移行する。

---

## Goal

`std.process.run` の出力 limit（現状 stdout/stderr とも `.limited(16MiB)` をハードコード）を、
**log 実行経路に限り**注入可能にする。これにより:

1. **テスト容易化**: `runLogInt`/`runLogPageInt` を小さな `stdout_limit`（例 `.limited(8)`）で直接呼び、
   `error.StreamTooLong` を再現 → `LogLoadFailed`/`LogPageFailed` への正規化が機能することを検証する。
2. **挙動不変**: 本番経路（dispatcher 経由）は既定の 16MiB を渡すため、ユーザー体験・他の git 実行は一切変わらない。

完了後、`TODO.md` phase 3b 残の「StreamTooLong の limit 注入 seam」をチェック。

---

## Background

### 現状（実コードから検証済みの事実）

| 項目 | 事実 | 出典 |
|---|---|---|
| limit ハードコード | `process.run` が stdout/stderr とも `.stdout_limit = .limited(16*1024*1024)` を直書き | `src/git/process.zig:34-39` |
| RunError | `pub const RunError = std.process.RunError;`（`error.StreamTooLong` を含む） | `src/git/process.zig:12` |
| log 実行点 | `git log` の実行は appcmd 内の `process.run(a, io, argv.args, cwd)` 2 箇所 | `src/appcmd.zig:186`（`runLogInt`）, `:264`（`runLogPageInt`） |
| 正規化（既存） | 上記 2 箇所は `process.run(...) catch return mkLoadFailedOrSilent/mkPageFailedOrSilent...` で `RunError` 全体（StreamTooLong 含む）を typed failure へ正規化 | `src/appcmd.zig:186-187`, `:264-265` |
| 内部 git 呼び出し | `runLogInt` は本体 log 実行の前に rev-parse HEAD / head-state 解決を行う（小出力） | `src/git/commands.zig:249,262,283`（`revParseHead`/`headState` 等） |
| dispatcher | `run()` の `.load_log`/`.load_log_page` arm が `runLogInt`/`runLogPageInt` を呼ぶ | `src/appcmd.zig:108-109` |
| Msg 解放 | `Msg.deinit` が `log_load_failed.error_text`/`log_page_failed.error_text` を free | `src/messages.zig:124,147,149` |
| テストハーネス | `TmpRepo`（init/writeFile/git/cwd/deinit）が appcmd テストで利用可能 | `src/appcmd.zig:318-340` |

### 問題

phase 3a §6.3（MINOR7）で、`std.process.run` の 16MiB 制限による `error.StreamTooLong` は
`runLogInt`/`runLogPageInt` の catch 範囲で**自然に正規化される**ことが設計上の前提とされた。
しかし **16MiB の実 git 出力を作るのは重すぎ**、この正規化経路が回帰なく機能し続けることをテストできない。
phase 3a §6.3 / §14 / §15 はその対策として **limit 注入設計**を「推奨」と明記している（本 spec はその実装）。

---

## Approach（合意済み: A）

ブレインストーミングで以下を比較し、**A** を採用:

| 案 | 内容 | 評価 |
|---|---|---|
| **A（採用）** | `process.zig` に `default_stream_limit` 定数 + `runWithLimit(.., stdout_limit)` を新設。`run` は既定値で委譲する薄いラッパへ。`runLogInt`/`runLogPageInt` に `log_limit` 引数を追加し、**log 実行 1 箇所ずつ**を `runWithLimit` へ。dispatcher は `default_stream_limit` を渡す。 | グローバル可変状態なし・log 以外の呼び出し（commands.zig の rev-parse 等含む）無改変・スレッド安全・idiomatic。 |
| B | `process.zig` にモジュール `var` を置きテストで上書き。 | 差分最小だが可変グローバル・非スレッド安全・テスト汚染。**却下**。 |
| C | `process.run` 全体に limit 引数を追加し全呼び出しを変更。 | 最も明示的だが、既定で十分な多数の箇所まで churn。**却下**。 |

採用理由: seam を「log 実行経路のみ」に限定でき、他の git 実行（commands.zig の小出力ヘルパ）の挙動を一切変えず、
可変グローバルも避けられる。

---

## 1. `src/git/process.zig` の変更

### 1.1 定数

- 追加: `pub const default_stream_limit: std.Io.Limit = .limited(16 * 1024 * 1024);`
  - 現状の直書き `16 * 1024 * 1024` を単一の定数へ集約（マジックナンバー除去・dispatcher から参照）。
  - コメント要求（NIT-2）: 「`run` では stdout/stderr 両方へ適用。`runWithLimit` では stderr のみへ適用（stdout は注入引数）」を定数定義箇所に明記し、`runWithLimit` が stderr も bound すると誤読されないようにする。

### 1.2 `runWithLimit`

- 新設: `pub fn runWithLimit(allocator, io, argv: []const []const u8, cwd: Cwd, stdout_limit: std.Io.Limit) RunError!RunResult`
  - 本体は現 `run` と同一。`std.process.run` の opts を `.stdout_limit = stdout_limit`、`.stderr_limit = default_stream_limit` とする。
  - **stdout_limit のみ注入**する（git log 成功出力は stdout に来るため。stderr は git のエラー文で小さく、常に既定 16MiB で十分）。引数名を `stdout_limit` とし対象を明示。
  - exit code 正規化（`.exited => c` / `else => 255`）は現 `run` と同一。

### 1.3 `run`（後方互換ラッパ）

- 変更: `pub fn run(allocator, io, argv, cwd) RunError!RunResult` の本体を
  `return runWithLimit(allocator, io, argv, cwd, default_stream_limit);` へ。
  - シグネチャ不変 → 既存呼び出し（appcmd の非 log 経路・commands.zig 全箇所）と既存テストは無改変。

---

## 2. `src/appcmd.zig` の変更

### 2.1 `runLogInt`

- シグネチャ: `fn runLogInt(a, io, cwd, cmd: AppCmd.LoadLog, log_limit: std.Io.Limit) !Msg`（末尾に `log_limit` 追加）。
- 変更点: `git log` 本体実行（`:186` の `process.run(a, io, argv.args, cwd)`）→ `process.runWithLimit(a, io, argv.args, cwd, log_limit)`。
  - catch 句（`catch return mkLoadFailedOrSilent(a, cmd, "git log 実行エラー", snapshot_tip)`）は**不変**。
    `RunError` は同一なので `StreamTooLong` も従来どおりこの catch に落ちる。
- **不変**: 関数前段の rev-parse HEAD / head-state 解決・git-dir 解決等は `process.run`（既定 limit）のまま。
  log 限定の seam なのでそれらは注入対象外（出力が小さく StreamTooLong は実質起きない）。

### 2.2 `runLogPageInt`

- シグネチャ: `fn runLogPageInt(a, io, cwd, cmd: AppCmd.LoadLogPage, log_limit: std.Io.Limit) !Msg`。
- 変更点: `:264` の `process.run(a, io, argv.args, cwd)` → `process.runWithLimit(.., log_limit)`。
  catch（`mkPageFailedOrSilentForPage(a, cmd, "git log 実行エラー")`）不変。bad revision 検出ロジック（`:268-289` 相当）も不変。

### 2.3 dispatcher（`run()`）

- `:108-109` の arm:
  - `.load_log => |c| return runLogInt(a, io, cwd, c, process.default_stream_limit),`
  - `.load_log_page => |c| return runLogPageInt(a, io, cwd, c, process.default_stream_limit),`
- 本番経路は既定 limit を渡す → ユーザー体験不変。

---

## 3. 所有権 / エラー経路

- seam は既存の正規化（`mkLoadFailedOrSilent`/`mkPageFailedOrSilentForPage`）を**再利用するだけ**で、新たな確保・解放を導入しない。
- 返り Msg（`log_load_failed`/`log_page_failed`）は `error_text: []u8` を所有。consumer（main・テスト）が `Msg.deinit(a)` で解放する既存規約のまま。
- OOM 極限（error_text 複製失敗）は既存 `mkLoadFailedSilent`/`mkPageFailedSilentForPage`（silent 版）へ落ちる経路を維持。

---

## 4. テスト（`src/git/process.zig` / `src/appcmd.zig` の `test {}` ブロック）

### 4.1 process.zig（単体）

- **`runWithLimit` が小 limit 超過で StreamTooLong**: `runWithLimit(a, io, &.{"echo", "hello"}, .inherit, .limited(2))`
  → `error.StreamTooLong` が返ること（`expectError`）を確認。
  - seam の前提（limit 超過 = truncate ではなく error）を固定する**回帰ガード**（§6 参照・Zig 0.16 std で実証済み）。
- **`run` 既定動作の回帰**: 既存 2 テスト（echo / false）はそのまま通る（`run` がラッパ化されても挙動同一）。

### 4.2 appcmd.zig（結合・TmpRepo）

- **`runLogInt` StreamTooLong → `log_load_failed`**: `TmpRepo` に **1 コミット作成（必須）** →
  `runLogInt(a, io, repo.cwd(), <LoadLog cmd>, .limited(16))` を呼ぶ。
  - **1 コミットが必須な理由（MINOR-2）**: `runLogInt` は本体 log 実行の**前に** head-state / rev-parse HEAD 解決を
    既定 limit で行う。unborn（コミット無し）リポジトリでは log 到達前に unborn 経路で返り、注入 limit に届かない。
    1 コミットあれば head 解決を通過し、注入 limit を使う `git log` 実行へ到達して StreamTooLong が発火する。
  - 期待: 返り Msg tag が `.log_load_failed`（出力が 16 byte 超 → StreamTooLong → 正規化）。
  - error_text が正規化 prefix「git log 実行エラー」を含むことを確認。
  - 返り Msg を `msg.deinit(a)` で解放（リーク検出）。
  - **cmd ペイロードの所有権（MINOR-1）**: 本テストは `runLogInt`/`runLogPageInt` への**初の直接呼び出し**で、
    既存テストの `runOwned`→`run`（dispatcher）経路の auto-`deinit`（`defer c.deinit(a)`）を**経由しない**。
    そのためテスト側で `var cmd = AppCmd.LoadLog{...}; defer cmd.deinit(a);` のように明示的に payload を解放する
    （「既存パターンに合わせる」ではなく明示 defer）。`LoadLog.filter` は空（`FilterSpec.init()` = 確保ゼロ）なので
    leak しないが、規約遵守のため明示する。
- **`runLogPageInt` StreamTooLong → `log_page_failed`**: 同様に小 limit で `.log_page_failed` を確認・`deinit`。
  - **★ownership 重要（MINOR-1）**: `LoadLogPage` は `tip_hash: []u8` を**所有**（`a.dupe` で構築する所有メモリ）。
    直接呼びは auto-deinit を経由しないため、テストは `var cmd = AppCmd.LoadLogPage{ .tip_hash = try a.dupe(...), ... }; defer cmd.deinit(a);`
    で必ず解放する。怠ると `std.testing.allocator` のリーク検出でテスト失敗。
- **既定 limit では成功**（任意・回帰）: `runLogInt(.., process.default_stream_limit)` が `.log_loaded` を返すことを 1 ケースで確認し、
  seam が本番経路を壊していないことを担保（既存の runLogInt 成功テストがあればそれで代替可）。

### 4.3 テスト設計の注意

- 小 limit は **0 より大きく、かつ git log 出力より小さい**値（git log は最小でも hash+メタで数十 byte）。`.limited(16)` で確実に超過。
- `echo "hello"`（6 byte）に対し `.limited(2)` で超過。limit 値は出力サイズより小さければよい。
- テストは `std.testing.allocator`（リーク検出）+ `std.testing.io`。

---

## 5. 影響範囲 / 非変更点

- **変更ファイル**: `src/git/process.zig`（定数 + 新関数 + ラッパ化 + テスト）、`src/appcmd.zig`（log 2 関数のシグネチャ + 実行点 + dispatcher 2 arm + テスト）。
- **非変更**: `src/git/commands.zig`（rev-parse/status/commit 等は `process.run` 既定 limit のまま）、`model.zig`/`update.zig`/`messages.zig`/`view.zig`/`input.zig`/`main.zig`（純粋層・UI 層は一切触れない）。
- **挙動不変**: 本番の全 git 実行は 16MiB 既定 limit のまま。seam はテストからのみ小 limit を渡す。

---

## 6. 留意点 / リスク

- ✅ **前提は実証済み（codex レビューで Zig 0.16 std ソース確認）**: `std.process.run` は `stdout_limit` 超過時に
  truncate せず `error.StreamTooLong` を**返す**（`lib/std/process.zig:520-528`・判定は strict `>`・`RunError` に含む `:454-456`）。
  - したがって §4.1 の `expectError(error.StreamTooLong, runWithLimit(.., .limited(2)))` は単なる前提確認ではなく、
    **将来の std 挙動変更を経験的に検知する回帰ガード**として機能する（この挙動が崩れたらこのテストが落ちる）。
  - 注意（strict `>`）: limit 値は出力サイズと**等しい**と発火しない。§4.3 の値（"hello" 6byte に `.limited(2)`、
    40 文字 hash を含む git log 行に `.limited(16)`）はいずれも出力より十分小さく確実に発火する。
- **stderr は注入対象外**: 本 seam は stdout のみ。将来 stderr 超過のテストが必要になれば別途引数追加（YAGNI で今回は対象外）。
- **root_test.zig**: process.zig は既に登録済み（既存テストあり）。新規モジュールではないため `_ = @import` の追加不要。
- **`TODO.md` 更新**: 実装完了時に phase 3b 残の「StreamTooLong の limit 注入 seam」チェックボックスを `[x]` へ更新。

---

## 7. 受け入れ基準

1. `process.runWithLimit` が新設され、`run` はそのラッパ（既定 `default_stream_limit`）になっている。
2. `runWithLimit` を小 limit で呼ぶと `error.StreamTooLong` が返る（process.zig 単体テストで実証）。
3. `runLogInt`/`runLogPageInt` が `log_limit` 引数を取り、log 実行のみ `runWithLimit` を使う。dispatcher は既定 limit を渡す。
4. 小 limit で `runLogInt`/`runLogPageInt` を呼ぶと `.log_load_failed`/`.log_page_failed`（prefix「git log 実行エラー」）へ正規化される（appcmd 結合テストで実証）。
5. 既存テスト全通過（`zig build test --summary all`）+ 本番挙動不変（既定 limit 経路）。
6. `TODO.md` の該当チェックボックス更新。
