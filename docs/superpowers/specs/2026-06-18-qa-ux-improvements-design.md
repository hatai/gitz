# git-tui QA 2026-06-18 UX 改善案 設計 (TODO 1 付随)

作成: 2026-06-18
対象: `TODO.md` 「QA 2026-06-18 観察による UX 改善提案（機能ブロッカーではない・任意対応）」
の未対応 4 タスクを 1 つの spec にまとめて実装する。

## 1. 背景・スコープ

TODO 1（部分ステージング）の全 Sub Tasks は 2026-06-18 QA で期待どおり動作確認済み。
以下は機能ブロッカーではなく、使い勝手・テスト容易性・互換性の改善案。本 spec で**全 4 タスクを実装する**。

- タスク A: `v` トグル状態の視覚的明示（範囲反転 + ステータスバー SELECT 表示）
- タスク B: rename+modify の staged diff 表示の補足（メタ行）
- タスク C: commit の `Ctrl+S` キーバインドの README 注意書き追加
- タスク D: `#` / `H` でハンク全体を選択するショートカット

### アーキテクチャ前提（`CLAUDE.md` 準拠）
- Elm 風・副作用隔離。`model/messages/update/appcmd/git/diff/*` が純粋層（TDD 対象）、
  `input/view/main` が UI 層。
- `update(*Model, Msg) !AppCmd` は**純粋 reducer**（端末/git に触れない）。
- `Msg`/`AppCmd` の所有ペイロードは複製所有し、消費者が deinit。
- 機能追加は「純粋層を TDD → UI 配線」の順。

### レビュー経緯
subagent（実現可能性レビュー）および codex 相当（厳格な正確性・所有権レビュー）の
2 系統で設計レビューを実施。以下の指摘を取り込み済み:
- タスク D: 空 diff（`hunks.len==0`）で `#`/`H` 押下時の out-of-bounds panic → arm 先頭ガード必須。
- タスク B: `2 R.`（完全 stage）で「content partial」の嘘メタ行が出る →「同 path の `.unstaged` エントリ存在」AND 条件追加。
- タスク A: prefix 桁数は `>> `（3 桁）より `>`（1 桁）が fitPane 切り詰め影響を最小化。
- タスク D: `stage_lines`/`stage_hunk` の apply_patch 構築は共通ヘルパへ切り出し、重複とデットコード化を防止。

---

## 2. タスク A: `v` トグル視覚化

### 2.1 観察と Goal
`v` で範囲選択開始 → もう一度 `v` で解除した際、テキストダンプ snapshot では
anchor 有無の区別がほぼ見えない（色違いのみ）。実機の色付き端末では判別可能だが、
テスト自動化やスクリーンショット共有で分かりにくい。

**Goal**: anchor 非 null のとき形状レベルで差を出し、テキストダンプでも選択状態が判別可能にする。

### 2.2 設計
- **行頭 prefix**: `view.renderDiff` で、`in_sel`（anchor 非 null かつ focus==.diff かつ行が
  `selectionRange(cursor, anchor)` の `[lo,hi]` 内）のとき、行頭に `>`（1 桁）を前置してから
  reverse スタイルを適用。
- **cursor 行優先**: `is_cursor` の行は `▌` マーカーを維持（既存どおり）。cursor 行が範囲内にある
  場合（`#`/`select_hunk` 後や `v` 直後の単一点選択）、cursor 表示を優先し範囲ハイライト（`>` prefix）
  は cursor 行には重ねない（視認性確保）。範囲内の非 cursor 行にのみ `>` prefix が付くため、
  `#` 後は「本文末尾 = `▌` マーカー」「それ以外の本文行 = `>` prefix」と視覚的に分かれる。
- **ステータスバー**: `view.renderStatus` の hint 横に `[SELECT]` 表示。
  条件: `model.focus == .diff and model.diff_anchor != null`。
- **state 増加無し**: 既存の `model.diff_anchor` と `selectionRange` を使用。

