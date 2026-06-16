# 行単位 stage / unstage 設計（TODO 1 phase 2: 行レンジ部分パッチ）

- 日付: 2026-06-16
- 対象: `TODO.md` TODO 1「部分ステージング（ハンク / 行単位）」のうち
  「行単位選択（複数行レンジ）→ 部分パッチ生成」。
- 前提: phase 1（ハンク単位 stage/unstage）は完了済み。本設計はその上に**行レンジ選択**を載せる。
- 親 spec: `docs/superpowers/specs/2026-06-14-git-tui-design.md`（全体アーキテクチャ）。

## Goal

JetBrains / lazygit と同様に、diff ペイン内の変更を**行単位（連続レンジ）**で
stage / unstage できるようにする。tracked ファイルの unstaged→index（stage）と
index→unstaged（unstage）の双方向を対象とする。

## Scope（今回やること / やらないこと）

含む:
- tracked ファイルの行レンジ stage / unstage。
- lazygit 風の行カーソル＋ビジュアル選択（連続レンジ）。
- diff クリックによるカーソル移動。

含まない（将来 TODO へ退避）:
- 飛び飛び（discontiguous）のマーク集合選択（チェックボックス型）。
- マウスのドラッグ範囲拡張 / Shift クリック範囲拡張（`MouseEvent` 修飾キー未対応のため）。
- untracked ファイルのハンク/行 stage（intent-to-add）。
- rename ファイルのハンク/行 stage。

## 用語・前提（実装の不変条件）

- **絶対 diff 行 index**: `std.mem.splitScalar(diff_text, '\n')` の要素 index。`hunk.zig`
  既存の `start_line` / `hunkIndexForLine` と同じ座標系。
- **1 パッチ = 1 ハンク**: 行レンジ stage は常に単一ハンクのパッチを生成する。
- **選択はカーソルのハンクにクランプ**: 範囲 `[min(cursor,anchor), max(cursor,anchor)]` を
  **カーソルが属するハンクの本文**に交差させる。ハンク跨ぎの範囲は無視（はみ出し部分は捨てる）。
- **文脈行は範囲外でも常に保持**: 選択で gate されるのは `+`/`-` 行のみ。`' '` 文脈行は
  範囲内外を問わずパッチに残す（git apply のコンテキスト整合に必須）。

## アーキテクチャ（変更箇所）

Elm 風の純粋層から配線層の順で実装する。

### 1. 純粋層: `src/diff/hunk.zig` に `buildLinePatch` を追加

```
pub fn buildLinePatch(
    a: std.mem.Allocator,
    parsed: ParsedDiff,
    hunk_index: usize,
    sel_start: usize, // 絶対 diff 行 index（閉区間）
    sel_end: usize,   // 同上。sel_start<=sel_end を呼び出し側が保証
    reverse: bool,    // false=stage(forward), true=unstage(reverse)
) !?[]u8
```

- 戻り値 `?[]u8`: 選択範囲に**保持される `+`/`-` 行が 1 つも無い**場合は `null`
  （文脈行のみ選択 / change 行ゼロ）。呼び出し側（reducer）は `null` を no-op として扱う。
- 非 null のとき、呼び出し側所有のパッチ文字列（`file_header` + 再構成ハンク、末尾改行保証）。

変換規則（`git add -p` / `git reset -p` と同一。レビューア 2 名で正当性確認済み）。
ハンク本文の各行を、その絶対行 index が `[sel_start, sel_end]` に入るかで分類する:

| 行種別 | stage (forward) | unstage (reverse) |
|---|---|---|
| 選択された `+` / `-` | そのまま保持 | そのまま保持 |
| 未選択の `+` | **削除（行ごと落とす）** | **文脈行化（`+`→`' '`）** |
| 未選択の `-` | **文脈行化（`-`→`' '`）** | **削除（行ごと落とす）** |
| 文脈行 `' '` | 保持 | 保持 |

正当性: index は `git diff --cached`（HEAD→index）の post-image。unstage(reverse) では
未選択 `+` は index に存在する→文脈化して reverse-apply 時に残す、未選択 `-` は index に
不在→削除して reverse-apply 時に再追加させない。stage(forward) はその鏡像。

`@@` ヘッダ再計算:
- `old_count = (保持された ' ' 行数) + (保持された '-' 行数)`
- `new_count = (保持された ' ' 行数) + (保持された '+' 行数)`
- `old_start` / `new_start` は**原ハンクの値を据え置き**（単一ハンクのため前ハンクのオフセット
  ずれが無く、git apply は context でロケートするため stale な start で拒否されない。
  `git add -p` 自身も start 据え置き・count のみ再計算する）。

