# 部分ステージング（ハンク単位）設計 — TODO 1 / phase 1

- 日付: 2026-06-15
- 対象: `TODO.md` の「TODO 1. 部分ステージング（ハンク / 行単位）」のうち **ハンク単位**（phase 1）
- 親設計: `docs/superpowers/specs/2026-06-14-git-tui-design.md`
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（食い違う場合はノート優先）

## 1. ゴールとスコープ

JetBrains / lazygit と同様に、diff ペインで **ハンク（`@@ ... @@` 単位）** を選択し、その範囲だけを
stage / unstage できるようにする。

### スコープ（phase 1 で**やること**）

- tracked な変更（unstaged / staged）のハンク単位 stage / unstage。
- diff ペインに「ハンクカーソル」を置き、`j`/`k` で移動・`s`/`space`/`Enter` で適用。
- 選択中ハンクのハイライトと、選択ハンクが見えるよう diff の自動スクロール。
- diff ペインのクリックでハンク選択（マウスのハンクヒットテスト）。

### スコープ外（phase 1 で**やらないこと** / 将来）

- **行単位（複数行レンジ）選択**: ハンクヘッダの行数再計算と非選択行の context 変換が必要で
  複雑度が段違いのため phase 2 に分離（`TODO.md` の該当サブタスクとして残す）。
- **untracked のハンク stage**: index 未登録のため `git add -N`（intent-to-add）が前提になる。
  phase 1 では untracked は従来どおり `space`/`s` でファイル単位 stage のみ。
- ダブルクリックでのハンク stage（クリックでの選択までが phase 1。必要なら追補）。

## 2. 前提（裏取り済みの制約）

- **`std.process.run` の `RunOptions` に stdin フィールドは無い**（`argv` / `cwd` /
  `stdout_limit` / `stderr_limit` / `timeout` 等のみ。zig 0.16.0 の
  `lib/std/process.zig` を直接確認）。したがって `git apply --cached -`（stdin パイプ）は
  既存 `src/git/process.zig` の `run` では実現できない。
- → **一時ファイル経由**で `git apply --cached [--reverse] <tmpfile>` を使う。
  既存 `process.run` は**一切変更しない**。tmp 書き込みは既存テストの
  `dir.writeFile(io, ...)` と同じ io 経由パターンを使う。

## 3. アーキテクチャ（Elm 風 + 副作用隔離を踏襲）

```
diff_text (model 所有・persistent)
   │  hunk.parse(diff_text)                 ← 純粋・TDD
   ▼
ParsedDiff { file_header, hunks[]{ text, start_line, line_count } }
   │  view: hunks[selected_hunk] をハイライト＋自動スクロール
   │  input: ハンクカーソル移動 / クリックでハンク選択
   │  update: hunk.buildPatch(parsed, selected_hunk)  ← 純粋・TDD 最優先
   ▼
patch string ──(AppCmd.apply_patch{patch, reverse})──▶
   appcmd: tmpfile へ patch を書込 → git apply --cached [--reverse] <tmp>
          → 既存 execThenRefresh に乗せて status_loaded（→ diff 再読込は update が自動発行）
```

### 触るファイル

| ファイル | 変更 |
|---|---|
| `src/diff/hunk.zig` | **新規**: `Hunk` / `ParsedDiff` / `parse` / `buildPatch`（純粋・TDD） |
| `src/root_test.zig` | `_ = @import("diff/hunk.zig");` を有効化 |
| `src/model.zig` | `selected_hunk: usize` フィールド追加（init / 文書化） |
| `src/messages.zig` | `Msg`: `hunk_next` / `hunk_prev` / `stage_hunk`。`AppCmd`: `apply_patch`（+deinit） |
| `src/update.zig` | `hunk_next`/`hunk_prev`/`stage_hunk` 処理・`diff_loaded` で `selected_hunk=0` |
| `src/git/commands.zig` | `applyPatchArgv`（純粋・テスト） |
| `src/appcmd.zig` | `apply_patch` 解釈（tmp 書込 → git apply → refresh） |
| `src/input.zig` | `keyToMsg` の diff フォーカス分岐・マウスのハンクヒットテスト |
| `src/view.zig` | `renderDiff` のハンクハイライト＋自動スクロール |
| `README.md` / `TODO.md` | キー操作追記・TODO 1 のチェック更新 |