### 2.3 実装箇所
- `src/view.zig renderDiff`: `in_sel` ブロックで `>` prefix を付けてから `sel_style.render`。
  ANSI を含まない `>` を前置することで `zz.width` / `zz.measure.truncate` の桁計算が
  +1 されるだけで、既存の `fitPane` ロジックは破綻しない（行全体が +1 桁になり、
  ペイン幅を超えるときは `truncate` が ANSI を割らずに切り詰める）。
- `src/view.zig renderStatus`: hint 文字列の生成部で `[SELECT]` を挿入。

### 2.4 エッジケース
- anchor が `@@` ヘッダ行や file_header に設定される: `validateAnchor` により diff_loaded 時に
  null 化済み（2026-06-18 修正）。`select_hunk` が本文行へ設定するので整合。
- focus != .diff のとき: `in_sel` 計算が `model.focus == .diff` でゲートされるので表示無し。
  ステータスバーの `[SELECT]` も同様。
- ハンク無し（空 diff）: `selectionRange` は cursor/anchor ともに 0 となり、本文行 0 のため
  `in_sel` に入る行が存在しない。安全。

### 2.5 テスト
- 純粋層としてのテストは既存の `selectionRange` が担保。view の描画は zigzag 依存で
  自動 test 無し（`refAllDecls` のみ）。手動 pty 検証（tmux capture-pane）で確認。

---

## 3. タスク B: rename+modify の staged diff 表示補足

### 3.1 観察と Goal
`2 RM`（rename staged + content modify unstaged）で部分 stage すると、HEAD に新パスが
存在しないため `git diff --cached` が `new file mode` になる。git の仕様だが、diff ペインで
見たユーザが「ファイル全体が stage された」と誤認しやすい。実際の index 内容は部分 stage 結果で正しい。

**Goal**: diff ペイン先頭に rename context（`oldname → newname`）と「content partial」を明示し、
誤認を防ぐ。

### 3.2 設計
- **純粋判定関数** `isRenamePartialState(model) bool` を新設（テスト容易化のため分離）:
  - 戻り値 `true` の条件（全て AND）:
    1. `model.files.items.len > 0 and model.selected < model.files.items.len`
    2. 現在選択中の `FileItem.section == .staged`
    3. 現在選択中の `FileItem.orig_path != null`
    4. **同 `path` を持つ `.unstaged` エントリが `model.files` 内に存在する**
  - 条件 4 は「`2 R.`（rename+内容変更が両方 staged・unstaged 無し）」と「`2 RM`（rename staged +
    content modify unstaged）」を区別するための必須条件（subagent 指摘・`status.zig` parse 仕様）。
- **メタ行挿入**: `view.renderDiff` で `isRenamePartialState` が真のとき、diff_text の先頭に
  `[rename staged: <orig> → <path> · content partial]` 行を**描画時のみ**挿入する。
  `model.diff_text` 自体には触れない（→ `diffLineCount` / `clampScroll` / `ensureVisible` との
  不整合を回避）。
- **fitPane の高さクランプ**: メタ行 +1 された出力は fitPane が `r.h` 行へ切り詰めるため、
  メタ行が最終行として表示される（diff 末尾の数行が隠れることがあるが実害軽微）。

### 3.3 実装箇所
- `src/model.zig`: `pub fn isRenamePartialState(model: *const Model) bool` を追加（純粋）。
- `src/view.zig renderDiff`: 先頭行としてメタ行を組み立て、`diff_text` の行と結合して返す。
  メタ行は reverse 等の装飾無し（素のテキスト。fitPane の切り詰め対象）。