No-newline ポリシー:
- `\ No newline at end of file` 行（`\` 始まり）は直前の `+`/`-`/`' '` 行に属する。
  選択範囲が no-newline 境界に掛かり、矛盾するパッチ（文脈化された行が no-newline を主張する等）が
  生じ得るケースは、**矛盾パッチを emit せず `null`（no-op）を返す**方針とする。
- 具体的には: 「直前行を文脈行化する変換が必要なのに、その行に `\ No newline` マーカーが付いている」
  場合に検出して `null` を返す。git apply は厳格なので最悪でも**拒否（安全）**だが、ユーザに
  分かりやすいよう reducer 側でガイダンスを出す（後述）。これは phase の許容境界として明記する。
- カウント計算では `\` 始まり行は `' '`/`+`/`-` のいずれにも数えない（既存 `parse` テストの不変条件と一致）。

### 2. 状態: `src/model.zig`

- `selected_hunk: usize` を**廃止**し、以下を追加:
  - `diff_cursor: usize` — diff ペインのカーソル（絶対 diff 行 index）。
  - `diff_anchor: ?usize` — ビジュアル選択の anchor（絶対 diff 行 index）。`null`=範囲未選択。
- どちらもスカラのため `Model.deinit` は不変（解放不要）。
- カーソルの所属ハンクは保持せず `hunk.hunkIndexForLine(parsed, diff_cursor)` で都度導出する。

不変条件・リセット規則:
- **init**: `diff_cursor = 0`, `diff_anchor = null`。
- **ファイル切替（select 系）/ diff_loaded（再読込）**: 後述の `clampCursor` で
  カーソルを**先頭ハンクの本文先頭行**へ正規化、`diff_anchor = null`。
- **clampCursor**（reducer 内ヘルパ、純粋）: parse 結果に対し、
  - ハンク 0 個 → `diff_cursor = 0`, `diff_anchor = null`。
  - カーソルがどのハンク本文にも属さない（file_header / ヘッダ行 / 範囲外）→
    先頭ハンクの本文先頭行（`hunks[0].start_line + 1`、本文が無いなら `start_line`）にクランプ。
  - `diff_anchor` が非 null かつカーソルと別ハンク → anchor は維持（patch builder 側でハンク
    クランプするため安全）。ただし diff 再読込時は `anchor=null`。

### 3. メッセージ: `src/messages.zig`

既存の `hunk_next` / `hunk_prev` / `select_hunk_at_line` を置換・追加（すべて非所有スカラ、`deinit` 自明）:
- `diff_cursor_down` / `diff_cursor_up` — 行カーソルを ±1（本文行域でクランプ）。
- `diff_hunk_next` / `diff_hunk_prev` — カーソルを次/前ハンクの本文先頭へジャンプ。
- `toggle_line_selection` — `diff_anchor` が `null` なら `= diff_cursor`、非 null なら `null` に戻す。
- `stage_lines` — 選択レンジ（または anchor=null なら単一カーソル行）を stage/unstage。
- `select_line_at: usize` — diff クリックの絶対行。カーソルをそこへ移動（focus も diff）、`anchor=null`。

`AppCmd` は**無改変**。`stage_lines` は既存の `AppCmd.apply_patch{patch:[]u8, reverse:bool}` を返す。

### 4. reducer: `src/update.zig`

- `diff_cursor_down/up`: parse して本文行域 `[first_hunk_body_top, total_lines)` 内で ±1 clamp。
  （ヘッダ行や file_header にはカーソルを置かない設計。実装簡略のため「ハンク本文行のみ」を
  許可域とし、移動時にヘッダ行をスキップ。）
- `diff_hunk_next/prev`: 現カーソルのハンク index を導出し ±1、その本文先頭行へ。`anchor=null`。
- `toggle_line_selection`: 上記トグル。
- `select_line_at`: `focus=.diff`、parse、`clampCursor` でカーソル設定、`anchor=null`。
  ヘッダ/file_header/範囲外クリックはハンク本文へクランプ（誤選択を作らない）。
- `stage_lines`:
  - ガード（既存 `stage_hunk` と同様）: `busy` / `files 空` / `untracked` / `rename(orig_path!=null)`
    は no-op（untracked・rename はガイダンス `error_text`）。
  - parse、`hunks.len==0` は no-op。
  - `idx = hunkIndexForLine(parsed, diff_cursor)`（null は no-op）。
  - `lo = min(cursor, anchor orelse cursor)`, `hi = max(...)`。
  - `buildLinePatch(idx, lo, hi, reverse = (section==.staged))`。
    - `null` 戻り（change 行ゼロ / no-newline 矛盾）→ `error_text` にガイダンス、no-op。
    - 非 null → `diff_anchor=null`（選択消費）して `apply_patch` を返す。
- `diff_loaded`: `setStr` 後に `clampCursor`（先頭ハンク本文先頭・`anchor=null`）。

### 5. 描画: `src/view.zig` `renderDiff`

- diff_scroll 調整を**ハンク重なり判定からカーソル行 ensure-visible へ置換**:
  `model.diff_scroll = ensureVisible(model.diff_scroll, model.diff_cursor, limit)`
  （`focus==.diff` のフレームのみ。diff_scroll の唯一 writer の不変条件・マウス当たり判定との
  一致を維持）。これにより大きいハンク内 j/k でもカーソルが画面外へ出ない。
- ハイライト:
  - 選択レンジ `[lo, hi]`（anchor 非 null 時）に含まれる行を `sel_style`（reverse）。
  - カーソル行は左マーカー `▌` ＋強調（anchor の有無に関わらず）。
  - 非選択行は従来どおり `+`=緑 / `-`=赤。
- `clampScroll` / `fitPane` の既存制約（行切り詰め）は不変。

### 6. 入力: `src/input.zig`

- `keyToMsg(.diff, ...)`:
  - `j` / `down` → `diff_cursor_down`、`k` / `up` → `diff_cursor_up`。
  - `]` → `diff_hunk_next`、`[` → `diff_hunk_prev`。
  - `v` → `toggle_line_selection`。
  - `s` / `' '` / `enter` → `stage_lines`。
- `fromZigzagMouse` / `mouseToMsg`: diff クリックは `select_line_at`（旧 `select_hunk_at_line` の
  リネーム・意味変更）。**drag/release は従来どおり `ignore` を維持**（範囲拡張は今回 descope）。
  当たり判定 `diff_line = diff_scroll + (ev.y - diff.y)` は不変。

### 7. status バーのヒント更新（`renderStatus`）

`focus==.diff` のヒントを行操作向けに更新（例）:
`j/k line  v select  s stage/unstage  ]/[ hunk  tab pane  r refresh  q quit`

## 検証方針（TDD）

純粋層を先に TDD、配線を後。**結合テスト（実 git ラウンドトリップ）を blocking ゲート**に据える。

### 結合テスト（`src/appcmd.zig`、一時 repo・主検証）
1. unstaged の複数 change を持つハンクで、一部の行レンジを stage（forward）→
   `git diff --cached` で**選択行のみが index に入った**ことを assert、残りは unstaged。
2. staged ハンクの一部行を unstage（reverse）→ `git diff --cached` で**選択行のみ index から外れた**ことを assert。
3. `git apply --cached --check` が通る（start/count 妥当性の経験的担保）。
4. No-newline 境界を含む選択 → `buildLinePatch` が `null`（no-op）になることを純粋層で確認
   （結合では「矛盾パッチを git に渡さない」ことを保証）。

### ユニットテスト（`src/diff/hunk.zig`、パッチ文字列・従検証）
- stage forward: 未選択 `+` 削除・未選択 `-` 文脈化・`@@` count 再計算を検証。
- unstage reverse: 鏡像を検証。
- **フルハンク選択時 `buildLinePatch` 出力が `buildPatch` と等価**（補助不変条件）。
- 文脈行のみ選択 → `null`。
- No-newline 境界選択 → `null`。
- 日本語を含む行で行単位パッチが壊れない。

### reducer / input / view テスト
- `diff_cursor_down/up` の本文行クランプ、`diff_hunk_next/prev` のジャンプ、`toggle_line_selection`、
  `stage_lines` のハンククランプ・ガード（untracked/rename/busy/0 ハンク）・`null` no-op。
- `diff_loaded` 後の `clampCursor`（先頭ハンク本文・`anchor=null`）不変条件。
- `keyToMsg` の新キー写像、`select_line_at` のクリック→カーソル写像。
- `renderDiff` のカーソル ensure-visible（大ハンク内でカーソルが可視窓に入る）、選択レンジ強調。

### テスト規約（既存に従う）
- 実装と同じ `.zig` 内 `test {}`。`std.testing.allocator`（arena が要る view は ArenaAllocator）。
- 各ファイル `test { std.testing.refAllDecls(@This()); }`。

## TODO.md 反映

- TODO 1 の `[ ] 行単位選択（複数行レンジ）→ 部分パッチ生成` を `[x]` に。
- TODO 1 留意点 or 新規 phase 2 項目として追記:
  - 飛び飛びマーク集合選択（チェックボックス型・discontiguous）。
  - マウスのドラッグ範囲拡張 / Shift クリック（`MouseEvent` に修飾キーフィールド追加が前提）。

## 既知の制約（phase 境界として明記）

- 1 操作 = 単一ハンク内の連続レンジのみ。ハンク跨ぎ範囲は無視。
- No-newline 境界に掛かる選択は no-op（矛盾パッチを出さない安全側）。
- マウスは「クリックでカーソル移動」のみ。範囲はキーボード（`v` + `j/k`）。
- untracked / rename は引き続きファイル単位 stage（行単位 no-op + ガイダンス）。