## 4. `src/diff/hunk.zig`（核心・純粋）

### データ構造

```zig
pub const Hunk = struct {
    text: []const u8,    // "@@ ... @@\n" ＋本文を diff_text から verbatim に切り出した slice
    start_line: usize,   // diff_text 内での @@ 行の 0 始まり行番号（ハイライト/カーソル/ヒットテスト用）
    line_count: usize,   // @@ 行＋本文が占める行数。ハイライト範囲 = [start_line, start_line+line_count)
};

pub const ParsedDiff = struct {
    file_header: []const u8, // 先頭〜最初の @@ 直前（diff --git / index / --- / +++）の verbatim slice
    hunks: []Hunk,           // **配列のみ** allocator 所有。text / file_header は diff_text を借用
    pub fn deinit(self: *ParsedDiff, a: std.mem.Allocator) void { a.free(self.hunks); }
};
```

**借用方針**: `parse` は `diff_text` のバイトを複製せず slice で指す（配列だけ所有）。`diff_text` は
persistent allocator 所有で次の `diff_loaded` まで安定なので安全。コピーコストもゼロ。
（`git/status.zig parse` は要素も複製するが、本モジュールは diff_text の寿命に乗るため借用で十分。）

### `parse(a, diff_text) -> ParsedDiff`

- 先頭から最初の `@@` 行直前までを `file_header` とする。
- 各 `@@` 行から次の `@@`（または EOF）までを 1 つの `Hunk.text` とする（verbatim slice）。
- `start_line` は `@@` 行の 0 始まり行番号、`line_count` はその hunk が占める行数。
- **`\ No newline at end of file` 行は本文 slice に自然に含まれる**（verbatim 切り出しのため特別扱い不要）。
- 以下は `hunks.len == 0` とする（stage キーは no-op）:
  - 空文字列 / `(no diff)` 等のプレースホルダ。
  - ヘッダのみで `@@` を含まない。
  - バイナリ差分（`Binary files ... differ`）。

### `buildPatch(a, parsed, hunk_index) -> []u8`（**TDD 最優先**）

- 出力 = `parsed.file_header` ＋ `parsed.hunks[hunk_index].text`。末尾に改行が無ければ `\n` を付す
  （`git apply` はパッチ末尾の改行を要求する）。
- ハンク単位では選択行の変換が無いため、`@@` ヘッダの行数（`-a,b +c,d`）は git が算出した値を
  **そのまま使える**（再計算不要）。forward / reverse でパッチ内容は同一で、方向は appcmd の
  `--reverse` フラグだけで切り替わる。
- 所有: 返り値は呼び出し側（update）が所有し、`AppCmd.apply_patch` に move する。

### worked example

unstaged diff（2 ハンク）の 2 番目だけを stage する場合:

```
diff --git a/f.txt b/f.txt        ┐
index e69de29..0000000 100644     │ file_header
--- a/f.txt                       │
+++ b/f.txt                       ┘
@@ -1,2 +1,2 @@      ← hunks[0]（選ばない）
 a
-b
+B
@@ -10,2 +10,3 @@    ← hunks[1].text（これだけ）
 x
+Y
 z
```

`buildPatch(_, parsed, 1)` = `file_header` ＋ `@@ -10,2 +10,3 @@\n x\n+Y\n z\n`。
`git apply --cached <tmp>` で hunks[1] のみ index へ入る。

### 方向の決定（section で一意）

| 選択ファイルの section | diff の中身 | 操作 | git |
|---|---|---|---|
| unstaged | `git diff`（index→worktree） | stage | `git apply --cached <tmp>` |
| staged | `git diff --cached`（HEAD→index） | unstage | `git apply --cached --reverse <tmp>` |
| untracked | — | 非対応 | no-op ＋ 案内メッセージ |

