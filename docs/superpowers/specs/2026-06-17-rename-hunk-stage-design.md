# rename ファイルのハンク stage 設計（TODO 1 phase 2 完了: rename + modify の部分 stage）

- 日付: 2026-06-17
- 対象: `TODO.md` TODO 1「部分ステージング（ハンク / 行単位）」の最後の未対応サブタスク
  `[ ] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）`。
- 前提: phase 1（ハンク単位 stage/unstage）・phase 2 行単位（`buildLinePatch`）・既知の制約 3-5
  （worktree/submodule の `git_dir` 解決・`diff_scroll` クランプ・MouseEvent factoring）・
  untracked ハンク stage（2026-06-17 完了）は全て完了済み。
- **対象外（別件）**:
  - 行単位選択の高度化（discontiguous 選択・ドラッグ範囲拡張・Shift クリック）。
    TODO 1「行単位 stage の phase 2 で未対応（さらに将来）」に既出・据え置き。
  - **`2 .R` / `2 .C`（worktree 側 rename/copy で staged 側は無変更）の部分 stage**。
    porcelain の `Y='R'/'C'` に対応する unstaged エントリは `orig_path != null` になり、現行ガードでブロックされる。
    diff が `rename from/to` ヘッダを含むため、部分パッチ生成の検証が未実施（本 spec の実証実験は `2 RM`/`2 R.` のみ）。
    実用上も稀（index 未反映の worktree rename）のため、本 spec ではガードを維持してファイル単位 stage を案内する。
    将来 spec で個別に実証してから対応する。
  - **staged 側の rename+modify 部分行 unstage**（`2 R.` で内容ハンクも staged な状態からの
    行/ハンク単位 unstage）。実証実験（§2 実験 3）で git 自体の `apply --cached --reverse` が
    安定しないことを確認したため、本 spec では **staged rename 側の `stage_lines` は従来通り
    ファイル単位 unstage（`toggle_stage`）を案内するガードを残す**。詳細は §2 実験 3・§3.1。
- 親 spec:
  - `docs/superpowers/specs/2026-06-14-git-tui-design.md`（全体アーキテクチャ）
  - `docs/superpowers/specs/2026-06-15-partial-staging-hunk-design.md`（phase 1: apply_patch の導入）
  - `docs/superpowers/specs/2026-06-16-line-staging-design.md`（行単位: diff_cursor/anchor/buildLinePatch）
  - `docs/superpowers/specs/2026-06-17-todo1-known-constraints-design.md`（git_dir・diff_scroll クランプ）
  - `docs/superpowers/specs/2026-06-17-untracked-hunk-stage-design.md`（untracked: `--no-index` 部分作成）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（食い違う場合はノート優先）

## 1. ゴールとスコープ

### Goal

rename（および copy）と同時に発生する内容変更のうち、**頻出パターン（rename は staged、
内容変更は unstaged = porcelain `2 RM`）**について、tracked ファイルと同じ操作感
（`j/k` で行移動・`v` で選択・`s` で stage）で部分 stage できることを**保証・固定化**する。

### スコープ（やること）

- **`2 RM`（rename staged + 内容変更 unstaged）の部分 stage が現状で既に動くこと**を、
  パーサ・モデル・reducer・結合テストで回帰不能に固定化する。
  これが実用上のほぼ全てのケース（`git mv` 直後に内容も触った、または `git mv` を経ずに
  エディタで rename + 編集して `git add` していない状態）。
- 部分 stage 後の状態遷移（`2 RM` → `2 R.`）を既存の `replaceFiles` 挙動で取り回すことを検証する。

### スコープ外（やらないこと）

- **`2 .R` / `2 .C`（worktree rename/copy で staged 側は無変更）の部分 stage**:
  porcelain `Y='R'/'C'` に対応する unstaged エントリは `orig_path != null` になり現行ガードでブロックされる。
  diff が `rename from/to` ヘッダを含み、部分パッチ生成の検証が未実施のため、本 spec ではガード維持。
- **staged rename + modify の部分行/ハンク unstage**: `2 R.` で内容ハンクも staged な状態から
  行/ハンク単位で unstage する操作。実証実験（§2 実験 3）で git 自体の `apply --cached --reverse` が
  index の old 側パス解決に失敗し安定しないことを確認。実用上も稀（ユーザが rename と内容変更を
  一括 `git add` した後、一部だけ unstage し直す）ため、本 spec では **staged rename 側の
  `stage_lines` を従来通りガード**し、ファイル単位 unstage（`toggle_stage`）を案内する。
  これは本タスクを「完了」扱いするにあたっての**残された既知の制約**として TODO.md の留意点に明記する。
