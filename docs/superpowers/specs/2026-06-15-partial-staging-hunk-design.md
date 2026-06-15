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
| `src/view.zig` | `renderDiff` のハンクハイライト＋自動スクロール（`*Model` 化） |
| `src/main.zig` | `applyAppCmd` / `seedInitialStatus` の網羅 switch に `apply_patch` arm（後述 §9.1） |
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

- **行頭が `@@` の行のみ**をハンクヘッダ境界とする（本文行は必ず ` `/`+`/`-`/`\` で始まるため、
  本文中に `+foo@@bar` のような `@@` を含む行があっても誤検出しない）。
- 先頭から最初のハンクヘッダ行直前までを `file_header` とする。
- 各ハンクヘッダ行から次のヘッダ行（または EOF）までを 1 つの `Hunk.text` とする（verbatim slice）。
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
| unstaged（かつ `orig_path == null`） | `git diff`（index→worktree） | stage | `git apply --cached <tmp>` |
| staged（かつ `orig_path == null`） | `git diff --cached`（HEAD→index） | unstage | `git apply --cached --reverse <tmp>` |
| untracked | — | 非対応 | no-op ＋ 案内メッセージ |
| **rename（`orig_path != null`）** | rename を含む diff | 非対応 | no-op ＋ 案内メッセージ |

変更が staged/unstaged 両方にあるファイルは Changes 一覧に 2 エントリで出る既存挙動のため、
どちらを選択中かで方向が曖昧なく決まる。

**rename の除外理由（phase 1）**: `file_header` は最初の `@@` 直前までを含むため、rename では
`rename from` / `rename to`（similarity index 行）が file_header に入る。これを
`git apply --cached --reverse` するとハンクだけでなく rename 自体まで巻き戻す恐れがある。
既存コードは rename を `orig_path != null` で扱い `diffArgv` が両パスを渡す（commands.zig）ため
rename の diff は実際に発生し得る。phase 1 では rename ファイルのハンク stage を untracked と同様に
非対応（案内メッセージ）とし、ファイル単位の stage/unstage に委ねる。rename のハンク stage は phase 2。

### テスト（this module）

- parse: 単一ハンク / 複数ハンク / ヘッダのみ（0 件）/ バイナリ（0 件）/ 空（0 件）。
- parse: `start_line` / `line_count` が正しい（複数ハンク・file_header 行数を跨ぐ）。
- parse: 日本語を含む本文・ファイル名（`core.quotePath=false` で raw UTF-8）でも行単位で正しく分割。
- parse: 末尾に `\ No newline at end of file` を含むハンクが本文に取り込まれる。
- parse: 本文行に `@@` を含む行（例 `+foo@@bar`）があってもハンク分割が壊れない（行頭アンカー回帰）。
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

- **ファイル選択変更（`key_down` / `key_up` / `select_index`）** に `model.selected_hunk = 0;` を追加
  （別ファイルへ移ったらハンクカーソルを先頭へ）。既存の `diff_scroll = 0` 設定と同じ箇所。
- `diff_loaded` 処理: `model.selected_hunk` を**リセットせず clamp** する
  （`parse` で `count` を得て `model.selected_hunk = if (count == 0) 0 else @min(model.selected_hunk, count - 1)`）。
  これにより「1 ハンク stage → status_loaded → diff 再読込」後もカーソルが直前位置の近傍に留まり、
  複数ハンクを連続 stage しやすい（レビュー指摘の UX）。ファイル切替時の 0 リセットは上記ナビ側が担う。
- `hunk_next` / `hunk_prev`:
  - `parse(model.diff_text)` で `count = hunks.len` を得て即 `deinit`。
  - `hunk_next`: `if (model.selected_hunk + 1 < count) model.selected_hunk += 1;`
  - `hunk_prev`: `if (model.selected_hunk > 0) model.selected_hunk -= 1;`
  - 0 件なら据え置き。`.none` を返す。
- `select_hunk` → `parse` で count 取得。**underflow ガード必須**:
  `if (count == 0) model.selected_hunk = 0 else model.selected_hunk = @min(i, count - 1);`
  （`@min(i, count-1)` 単独は `count==0` で usize underflow し Debug でパニックするため不可）。`.none`。
- `stage_hunk`:
  - `model.busy` なら `.none`。**注意**: `model.busy` を立てるのは reducer ではなく
    `main.zig dispatchSideEffect`（副作用を worker へ委譲する際に立て、結果 Msg で false に戻す）。
    update 側の busy チェックは UX 上の早期 no-op に過ぎず、最終的な直列化は main が担う
    （busy 中の副作用は `pending` に latest-wins 退避され取りこぼさない）。`apply_patch` も他の副作用と
    同様に必ず `dispatchSideEffect` 経由で直列化される（§9.1 参照）。
  - ファイルが無い / hunk 0 件 → `.none`。
  - 現ファイルの section / rename で分岐:
    - `untracked` → `setStr(error_text, "untracked はファイル単位で stage してください")`、`.none`。
    - `orig_path != null`（rename） → `setStr(error_text, "rename はファイル単位で stage してください")`、`.none`。
    - それ以外（tracked・非 rename） → `parse` → `selected_hunk` をクランプ → `buildPatch` →
      `.apply_patch{ .patch = <owned>, .reverse = (section == .staged) }`。`parse` の配列は即 deinit。
- テスト:
  - `hunk_next`/`hunk_prev` が count 内でクランプ移動（複数ハンク diff_text を直接セット）。
  - `stage_hunk`（unstaged）→ `apply_patch{ reverse=false }` で patch に選択ハンクと file_header を含む。
  - `stage_hunk`（staged）→ `reverse=true`。
  - `stage_hunk`（untracked）→ `.none` ＋ error_text セット。
  - `stage_hunk`（rename: `orig_path != null`）→ `.none` ＋ error_text セット。
  - `stage_hunk`（busy / 0 件）→ `.none`。
  - `select_hunk`（count==0）→ `selected_hunk==0`・パニックしない（underflow ガード回帰）。
  - `key_down`/`key_up`/`select_index` で `selected_hunk` が 0 に戻る（ファイル切替リセット）。
  - `diff_loaded` で `selected_hunk` が count にクランプされる（リセットされず近傍維持）。

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
  1. **書込先を `<repo_root>/.git/` 配下に確定**する（システム tmpdir 発見 API が無く、
     `std.testing.tmpDir` はテスト専用のため本番で使えない。`.git/` は同一 FS・確実に書込可能・
     git 管理外）。ファイル名は衝突回避のため一意化（例 `git-tui-stage-<pid>.patch`。0.16 の pid 取得
     API は実装時に確認）。`Io.Dir.writeFile(io, .{ .sub_path, .data })`（api-notes L110、本番でも使える
     Dir メソッド）で書き込む。書込先 Dir は `repo_root` を io で open して得る。`defer` で確実に削除。
     - cwd は `Child.Cwd` ユニオンで Dir を直接得られない場合があるため、`repo_root`（model 所有の文字列）を
       AppCmd か run 引数で受け取り、そこから絶対パスを組む。受け渡し経路は実装計画で確定
       （`ApplyPatch` に `repo_root` を持たせず、appcmd.run の引数 cwd/既存情報から解決する方針を優先）。
  2. `argv = applyPatchArgv(a, ap.reverse, tmp_abs_path)`（絶対パスで cwd 非依存）。
  3. `process.run(a, io, argv, cwd)`。
  4. `exit_code != 0` → `.{ .git_error = dup(stderr) }`（apply 失敗を握り潰さず stderr を表面化）。
  5. 成功 → 既存 `execThenRefresh` 同等に `statusRaw` → `status_loaded`
     （update 側が status_loaded で diff を自動再読込）。
- 結合テスト（既存 TmpRepo パターン）:
  - 複数行ファイルを commit → 2 箇所変更 → unstaged diff を取得 → 1 ハンクだけ `apply_patch` →
    status_loaded が staged/unstaged 両エントリを返す（部分 stage の確認）。
  - staged な変更を `reverse=true` で `apply_patch` → そのハンクが unstaged 側へ戻る（部分 unstage）。
  - 日本語を含む変更行でも apply が成功する。
  - 末尾に `\ No newline at end of file` を含む変更でも apply が成功する（受け入れ基準 4）。
  - 不正パッチ（コンテキスト不一致）→ `git_error`（握り潰さない）。

## 9.1. `src/main.zig`（配線・網羅 switch）

`AppCmd` に `apply_patch` を足すと、`else` を持たない網羅 switch が main.zig に **2 箇所**ある
（messages.zig の deinit と appcmd.run は §6/§9 で対応済み。合わせて 4 箇所）。両方に arm を足さないと
コンパイル不可:

- `applyAppCmd`（現状 `.refresh_status, .stage, .unstage, .load_diff, .commit => dispatchSideEffect`）:
  → `apply_patch` を**同じ副作用群に追加**して `dispatchSideEffect(app, cmd)` へ振る。これにより
  `model.busy` 管理・worker 直列化・`pending` latest-wins 退避に正しく乗る（§7 の busy 注記参照）。
- `seedInitialStatus`（起動時の status→load_diff 連鎖を回す網羅 switch、`else` 無し）:
  → 起動チェーンで `apply_patch` は生じ得ないが、網羅 switch なので arm が必要。`.none, .quit => {}` と
  同じ **no-op arm** に `apply_patch` を加える（再実行しない）。
- `step` 内の `switch (cmd) { .none, .quit => deinit, else => {} }`（line 184 付近）は `else` を持つため
  変更不要（`apply_patch` は else=所有権移譲済みに落ちる）。
- 実 pty 検証（tmux）で、diff フォーカス→`j/k`→`s` のハンク stage が busy スピナと共に動くことを目視。

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
    `hunkFromDiffLine(diff_text, abs_line) -> ?usize` を追加（`changesRowLayout`↔`fileRowFromVisual`
    と同型: 描画とヒットテストで同一の `parse` を共有しズレを防ぐ）。引数は **diff_text 内の絶対行番号**。
  - **スクロールオフセット合算が必須**（レビュー指摘）: changes ペインと同様に、クリックのペイン相対行 `vr` に
    `model.diff_scroll` を足して絶対行 `model.diff_scroll + vr` に直してから `hunkFromDiffLine` に渡す。
    これは §11 で `renderDiff` を `diff_scroll` の唯一 writer にする（clamp/ensureVisible 済み値を書き戻す）
    ことで成立する（input.zig の changes ヒットテストが `changes_scroll + vr` で読むのと同型）。
  - クリック→ハンク選択用の `Msg.select_hunk: usize` を追加する（reducer は `model.selected_hunk` を
    クランプ設定して `.none`。diff ペインクリックは既存の `set_focus(.diff)` に加えてこの選択も発行する）。
  - stage はキーボード `s`。ダブルクリック stage は phase 1 では行わない。
- テスト（純粋）:
  - `keyToMsg(.diff, ...)` の各マッピング。
  - `keyToMsg(.changes, ...)` が不変（回帰）。
  - `hunkFromDiffLine` のハンク境界解決（複数ハンク・file_header 行・範囲外・絶対行入力）。

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
6. rename ファイル（`orig_path != null`）でハンク stage キーを押すと、案内メッセージが出て
   rename もハンクも巻き戻らない。
7. apply が失敗した場合（コンテキスト不一致等）、空挙動で握り潰さず status バーに git_error を表示。
8. 既存のファイル単位 stage/unstage・コミット・マウス・スクロールの挙動は不変（既存テスト green）。
9. diff ペインで選択中ハンクがハイライトされ、`j`/`k` 移動で自動スクロールして見える。
10. diff ペインのクリックで、`Ctrl+d/u` でスクロールした後でも正しいハンクが選択される
    （スクロールオフセット合算の確認）。

## 14. 実装順（純粋層 TDD → 配線）

1. `src/diff/hunk.zig`（parse / buildPatch・行頭 `@@` アンカー）を TDD。`root_test.zig` 有効化。
2. `messages.zig`（Msg 4 種 + AppCmd.apply_patch + deinit）→ `model.zig`（selected_hunk）。
3. `update.zig`（hunk_next/prev/select_hunk/stage_hunk・ナビ 0 リセット・diff_loaded clamp・
   rename/untracked ガード・underflow ガード）を TDD。
4. `git/commands.zig`（applyPatchArgv）を TDD。
5. `appcmd.zig`（apply_patch 解釈・`.git/` 配下へ tmp 書込）を結合テスト。0.16 fs/pid API を実装時に確認。
6. `input.zig`（keyToMsg diff 分岐・`hunkFromDiffLine`・クリック時の diff_scroll 合算）を TDD。
7. `view.zig`（`renderDiff` を `*Model` 化し diff_scroll 唯一 writer・ハイライト・自動スクロール）。
8. `main.zig`（`applyAppCmd` に `apply_patch => dispatchSideEffect`・`seedInitialStatus` に no-op arm）
   配線確認 → tmux で実 pty 目視（非 tty では unverified）。
9. README / TODO 更新。