変更が staged/unstaged 両方にあるファイルは Changes 一覧に 2 エントリで出る既存挙動のため、
どちらを選択中かで方向が曖昧なく決まる。

### テスト（this module）

- parse: 単一ハンク / 複数ハンク / ヘッダのみ（0 件）/ バイナリ（0 件）/ 空（0 件）。
- parse: `start_line` / `line_count` が正しい（複数ハンク・file_header 行数を跨ぐ）。
- parse: 日本語を含む本文・ファイル名（`core.quotePath=false` で raw UTF-8）でも行単位で正しく分割。
- parse: 末尾に `\ No newline at end of file` を含むハンクが本文に取り込まれる。
- buildPatch: 選択ハンクのみ＋ file_header を含む。末尾改行を保証。
- buildPatch: 末尾ハンク（`\ No newline ...` 付き）でもバイト列が壊れない。
- すべて `std.testing.allocator`（リーク検出）。`test { refAllDecls(@This()); }`。

## 5. `src/model.zig`

- フィールド追加: `selected_hunk: usize`（init で 0）。
- ハンク数・境界は**キャッシュしない**（不変条件を増やさない）。`diff_text` は `diff_loaded` でのみ
  置換されるため、`update` と `view` が必要時に `hunk.parse` で都度算出する（純粋・安価）。
- `deinit` への追加は不要（usize）。

## 6. `src/messages.zig`

```zig
// Msg（借用なし・単純バリアント。deinit は no-op 側に追加）
hunk_next,
hunk_prev,
stage_hunk,
select_hunk: usize,  // マウスでハンク行クリック（reducer が selected_hunk をクランプ設定）

// AppCmd
apply_patch: ApplyPatch,
pub const ApplyPatch = struct { patch: []u8, reverse: bool };
```

- `Msg.deinit` の網羅 switch: 新 4 バリアント（`hunk_next`/`hunk_prev`/`stage_hunk`/`select_hunk`）を
  「借用 / 単純」側（no-op）に追加。
- `AppCmd.deinit` の網羅 switch: `.apply_patch => |ap| a.free(ap.patch)` を追加。
- テスト: `AppCmd.apply_patch` が patch を所有し deinit で解放（既存 stage/commit と同型）。

## 7. `src/update.zig`（純粋 reducer）

- `diff_loaded` 処理に `model.selected_hunk = 0;` を追加（既存の `setStr(diff_text)` はそのまま）。
- `hunk_next` / `hunk_prev`:
  - `parse(model.diff_text)` で `count = hunks.len` を得て即 `deinit`。
  - `hunk_next`: `if (model.selected_hunk + 1 < count) model.selected_hunk += 1;`
  - `hunk_prev`: `if (model.selected_hunk > 0) model.selected_hunk -= 1;`
  - 0 件なら据え置き。`.none` を返す。
- `select_hunk` → `parse` で count 取得し `model.selected_hunk = @min(i, count-1)`（0 件なら 0）。`.none`。
- `stage_hunk`:
  - `model.busy` なら `.none`（二重適用ゲート、既存 `request_commit` と同じ思想）。
  - ファイルが無い / hunk 0 件 → `.none`。
  - 現ファイルの section で分岐:
    - `untracked` → `setStr(error_text, "untracked はファイル単位で stage してください")`、`.none`。
    - それ以外 → `parse` → `selected_hunk` をクランプ → `buildPatch` →
      `.apply_patch{ .patch = <owned>, .reverse = (section == .staged) }`。`parse` の配列は即 deinit。
- テスト:
  - `hunk_next`/`hunk_prev` が count 内でクランプ移動（複数ハンク diff_text を直接セット）。
  - `stage_hunk`（unstaged）→ `apply_patch{ reverse=false }` で patch に選択ハンクと file_header を含む。
  - `stage_hunk`（staged）→ `reverse=true`。
  - `stage_hunk`（untracked）→ `.none` ＋ error_text セット。
  - `stage_hunk`（busy / 0 件）→ `.none`。
  - `diff_loaded` で `selected_hunk` が 0 に戻る。