- 純粋 rename のみ（内容変更なし）の明示処理: `@@` 行が無く `hunks.len == 0` で既存 no-op のため。
- discontiguous 選択・ドラッグ範囲拡張・Shift クリック（TODO 1「さらに将来」項目）。
- `AppCmd` / `Msg` の新規バリアント追加・UI 変更: 不要。

## 2. 実証実験（設計判断の根拠）

untracked ハンク stage の spec と同様、本 spec の核心も実 git での実証実験で確定した。
主要な発見:

### 実験 1: `2 RM`（rename staged + 内容変更 unstaged）が実用上のほぼ全て

`old.txt`（10 行）を `git mv old.txt new.txt` し、その後内容の一部（`b`→`X`）を編集した状態
（`git add -A` は未実行）:

```
$ git status --porcelain=v2 -z | tr '\0' '\n'
2 RM N... 100644 100644 100644 92dfa21 92dfa21 R100 new.txt
old.txt

$ git -c core.quotePath=false diff --cached -- new.txt old.txt
diff --git a/old.txt b/new.txt
similarity index 100%
rename from old.txt
rename to new.txt

$ git -c core.quotePath=false diff -- new.txt
diff --git a/new.txt b/new.txt
index 9405325..6fe8acc 100644
--- a/new.txt
+++ b/new.txt
@@ -1,5 +1,5 @@
 a
-b
+X
 c
 d
 e
```

- porcelain の `2 RM` を `replaceFiles` が 2 エントリへ展開するが、**それぞれの `orig_path` の有無は
  porcelain の X/Y フラグに依存する**（`src/git/status.zig` の `appendOrdinary` で `is_x_rename`/`is_y_rename` が判定）:
  - **staged 側**（X='R'）: `is_x_rename=true` → `orig_path = old.txt` を持つ `2 R.` 相当エントリ。
  - **unstaged 側**（Y='M'）: `is_y_rename=(M=='R' or M=='C')=false` → **`orig_path = null`** の `2 .M` 相当エントリ。
- この `orig_path == null` が決定的: 現行の `update.zig` ガード `if (f.orig_path != null)`
  （`src/update.zig:169`）は **`2 RM` の unstaged エントリでは発火しない**。
  つまり `git mv` + unstaged 内容変更の部分 stage は**現状のコードで既に動作する**。
- **staged 側**（`2 R.` 相当・`orig_path != null`）: ガードが発火し「ファイル単位で stage してください」と案内。
  これは純粋 rename（内容ハンク無し・`hunks.len == 0`）と、rename + 内容変更の一括 add（`2 R.`・内容ハンクあり）
  の両方を含む。後者の部分 unstage は §2 実験 3 の通り git が安定しないため、ガード維持が正しい。
- **unstaged 側**（`2 .M` 相当・`orig_path == null`）: ガードを抜け、rename ヘッダを含まない
  単純 `a/new.txt b/new.txt` diff に対して `buildLinePatch` が走る。
  `git mv` の時点で rename は index 済みのため、index の old 側は既に `new.txt` を指し、
  worktree との差分は rename 行無しの content-only diff になる。

### 実験 2: unstaged 側の部分 stage は `git apply --cached` がそのまま受理する

実験 1 の unstaged diff から、（`b`→`X`）変更のみを含む部分パッチ（rename ヘッダ無し・`new.txt` 単体）を
`git apply --cached` で適用:

```
$ cat /tmp/f.patch
diff --git a/new.txt b/new.txt
index 9405325..6fe8acc 100644
--- a/new.txt
+++ b/new.txt
@@ -1,5 +1,5 @@
 a
-b
+X
 c
 d
 e
$ git apply --cached /tmp/f.patch && echo OK
OK
$ git status --porcelain=v2 -z | tr '\0' '\n'
2 R. N... 100644 100644 100644 92dfa21 e976cfb R90 new.txt
old.txt
```

- exit 0 で受理。`2 RM` が `2 R.`（rename + 内容変更が両方 staged）へ遷移する。
  `replaceFiles` が次回 status 取得で `2 R.` を staged 単体エントリへ展開する既存経路で吸収。
- **結論**: 既存 `buildLinePatch`/`buildPatch` が `a/new.txt b/new.txt` 形式のパッチを生成するため、
  **コード変更は不要**。`2 RM` の部分 stage は現状の `update.zig` ガード（`orig_path != null`）を
  そのまま通過する。本タスクの実装は「テスト追加による回帰保護」と「TODO.md 更新」のみ。

### 実験 3: staged rename+modify の部分 unstage は git 自体が安定しない（対象外の理由）

`old.txt` を `git mv new.txt` し、内容の `b`→`X` と `d`→`Y` を両方 `git add -A` で staged にした状態
（porcelain `2 R.`・内容ハンク 2 つ staged）から、（`d`→`Y`）だけを `apply --cached --reverse` で unstage する試行:

```
$ git -c core.quotePath=false diff --cached
diff --git a/old.txt b/new.txt
similarity index 80%
rename from old.txt
rename to new.txt
index 92dfa21..e1da833 100644
--- a/old.txt
+++ b/new.txt
@@ -1,7 +1,7 @@
 a
-b
+X
 c
-d
+Y
 e
 f
 g

$ git apply --cached --reverse /tmp/r3.patch   # rename 行を保持した部分パッチ
REVERSE OK
$ git status --porcelain=v2 -z | tr '\0' '\n'
1 MD N... 100644 100644 000000 92dfa21 e976cfb old.txt
? new.txt
```

- `apply --cached --reverse` 自体は exit 0 だが、**結果の index 状態が破綻する**: `old.txt` が index に
  復活し（`1 MD`）、`new.txt` が untracked（`?`）になる。rename が取り消された上で内容ハンクだけが
  部分適用されるため、ユーザの意図（rename は staged のまま (d->Y) だけ unstage）と一致しない。
- `old.txt` など rename ヘッダを省いて `a/new.txt b/new.txt` で逆適用しようとすると `patch failed` になる
  （index の old 側が `old.txt` に戻れないため）。どちらの経路も安定しない。
- **結論**: staged rename+modify の部分行/ハンク unstage は git の `apply --cached --reverse` のレベルで
  意図通りの結果を得られない。本 spec では **staged rename 側（`f.orig_path != null && f.section == .staged`）
  の `stage_lines` はガードを残し**、ファイル単位の unstage（`toggle_stage` → `git restore --staged`）を案内する。
  実用上も稀な操作（一括 add した rename+modify の一部だけを unstage し直す）のため、
  これを本タスクの「完了」を阻ぐ制約とはしない。TODO.md 留意点へ明記する。

## 3. 変更点

### 3.1 ソースコード — 変更なし

レビュー（subagent + codex、2026-06-18）で判明した本 spec の核心:
**`2 RM`（rename staged + 内容変更 unstaged）の部分 stage は現状のコードで既に動作する**。

根拠（`src/git/status.zig` `appendOrdinary`）:
- porcelain `2 RM` の X='R' は `is_x_rename=true` → staged エントリに `orig_path = old.txt`。
- 同 Y='M' は `is_y_rename=(M=='R' or M=='C')=false` → **unstaged エントリは `orig_path = null`**。
- `src/update.zig:169` の現行ガード `if (f.orig_path != null)` は `orig_path == null` の unstaged エントリで発火せず、
  そのまま `buildLinePatch(..., reverse=false)`（`f.section == .unstaged`）へ進む。
- `src/git/commands.zig:35-37` で `orig_path == null` のため `git diff -- new.txt`（単体パス）が走り、
  index が既に rename 済みなので rename 行を含まない content-only diff が得られる（§2 実験 1）。
- 既存 `buildLinePatch`/`buildPatch` は標準 tracked diff と同形のこの diff を処理済み。

したがって **ソースコードの変更は一切不要**。当初案だった「ガードを `f.section == .staged` で絞る」変更は
**破棄**する（`2 .R`/`2 .C` の未検証パスを開放してしまうリスクがあるため）。

### 3.2 ガードメッセージ — 変更しない

現状ガードのメッセージ「rename はファイル単位で stage してください」は、`2 .R`（worktree rename）・
`2 R.`（staged rename）の両方に当たる。後者は「unstage」が正しいが、メッセージを状況依存にするには
`std.fmt.allocPrint` で組んだ文字列を `setStr`（dup して保持）へ渡す必要があり、`allocPrint` 結果の
所有権管理が余分に発生する。本タスクの核心（回帰保護）と無関係なため、**メッセージは現状維持**。
改良が必要なら別 PR で `setStrOwned` のようなヘルパを追加してから行う。

### 3.3 純粋層（`src/diff/hunk.zig`・`src/git/commands.zig`・`src/messages.zig`・`src/appcmd.zig`）— 変更なし

- `hunk.parse` / `buildPatch` / `buildLinePatch`: `2 RM` の unstaged 側 diff は rename 行を含まないため、
  他の tracked ファイルと完全同形で処理される。既存テストがカバー。
- `commands.diffArgv`: `orig_path == null` で `git diff -- new.txt`（単体）を生成済み。

### 3.4 テスト追加

各テストは実装 `.zig` 内の `test {}` ブロックへ（CLAUDE.md テスト規約）。

