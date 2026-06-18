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
  - **staged 側の rename+modify 部分行 unstage**（`2 R.` で内容ハンクも staged な状態からの
    行/ハンク単位 unstage）。実証実験（後述）で git 自体の `apply --cached --reverse` が
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
（`j/k` で行移動・`v` で選択・`s` で stage）で部分 stage できるようにする。

### スコープ（やること）

- **unstaged rename + modify**（`2 RM` → `replaceFiles` が `2 .M` の unstaged エントリへ展開後）:
  `git diff -- new.txt` の単純 content diff を行/ハンク単位で部分 stage。
  これが実用上のほぼ全てのケース（`git mv` 直後に内容も触った、または `git mv` を経ずに
  エディタで rename + 編集して `git add` していない状態）。
- 部分 stage 後の状態遷移（`2 RM` → `2 R.`）を既存の `replaceFiles` 挙動で取り回す。

### スコープ外（やらないこと）

- **staged rename + modify の部分行/ハンク unstage**: `2 R.` で内容ハンクも staged な状態から
  行/ハンク単位で unstage する操作。実証実験（§2 実験 3）で git 自体の `apply --cached --reverse` が
  index の old 側パス解決に失敗し安定しないことを確認。実用上も稀（ユーザが rename と内容変更を
  一括 `git add` した後、一部だけ unstage し直す）ため、本 spec では **staged rename 側の
  `stage_lines` を従来通りガード**し、ファイル単位 unstage（`toggle_stage`）を案内する。
  これは本タスクを「完了」扱いするにあたっての**残された既知の制約**として TODO.md の留意点に明記する。
- 純粋 rename のみ（内容変更なし）の明示処理: `@@` 行が無く `hunks.len == 0` で既存 no-op のため。
- discontiguous 選択・ドラッグ範囲拡張・Shift クリック（TODO 1「さらに将来」項目）。
- `AppCmd` / `Msg` の新規バリアント追加・UI 変更: 不要。
- copy (`C`) エントリの個別対応: porcelain 上は rename と同形で `diffArgv` も両パスを渡すため自動的にカバー。
  明示テストは rename (`R`) のみとし、copy は暗黙カバーに留める。

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

- porcelain の `2 RM` を `replaceFiles` が `2 R.`（staged・内容ハンク無し）と `2 .M`（unstaged・`new.txt` 単体）の
  2 エントリへ展開する。既存の展開経路そのまま。
- **staged 側**（`2 R.`）: 内容ハンクが無く `hunks.len == 0`。ユーザがこのエントリを選んで `s` しても
  既存 no-op で何も起きない（純粋 rename の unstage は `toggle_stage` で `git restore --staged` が担う）。
- **unstaged 側**（`2 .M`）: rename ヘッダを含まない単純 `a/new.txt b/new.txt` diff になる。
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
  追加の変換は一切不要。`update.stage_lines` の `orig_path` ガードを **unstaged 側のみ** 緩和すればよい。

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

### 3.1 `src/update.zig` — rename ガードを unstaged 側のみ緩和

現状の `stage_lines` reducer（`src/update.zig:174-177`）:

```zig
if (f.orig_path != null) {
    try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
    return .none;
}
```

を、**staged 側だけ**残して unstaged 側を通す:

```zig
if (f.orig_path != null and f.section == .staged) {
    try model.setStr(&model.error_text, "rename の一部 unstage はファイル単位で行ってください（S キー）");
    return .none;
}
```

- `f.section == .unstaged` かつ `orig_path != null`（`2 .M` エントリ）はガードを抜けて `buildLinePatch` へ。
  `reverse = (f.section == .staged) = false` なので forward（stage）パッチが生成される（実験 2 の経路）。
- `f.section == .staged` かつ `orig_path != null`（`2 R.` エントリ）はガードに引っかかりメッセージ表示。
  内容ハンク無し（`hunks.len == 0`）の純粋 rename もここで案内される（ファイル単位 unstage へ）。
- untracked は `orig_path == null` なので影響しない（既存の untracked ハンク stage 経路はそのまま）。