## 8. `src/git/commands.zig`

```zig
/// "git apply --cached [--reverse] <file_path>"。呼び出し側が free。
pub fn applyPatchArgv(a, reverse: bool, file_path: []const u8) ![]const []const u8
```

- argv 順: `git`, `apply`, `--cached`, （reverse なら `--reverse`）, `file_path`。
- `-p1` は git diff 既定でパッチ側と一致するため明示不要。
- テスト: reverse 有無で `--reverse` の有無が切り替わる・末尾が file_path。

## 9. `src/appcmd.zig`

- `apply_patch` 分岐を追加:
  1. 一時ファイルを作成し patch を io 経由で書き込む（**0.16 の一時ファイル / Dir API は
     `zigzag-api-notes.md` に照らして実装時に pin する**。既存 process.zig の Io 修正と同種の実装リスク）。
     パスは絶対パスにして cwd 非依存にする。`defer` で確実に削除。
  2. `argv = applyPatchArgv(a, ap.reverse, tmp_abs_path)`。
  3. `process.run(a, io, argv, cwd)`。
  4. `exit_code != 0` → `.{ .git_error = dup(stderr) }`（apply 失敗を握り潰さず stderr を表面化）。
  5. 成功 → 既存 `execThenRefresh` 同等に `statusRaw` → `status_loaded`
     （update 側が status_loaded で diff を自動再読込）。
- 結合テスト（既存 TmpRepo パターン）:
  - 複数行ファイルを commit → 2 箇所変更 → unstaged diff を取得 → 1 ハンクだけ `apply_patch` →
    status_loaded が staged/unstaged 両エントリを返す（部分 stage の確認）。
  - staged な変更を `reverse=true` で `apply_patch` → そのハンクが unstaged 側へ戻る（部分 unstage）。
  - 日本語を含む変更行でも apply が成功する。
  - 不正パッチ（コンテキスト不一致）→ `git_error`（握り潰さない）。

## 10. `src/input.zig`

- `keyToMsg(focus, key)` に `focus == .diff` 分岐を新設（現状は commit のみ特別扱い）:

| キー | changes（既存） | diff（新規） |
|---|---|---|
| `j` / `↓` | `key_down` | `hunk_next` |
| `k` / `↑` | `key_up` | `hunk_prev` |
| `s` / `space` / `Enter` | `toggle_stage` | `stage_hunk` |
| `Ctrl+d` / `Ctrl+u` | `scroll_diff_*` | `scroll_diff_*`（据え置き） |
| `c` / `r` / `q` / `tab` | 共通 | 共通 |

  - `Enter` キーを抽象 `Key` に追加（既存 `.enter` バリアントを diff フォーカスで `stage_hunk` に割当）。
  - changes フォーカスの挙動は不変（既存テストを壊さない）。
- マウス: diff ペインのクリックで、クリック行が属するハンクを選択する。
  - `parse` の `start_line`/`line_count` を使ったヒットテスト用 pure 関数
    `hunkRowFromVisual(diff_text, visual_row) -> ?usize` を追加（`changesRowLayout`↔`fileRowFromVisual`
    と同型: 描画とヒットテストで同一の `parse` を共有しズレを防ぐ）。
  - クリック→ハンク選択用の `Msg.select_hunk: usize` を追加する（reducer は `model.selected_hunk` を
    クランプ設定して `.none`。diff ペインクリックは既存の `set_focus(.diff)` に加えてこの選択も発行する）。
  - stage はキーボード `s`。ダブルクリック stage は phase 1 では行わない。
- テスト（純粋）:
  - `keyToMsg(.diff, ...)` の各マッピング。
  - `keyToMsg(.changes, ...)` が不変（回帰）。
  - `hunkRowFromVisual` のハンク境界解決（複数ハンク・ヘッダ行・範囲外）。

## 11. `src/view.zig`（`renderDiff`）