### 3.4 エッジケース（`status.zig` parse 仕様に基づく）
| porcelain | 展開後エントリ | section | orig_path | 同 path unstaged? | メタ行 |
|---|---|---|---|---|---|
| `2 RM` | staged: new.txt | .staged | old.txt | 有 | **出す**（target） |
| `2 RM` | unstaged: new.txt | .unstaged | null | - | 出さない（section 違い） |
| `2 R.` | staged: new.txt | .staged | old.txt | 無 | 出さない（完全 stage） |
| `2 .R` | unstaged: new.txt | .unstaged | old.txt | - | 出さない（section 違い） |
| `1 AM` | staged: f.txt | .staged | null | 有 | 出さない（orig_path null） |
| `1 M.` | staged: f.txt | .staged | null | 無 | 出さない |

`2 CR`/`2 RC` 等、XY のいずれかが `'R'` または `'C'` のレコードは、その側（staged 側なら X、
unstaged 側なら Y）が `'R'`/`'C'` のとき orig_path を持つ（`status.zig` `appendOrdinary` の
`is_x_rename`/`is_y_rename` 判定）。よって `2 CR`（X='C' copy staged, Y='R' rename unstaged）等の
変種も、staged 側が orig_path を持てば本メタ行対象になり得る。

### 3.5 テスト
- `src/model.zig` に `isRenamePartialState` の単体テストを追加（上記表の全ケースを網羅）。
- `2 RM` 部分 stage シナリオの e2e（手動 pty）でメタ行表示を確認。

---

## 4. タスク C: Ctrl+S README 注意書き追加

### 4.1 設計
- README.md の操作キー表の `Ctrl+S` 行に注意書きを追記:
  > 一部の端末では `Ctrl+S` がフロー制御（XOFF）に捕捉されます。`stty -ixon` を実行して
  > 無効化できます（シェル起動ファイルに追記すると恒久化されます）。
- コード変更無し。`input.zig` の `ctrl_s` → `request_commit` マッピングは維持。

### 4.2 代替キーの扱い
`Ctrl+Enter` 等の代替キー追加は zigzag の `KeyEvent` サポート次第のため本 spec では見送る。
将来 TODO として残す（README の注意書きのみで十分機能する）。

---

## 5. タスク D: `#` / `H` でハンク全体選択ショートカット

### 5.1 観察と Goal
行レンジ選択は `v` + `j` 繰り返しだが、ハンク全体を一度に stage する操作があると
lazygit 等からの移行ユーザに馴染む。

**Goal**: 
- `#`（select_hunk）: 現在ハンクの本文全体を選択範囲に設定（2 キー操作: `#` → `s`）
- `H`（stage_hunk）: 即 stage（1 キー操作。lazygit の `a`/`space` 相当）

### 5.2 設計
#### 5.2.1 新規 Msg バリアント
`src/messages.zig`:
```
select_hunk,   // diff フォーカス時 # （現在ハンク本文全体を選択範囲へ）
stage_hunk,    // diff フォーカス時 H （現在ハンクを即 stage/unstage）
```
- ペイロード無し。`Msg.deinit` の解放不要グループ（`key_down` 等と同列）へ追加。
- 網羅的 switch によりコンパイラが新バリアントの解放判断を強制するため、解放不要を明示するだけ。

#### 5.2.2 hunk.zig ヘルパ追加
`src/diff/hunk.zig`:
- 既存 `hunkBodyTop(h)` と対になる `hunkBodyBottom(parsed, h_index) usize` を追加。
  - ハンク本文の**最終本文行**（`@@` ヘッダを除く）の絶対行番号を返す。
  - `line_count <= 1`（本文 0 行の退化ハンク）の場合は `start_line` を返す（呼び出し側ガードで弾く）。
  - 実装: `abs = h.start_line + h.line_count - 1` から `abs > h.start_line` の間 `abs -= 1` で
    逆走し、行頭が `' '`/`'+'`/`'-'`/`'\\'` のいずれか（本文行）なら返す。
    `@@` ヘッダ行は `abs == h.start_line` でループ上限にするため本文 0 個の退化ハンクでは
    `start_line` へ退化（安全フォールバック）。**`isBodyLine`（update.zig private）は使わない**
    （hunk.zig から見えないため、`hunk.zig` 内で本文判定は行頭文字で直接行う）。