### 3.2 純粋層（`src/diff/hunk.zig`・`src/git/commands.zig`・`src/messages.zig`・`src/appcmd.zig`）— 変更なし

- `hunk.parse` / `buildPatch` / `buildLinePatch`: rename 行が `file_header` へ入る構造だが、
  unstaged 側の diff（実験 1）は元々 rename 行を含まないため本経路では使われない。
  他の tracked ファイルと完全同形で処理される。
- `commands.diffArgv`: staged/unstaged で `path` と `orig_path` の両方を渡す実装済み。
  unstaged 側では `path = new.txt` が第一引数になり、`git diff -- new.txt old.txt` となるが、
  index が既に rename 済みのため出力は `new.txt` 単体 diff になる（実験 1）。

### 3.3 テスト追加

各テストは実装 `.zig` 内の `test {}` ブロックへ（CLAUDE.md テスト規約）。

- **`src/diff/hunk.zig`**（純粋層ユニット）— **新規テスト不要**:
  unstaged rename 側の diff（実験 1）は `--- a/new.txt\n+++ b/new.txt\n` 形式の標準 tracked diff と
  構造が完全同一のため、既存の `buildLinePatch stage(forward)` テスト（`src/diff/hunk.zig` 既存）が
  この経路をカバーしている。純粋層へ追加コード・テストなし。
- **`src/update.zig`**（reducer）:
  - `stage_lines` が **unstaged rename エントリ**（`orig_path != null && section == .unstaged`）上で
    `apply_patch`（`reverse=false`）を発行すること。
  - `stage_lines` が **staged rename エントリ**（`orig_path != null && section == .staged`）上で
    `.none` を返し `error_text` にガイドメッセージが設定されること（§3.1 のガード残置を検証）。
- **`src/appcmd.zig`**（実 git サブプロセス結合）:
  - `apply_patch` が `git mv old.txt new.txt` + unstaged 内容変更を再現したリポジトリで、
    部分パッチ（`new.txt` 単体・rename 行無し）の forward 適用に exit 0 で成功し、
    porcelain v2 が `2 RM` → `2 R.` へ遷移すること（実験 2 の検証）。

## 4. リスクと検証

- **リスク A（staged rename 部分.unstage を諦めることの影響）**: `2 R.`（rename + 内容変更が両方 staged）
  から一部だけ unstage したいユーザにはファイル単位 unstage を案内する。これは `toggle_stage` で
  `git restore --staged -- new.txt old.txt` が走り、rename も内容変更も両方 unstaged（`2 RM`）へ戻る。
  ユーザはその後、必要な内容だけを再度部分 stage できる。デグレードではなく、安全な代替経路の案内。
- **リスク B（部分適用後の状態遷移）**: `2 RM` → 部分 stage で `2 R.` へ遷移するのみ。
  これは既存 `replaceFiles`（`src/model.zig`）が type2 レコードを staged+unstaged 2 エントリへ展開する
  既存経路で吸収済み。新規の展開ロジックは不要。
- **手動検証**: 省略。実サブプロセス結合テスト（`appcmd.zig`）が実 git で状態遷移まで検証するため。

## 5. TODO.md の更新

- サブタスク `[ ] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）` を `[x]` へ。
- 「留意点」へ追記:
  > **rename + modify の部分 stage は `2 RM`（rename staged + 内容変更 unstaged）が対象**。
  > `git mv` 時点で rename は index 済みのため、unstaged 側 diff は `new.txt` 単体の content-only diff になり、
  > tracked ファイルと完全同形で処理される（実証実験 2026-06-17）。
  > `update.stage_lines` は unstaged 側のみ `orig_path` ガードを緩和し、staged rename 側は
  > ファイル単位 unstage（`S` キー → `git restore --staged`）を案内する。
  > **既知の制約（staged rename+modify の部分行 unstage）**: `2 R.`（rename + 内容変更が両方 staged）
  > からの行/ハンク単位 unstage は、git 自体の `apply --cached --reverse` が index の old 側パス解決で
  > 破綻するため本ツールでもサポートしない。ファイル単位 unstage 後に再 stage で回避すること。