- 毎フレーム `parse(model.diff_text)`（`ctx.allocator` arena）。
- `focus == .diff` かつ `hunks.len > 0` のとき `hunks[selected_hunk]` を強調:
  - `@@` ヘッダ行を**反転表示**し、左に選択マーカー（例 `▌`）を付す。
  - 本文行は既存の `+`（緑）/`-`（赤）配色を維持。
- 自動スクロール: `renderChanges` の `changes_scroll`（view が唯一の writer）と同じパターンで、
  `model.diff_scroll = ensureVisible(model.diff_scroll, hunks[selected_hunk].start_line, height)` により
  選択ハンクのヘッダ行が可視範囲に入るようにする（`focus==.diff` かつ hunk>0 のときのみ）。
  - **シグネチャ変更**: 現状 `renderDiff` は `*const Model` を受け取り `diff_scroll` を書かない
    （ローカルの `scroll_off` で clamp するのみ）。本変更で `renderChanges` と同様に `*Model` を受け取り、
    上記の通り `model.diff_scroll` を書く唯一の writer になる（`render` は既に `*Model` を渡しているため
    呼び出し側変更は不要）。`focus != .diff` または hunk 0 件のときは従来どおりローカル clamp のみで
    `diff_scroll` を書かない。
- **既知の軽微な制約（seam としてコメント明記）**: `focus==.diff` 時は毎フレーム選択ハンクを
  可視化するため、`Ctrl+d/u` の自由スクロールはハンク範囲外へ出ると次フレームで引き戻される。
  phase 1 は許容。将来「選択が変わったフレームのみスクロール」へ精緻化可能。
- `parse` が 0 件・`diff_text` が空のときは既存の描画にフォールバック（ハイライト無し）。
- 描画は自動 test 無し（`test { refAllDecls }` で型検査）。ハイライト/スクロールのロジックは
  `parse` と `ensureVisible`（共に純粋・テスト済み）の合成で担保する。

## 12. README / TODO 更新

- `README.md`: diff ペインのキー操作（`j/k` ハンク移動・`s`/`Enter` ハンク stage/unstage）を追記。
- `TODO.md`: TODO 1 のハンク単位サブタスクにチェック、行単位・untracked ハンク・ダブルクリック stage は
  phase 2 として残す旨を追記。

## 13. 受け入れ基準

1. 複数ハンクを持つ unstaged ファイルで、1 ハンクだけ stage でき、残りは unstaged に残る。
2. staged ファイルで 1 ハンクだけ unstage でき、残りは staged に残る。
3. 日本語を含む変更行のハンクでも 1/2 が成立する。
4. 末尾に `\ No newline at end of file` を含むハンクでも apply が成功する。
5. untracked ファイルでハンク stage キーを押すと、案内メッセージが出てファイルは壊れない。
6. apply が失敗した場合（コンテキスト不一致等）、空挙動で握り潰さず status バーに git_error を表示。
7. 既存のファイル単位 stage/unstage・コミット・マウス・スクロールの挙動は不変（既存テスト green）。
8. diff ペインで選択中ハンクがハイライトされ、`j`/`k` 移動で自動スクロールして見える。

## 14. 実装順（純粋層 TDD → 配線）

1. `src/diff/hunk.zig`（parse / buildPatch）を TDD。`root_test.zig` 有効化。
2. `messages.zig`（Msg/AppCmd + deinit）→ `model.zig`（selected_hunk）。
3. `update.zig`（hunk_next/prev/stage_hunk/diff_loaded リセット）を TDD。
4. `git/commands.zig`（applyPatchArgv）を TDD。
5. `appcmd.zig`（apply_patch 解釈・tmp ファイル）を結合テスト。0.16 fs API を api-notes で pin。
6. `input.zig`（keyToMsg diff 分岐・hunkRowFromVisual）を TDD。
7. `view.zig`（ハイライト・自動スクロール配線）。
8. `main.zig` 配線確認 → tmux で実 pty 目視（非 tty では unverified）。
9. README / TODO 更新。