- 既存 `hunkIndexForLine` を再利用。本文判定は `hunk.zig` ローカルで完結（行頭 prefix チェック）。

#### 5.2.3 update.zig の arm 実装
- **`select_hunk` arm**:
  1. `hunk.parse` して `parsed` を組み立て（defer deinit）。
  2. **空 diff ガード**: `parsed.hunks.len == 0` なら `return .none`（panic 回避・subagent 指摘）。
  3. `hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse 0` で現在ハンク index を取得。
  4. `top = hunkBodyTop(parsed.hunks[idx])`, `bot = hunkBodyBottom(parsed, idx)` を計算。
  5. `model.focus = .diff`, `model.diff_anchor = top`, `model.diff_cursor = bot` をセット。
  6. `return .none`。
- **`stage_hunk` arm**:
  1. `hunk.parse` して `parsed`（defer deinit）。
  2. **空 diff ガード**: `parsed.hunks.len == 0` なら `return .none`。
  3. **busy ガード**: `model.busy` なら `return .none`。
  4. **rename ガード**: 現在ファイルの `f.orig_path != null` なら既存 stage_lines と同じ
     エラーメッセージをセットして `return .none`。
  5. select_hunk と同じ選択セット（top/bot 計算 → anchor=top, cursor=bot）を実行。
  6. **共通ヘルパ** `buildStagePatchFromSelection(model, parsed, idx, sel) !AppCmd` を呼び、
     得られた AppCmd を返す（stage_lines arm からも同じヘルパを呼ぶようリファクタリング）。
  7. `model.diff_anchor = null`（成否に関わらず選択消費）。

#### 5.2.4 共通ヘルパ抽出
`buildStagePatchFromSelection` を `src/update.zig` の private fn として新設:
- 入力: `*Model`, `parsed: hunk.ParsedDiff`, `idx: usize`, `sel: {lo,hi}`。
- 処理: 既存 `.stage_lines` arm の `buildLinePatch` 呼び出し + `apply_patch` リテラル構築を
 そのまま移管（errdefer 二重ガード含む）。
- 戻り値: `AppCmd`（`.apply_patch` または `.none` + error_text セット）。
- `.stage_lines` arm と `.stage_hunk` arm の両方から呼ぶ。重複コードとデットコード化を防止。

#### 5.2.5 input.zig のキーマップ
diff フォーカス時の `char` switch へ追加:
- `'#'` → `.select_hunk`
- `'H'` → `.stage_hunk`
- 既存の `']'`/`'['`/`'v'` と同列。`H`/`#` は現状マッピングで未使用（確認済み）。

### 5.3 エッジケース
- **空 diff**: 両 arm が `hunks.len == 0` ガードで `.none` 返却。panic 無し。
- **本文行 0 個の退化ハンク**（`line_count==1`）: `hunkBodyBottom` が `start_line` を返す。
  `top == bot == start_line` となり、`isBodyLine(start_line) == false`（@@ ヘッダ）のため
  `buildLinePatch` は `kept_changes == 0` → `null` → 既存のエラーメッセージで案内。安全。
- **cursor が @@ ヘッダ行にある状態**: `hunkIndexForLine` は @@ 行にも non-null を返す
  （`[start_line, start_line+line_count)` に含まれるため）。`#`/`H` 押下でそのハンクの
  本文先頭/末尾へ正しくジャンプする。
- **rename + modify の unstaged エントリ**（`2 RM`・`orig_path=null` の unstaged 側）:
  `f.orig_path != null` ガードを通過するため `#`/`H` ともに動作（既存 stage_lines と同じ挙動）。
- **`2 .R` worktree rename**（`orig_path != null` の unstaged 側）: ガードでブロック、
  エラーメッセージ表示（既存 stage_lines と同じ）。
- **No-newline 境界の tracked diff**: `buildLinePatch` が null を返す（safe no-op）ケースは
  既存のエラーメッセージ「選択範囲を stage できません（変更行なし、または末尾改行境界）」で案内。