- **`src/git/status.zig`**（パーサ・回帰保護の要）:
  - `2 RM`（X='R', Y='M'）レコードが、**staged エントリは `orig_path = old.txt` を持ち、
    unstaged エントリは `orig_path = null` であること**を検証する新規テスト。
    これが本タスクの核心不変条件（現行ガードが `2 RM` の unstaged 側を通す根拠）。
    既存テスト `parses rename (type 2)` は `2 R.`（X='R', Y='.'）のみで `2 RM` をカバーしていないため必須。
- **`src/diff/hunk.zig`**（純粋層ユニット）— **新規テスト不要**:
  unstaged rename 側の diff（実験 1）は `--- a/new.txt\n+++ b/new.txt\n` 形式の標準 tracked diff と
  構造が完全同一のため、既存の `buildLinePatch stage(forward)` テスト（`src/diff/hunk.zig:336`）が
  この経路をカバーしている。純粋層へ追加コード・テストなし。
- **`src/update.zig`**（reducer）:
  - `stage_lines` が **`2 RM` 由来の unstaged エントリ**（`orig_path == null && section == .unstaged`）上で
    `apply_patch`（`reverse=false`）を発行すること（現行ガードを通ることを固定化）。
  - `stage_lines` が **staged rename エントリ**（`orig_path != null && section == .staged`）上で
    `.none` を返し `error_text` にガイドメッセージが設定されること（ガード維持を検証）。
  - `stage_lines` が **`2 .R` unstaged エントリ**（`orig_path != null && section == .unstaged`）上でも
    `.none` でガードされること（§1 対象外の `2 .R` が開放されないことを固定化・リスク A の防御）。
- **`src/appcmd.zig`**（実 git サブプロセス結合）:
  - `apply_patch` が `git mv old.txt new.txt` + unstaged 内容変更を再現したリポジトリで、
    部分パッチ（`new.txt` 単体・rename 行無し）の forward 適用に exit 0 で成功し、
    porcelain v2 が `2 RM` → `2 R.` へ遷移すること（実験 2 の検証）。

## 4. リスクと検証

- **リスク A（ガードの意図せぬ緩和）**: 当初案の `f.section == .staged` 絞り込みは破棄した。
  これにより `2 .R`/`2 .C`（worktree rename/copy・`orig_path != null`）の unstaged エントリは
  引き続きガードでブロックされる。部分パッチが rename ヘッダを含むこれらのケースは未検証のため、
  ガード維持が正しい。`update.zig` のテストでこのブロック挙動を固定化する（§3.4）。
- **リスク B（staged rename 部分.unstage を諦めることの影響）**: `2 R.`（rename + 内容変更が両方 staged）
  から一部だけ unstage したいユーザにはファイル単位 unstage を案内する。これは `toggle_stage` で
  `git restore --staged -- new.txt old.txt` が走り、rename も内容変更も両方 unstaged（`2 RM`）へ戻る。
  ユーザはその後、必要な内容だけを再度部分 stage できる。デグレードではなく、安全な代替経路の案内。
- **リスク C（`2 RM` の既存動作が将来のリファクタで壊れる）**: 本タスクの核心は回帰保護。
  `status.zig` の `is_y_rename` 判定や `update.zig` のガードが将来変更されても、§3.4 のテストが
  「`2 RM` の unstaged 側が `orig_path == null` でガードを通る」ことを検査する。
- **手動検証**: 省略。実サブプロセス結合テスト（`appcmd.zig`）が実 git で状態遷移まで検証するため。

## 5. TODO.md の更新

- サブタスク `[ ] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）` を `[x]` へ。
- 「留意点」へ追記:
  > **rename + modify の部分 stage は `2 RM`（rename staged + 内容変更 unstaged）が対象で、現状で既に動作する**。
  > porcelain `2 RM` を `status.parse` が展開した unstaged エントリは `Y='M'` なので `orig_path == null` になり、
  > `update.stage_lines` の `orig_path != null` ガードを通過する。`git mv` 時点で rename は index 済みのため、
  > unstaged 側 diff は `new.txt` 単体の content-only diff になり、tracked ファイルと完全同形で処理される
  > （実証実験 2026-06-17）。本タスクは回帰テスト追加のみで完了。
  > **既知の制約1（`2 .R` / `2 .C` worktree rename の部分 stage）**: porcelain `Y='R'/'C'` に対応する
  > unstaged エントリは `orig_path != null` でガードブロック。diff が rename ヘッダを含むため未検証。
  > 将来 spec で実証してから対応。ファイル単位 stage で回避可能。
  > **既知の制約2（staged rename+modify の部分行 unstage）**: `2 R.`（rename + 内容変更が両方 staged）
  > からの行/ハンク単位 unstage は、git 自体の `apply --cached --reverse` が index の old 側パス解決で
  > 破綻するため本ツールでもサポートしない（ガードでファイル単位 unstage を案内）。
  > ファイル単位 unstage 後に再 stage で回避すること。