- **auto-refresh 中の select_hunk 後**: `validateAnchor`（Bug 1 層 2）が anchor=本文先頭、
  cursor=本文末尾ともに同ハンク本文行のため保持する（Bug 1 e2e と同様に検証）。

### 5.4 テスト（純粋層 TDD）
`src/update.zig` へ追加:
- `test "hunkBodyBottom returns last body line"`（hunk.zig 側）
- `test "hunkBodyBottom on degenerate hunk (line_count==1) returns start_line"`（hunk.zig 側）
- `test "select_hunk sets anchor=body top, cursor=body bottom, focus=diff"`
- `test "select_hunk on empty diff (no hunks) is no-op"`
- `test "stage_hunk builds apply_patch for whole hunk body"`
- `test "stage_hunk on empty diff is no-op"`
- `test "stage_hunk respects rename guard (orig_path != null)"`
- `test "stage_hunk respects busy guard"`
- `test "select_hunk followed by auto-refresh preserves anchor (Bug 1 e2e analog)"`

---

## 6. 実装順序

「純粋層 TDD → UI 配線」の順（`CLAUDE.md` 準拠）。

1. **messages.zig**: `select_hunk`, `stage_hunk` バリアント追加 + `deinit` の解放不要グループへ。
2. **diff/hunk.zig**: `hunkBodyBottom` 追加 + テスト。
3. **update.zig**: 
   - `buildStagePatchFromSelection` 共通ヘルパ抽出（既存 `.stage_lines` arm をリファクタ）。
   - `.select_hunk`, `.stage_hunk` arm 実装 + テスト。
4. **input.zig**: diff フォーカス時 `#`/`H` マッピング。
5. **model.zig**: `isRenamePartialState` 純粋関数 + テスト。
6. **view.zig**: 
   - `renderDiff`: `>` prefix + reverse（タスク A）、メタ行挿入（タスク B）。
   - `renderStatus`: `[SELECT]` 表示（タスク A）。
7. **README.md**: `Ctrl+S` 注意書き（タスク C）、`#`/`H` キーマップ表追記（タスク D）。
8. **TODO.md**: 4 タスクのチェックボックスを `- [x]` 化。

各ステップで `zig build test --summary all` を実行し、全テスト green を維持。

---

## 7. 受け入れ基準

- `zig build test --summary all` が全テスト green。
- `zig build` が型検査通過。
- 実機 pty 検証（tmux capture-pane）で以下を確認:
  - `v` 押下で `[SELECT]` がステータスバーに出る、範囲行に `>` prefix が付く。
  - `2 RM` 部分 stage でメタ行 `[rename staged: old → new · content partial]` が出る。
  - `#` 押下で現在ハンク全体が選択され `s` で stage できる。
  - `H` 押下で現在ハンクが即 stage される。
  - 空 diff で `#`/`H` を押してもクラッシュしない。
- README のキーマップ表に `Ctrl+S` 注意書き、`#`/`H` が追記されている。
- TODO.md の該当 4 チェックボックスが `- [x]` になっている。

---

## 8. リスクと mitigation

- **タスク A の `>` prefix による既存テスト破壊**: view のテストは `refAllDecls` のみで
  描画文字列を検証しないため、既存テストは破壊されない。fitPane の切り詰め計算は +1 桁で
  収まる（ANSI を含まない `>` のため）。
- **タスク B のメタ行による表示行数ズレ**: `model.diff_text` に触れないため
  `diffLineCount`/`clampScroll`/`ensureVisible` は影響無し。fitPane の高さクランプが吸収。
- **タスク D の既存 stage_lines への回帰**: `buildStagePatchFromSelection` 抽出時に
  既存の `.stage_lines` arm テスト（Bug 1 e2e 含む）が全て green であることを以て回帰無しを保証。
- **タスク D の auto-refresh との整合**: select_hunk/stage_hunk で設定した anchor/cursor が
  `validateAnchor` で保持されることを Bug 1 e2e analog テストで検証。
