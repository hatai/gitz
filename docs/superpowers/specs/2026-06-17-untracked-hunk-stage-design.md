# untracked ファイルのハンク stage 設計（TODO 1 phase 2: 新規作成ハンクの部分 stage）

- 日付: 2026-06-17
- 対象: `TODO.md` TODO 1「部分ステージング（ハンク / 行単位）」のうち
  `[ ] untracked ファイルのハンク stage（intent-to-add`git add -N`）（phase 2）`。
- 前提: phase 1（ハンク単位 stage/unstage）・phase 2 行単位（`buildLinePatch`）・既知の制約 3-5
  （worktree/submodule の `git_dir` 解決・`diff_scroll` クランプ・MouseEvent factoring）は全て完了済み。
- **対象外（別 spec）**:
  - rename ファイルのハンク stage（`file_header` の rename 行の扱い）。後続 spec へ分離。
  - 行単位選択の高度化（discontiguous 選択・ドラッグ範囲拡張・Shift クリック）。
    TODO 1「行単位 stage の phase 2 で未対応（さらに将来）」に既出。
- 親 spec:
  - `docs/superpowers/specs/2026-06-14-git-tui-design.md`（全体アーキテクチャ）
  - `docs/superpowers/specs/2026-06-15-partial-staging-hunk-design.md`（phase 1: apply_patch の導入）
  - `docs/superpowers/specs/2026-06-16-line-staging-design.md`（行単位: diff_cursor/anchor/buildLinePatch）
  - `docs/superpowers/specs/2026-06-17-todo1-known-constraints-design.md`（git_dir・diff_scroll クランプ）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（食い違う場合はノート優先）

## 1. ゴールとスコープ

### Goal

untracked ファイル（index 未登録）の変更を行/ハンク単位で部分 stage できるようにする。
tracked ファイルと同じ操作感（`j/k` で行移動・`v` で選択・`s` で stage）を untracked でも提供する。

### スコープ（やること）

- untracked ファイルの diff（`git diff --no-index /dev/null <file>` 出力）を行/ハンク単位で部分 stage。
- 部分 stage 後の状態遷移（`1 AM` = staged + unstaged 混合）を既存の `replaceFiles` 挙動で取り回す。

### スコープ外（やらないこと）

- rename ファイルのハンク stage（後続 spec）。
- `git add -N`（intent-to-add）の導入。本 spec では使わない（後述）。
- discontiguous 選択・ドラッグ範囲拡張・Shift クリック（TODO 1 の「さらに将来」項目）。

## 2. 実証実験（設計判断の根拠）

`docs/superpowers/specs/2026-06-17-todo1-known-constraints-design.md` の git-dir 解決と同様に、
本 spec の核心も実 git での実証実験で確定した。主要な発見:

### 実験 1: `git apply --cached` は index 未登録パスの新規作成ハンクを受理する

手順:
1. untracked の 10 行ファイル `new.txt` を作る。
2. `git diff --no-index /dev/null new.txt` の出力（`--- /dev/null` / `+++ b/new.txt` /
   `@@ -0,0 +1,10 @@` + 全行 `+`）を参考に、**前半 5 行だけ**の部分挿入パッチを手作り:
   ```
   diff --git a/new.txt b/new.txt
   new file mode 100644
   index 0000000..fe6ec40
   --- /dev/null
   +++ b/new.txt
   @@ -0,0 +1,5 @@
   +L1
   +L2
   +L3
   +L4
   +L5
   ```
3. `git apply --cached stage-front.patch` を実行。

結果:
- exit 0（受理）。
- `git diff --cached -- new.txt` が `@@ -0,0 +1,5 @@`（L1-L5 のみ）を返す。
- `git status --porcelain=v2 -z` が `1 AM N...` を返す（index に前半・worktree に全行 = staged+unstaged 混合）。
- worktree は 10 行のまま無傷。

**結論**: `git add -N`（intent-to-add）を前置せずとも、`git apply --cached` 単体で index 未登録パスの
部分作成が可能。TODO.md 記載の `-N` 方式（方式 A）は要件ではなく方式案の一つであり、本方式（B）のほうが
真に簡潔（1 コマンド・状態遷移なし）。

### 実験 2: 現行 `buildLinePatch(reverse=false)` が untracked diff を自然に処理する

現行 `buildLinePatch` の stage(forward) 変換ルールを untracked の全行挿入ハンクに適用した場合の挙動を
トレース・実証した:

| 行種別 | untracked での出現 | `reverse=false` の挙動 |
|---|---|---|
| 選択 `+` | ユーザ選択行 | 保持・`new_count += 1` |
| 未選択 `+` | 残り全行 | `is_add(true) != reverse(false)` = true → **削除**（行ごと落とす） |
| 文脈行 `' '` | 出現しない（全行挿入のため） | 到達不能 |
| `-` 行 | 出現しない（全行挿入のため） | 到達不能 |

結果:
- `old_count = 0` / `new_count = 選択行数`。
- `parseHeader` が原 `@@ -0,0 +1,N @@` から `old_start="0"`, `new_start="1"` を抽出。
- 出力 `@@ -0,0 +1,<sel_count> @@`（実験 1 で成功した形式と完全一致）。
- No-newline 境界も安全: untracked は「文脈化」が発生しないため、`buildLinePatch` の
  「文脈化した行が no-newline 主張 → null」の矛盾判定が発火しない。最終行の `\ No newline` マーカーは
  直前の `+` 行が選択なら保持、未選択なら行ごと落とされる（マーカーも落ちる）。

**結論**: `buildLinePatch` 本体は**一切変更不要**。変更は `update.stage_lines` の untracked ガード削除のみ。

### 実験 3: 部分 stage 後の diff 構造（`1 AM` の取り回し）

untracked 10 行ファイルの L1-L3 を部分 stage した後の状態（commit 無し・`git rm --cached` で index のみ
リセットして再現）:

- staged 側 diff（`git diff --cached`）: `--- /dev/null` → `+++ b/new.txt`、`@@ -0,0 +1,3 @@`（L1-L3 の新規作成）。
- unstaged 側 diff（`git diff`）: index の L1-L3 → worktree の L1-L10、`@@ -1,3 +1,10 @@`（L4-L10 の追加）。
- status: `1 MM` または `1 AM`（部分 stage 後・commit 後で X/Y は変わるが混合状態は同一）。

**結論**: 部分 stage 後は同一ファイルが staged・unstaged の 2 エントリで出る。
`git/status.zig parse` の既存ロジック（`X != '.'` と `Y != '.'` の両エントリ生成）と
`model.replaceFiles` の既存ソート規則で 2 エントリとして整理され、それぞれ個別に `toggle_stage`/
`stage_lines` で操作可能。**本 spec は post-stage 状態の取り回しを一切変更しない。**

## 3. アーキテクチャ（変更箇所）

Elm 風・副作用隔離を踏襲。変更は `update.zig` の 4 行削除 + テスト整備のみ。
他の全ファイル（`appcmd`/`messages`/`model`/`view`/`input`/`main`/`diff/hunk`/`git/*`）は**変更不要**。

| ファイル | 変更 | 行数概算 |
|---|---|---|
| `src/update.zig` | `stage_lines` の `if (f.section == .untracked)` ガード（4 行）を削除。既存テスト書き換え + 新規テスト追加 | -4 +30 行程度 |
| `src/diff/hunk.zig` | **変更不要**。実験 2 で確認。新規テスト 1 件のみ追加 | +25 行程度 |
| `src/appcmd.zig` | **変更不要**。既存 `apply_patch` 経路・`git_dir` 経路がそのまま使える。新規結合テスト 1 件のみ追加 | +55 行程度 |
| `src/messages.zig` | **変更不要** | 0 |
| `src/model.zig` | **変更不要**（`replaceFiles` が `1 AM` を 2 エントリへ展開する既存挙動で吸収） | 0 |
| `src/view.zig` | **変更不要**（`renderDiff` のハイライト・カーソルは既存どおり動く） | 0 |
| `src/input.zig` | **変更不要**（diff ペインの `s`/`space`/`Enter` → `stage_lines` は既存） | 0 |
| `src/main.zig` | **変更不要**（`dispatchSideEffect`/`apply_patch` arm は既存） | 0 |
| `TODO.md` | 該当チェックボックス `[x]` 化・留意点更新 | +数行 |

### 3.1 `src/update.zig`（reducer arm・唯一の実装変更）

現状:

```zig
.stage_lines => {
    if (model.busy) return .none;
    if (model.files.items.len == 0) return .none;
    const f = model.files.items[model.selected];
    if (f.section == .untracked) {
        try model.setStr(&model.error_text, "untracked はファイル単位で stage してください");
        return .none;
    }
    if (f.orig_path != null) {
        try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
        return .none;
    }
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    if (parsed.hunks.len == 0) return .none;
    const idx = hunk.hunkIndexForLine(parsed, model.diff_cursor) orelse return .none;
    const sel = @import("model.zig").selectionRange(model.diff_cursor, model.diff_anchor);
    const maybe = try hunk.buildLinePatch(model.allocator, parsed, idx, sel.lo, sel.hi, f.section == .staged);
    model.diff_anchor = null;
    if (maybe) |patch| {
        errdefer model.allocator.free(patch);
        const gd: ?[]u8 = if (model.git_dir) |g| try model.allocator.dupe(u8, g) else null;
        errdefer if (gd) |x| model.allocator.free(x);
        return .{ .apply_patch = .{
            .patch = patch,
            .reverse = (f.section == .staged),
            .git_dir = gd,
        } };
    }
    try model.setStr(&model.error_text, "選択範囲を stage できません（変更行なし、または末尾改行境界）");
    return .none;
},
```

変更後（untracked ガード 4 行を削除・コメント追記）:

```zig
.stage_lines => {
    if (model.busy) return .none;
    if (model.files.items.len == 0) return .none;
    const f = model.files.items[model.selected];
    // untracked ガード削除（2026-06-17）: buildLinePatch(reverse=false) が --no-index diff の全行挿入を
    //   自然に処理する（未選択 + は削除、選択 + は保持 → @@ -0,0 +1,N @@ の部分挿入パッチ）。
    //   git apply --cached は index 未登録パスも新規作成として受理する（実証実験で確認）。
    //   部分 stage 後は status が 1 AM となり replaceFiles が staged+unstaged 2 エントリへ展開する。
    if (f.orig_path != null) {
        try model.setStr(&model.error_text, "rename はファイル単位で stage してください");
        return .none;
    }
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    // ... 以降は現状どおり（buildLinePatch → apply_patch、変更なし）
},
```

- **rename ガードは残す**: rename は後続 spec で対応するため、従来どおり no-op + ガイダンス。
- **`busy` ゲートは残す**: untracked 操作に限らず全 stage 操作と同じ直列化経路を踏む。
- **`buildLinePatch(..., f.section == .staged)` の呼び出しは不変**: untracked は `.staged` でないため
  `reverse=false` になり、実験 2 で確認した経路が成立つ。
- **`apply_patch` ペイロードも不変**: `git_dir` の dupe・`errdefer` 二重ガードは既存のまま。
- **No-newline マーカーの扱い**: untracked の全行挿入ハンクでは `+` 行は「選択→kept」か「未選択→dropped」の
  2 択のみで `contextified` 状態に到達しないため、`\ No newline` マーカーの `switch (prev)` は `.kept` か
  `.dropped` しか見ない。最終 `+` 行を選択すればマーカーも保持され**有効なパッチ**が出る（`null` ではない）。
  未選択なら行ごと落とされマーカーも落ちる。null-conflict 判定は tracked diff 専門であり untracked では到達不能。

### 3.2 `busy` 中の挙動（既存・変更なし）

- `stage_lines` 冒頭の `if (model.busy) return .none;` を維持。untracked でも tracked でも同一の直列化経路。
- ユーザが untracked で `s` を押したときは `apply_patch` が発行され、main.zig の `dispatchSideEffect`
  → worker スレッドで `git apply --cached` が実行され、結果 `status_loaded` で reducer が戻る。
- `model.working`（スピナ）も既存どおり点灯（`isMutating(.apply_patch) = true`）。

### 3.3 `replaceFiles` の既存挙動で吸収される post-stage 状態

実験 3 で確認した `1 AM` status は、`git/status.zig parse` の既存ロジック（`X != '.'` と `Y != '.'` の
両エントリ生成）と `model.replaceFiles` の既存ソート規則（staged → unstaged → untracked・path 昇順）で
2 エントリとして整理される。両エントリとも既存の `toggle_stage`（ファイル単位）・`stage_lines`（行単位）で
個別に操作可能。**本 spec は post-stage 状態の取り回しを一切変更しない。**

## 4. テスト方針（純粋 + 結合の 2 層）

既存のテスト規約（`test {}` ブロックを同じ `.zig` 内に・`std.testing.allocator` 必須・リーク検出）に従う。

### 4.1 純粋層テスト（`src/diff/hunk.zig` 内・新規 4 件）

`buildLinePatch` が untracked diff（全行挿入）を正しく処理することを pin するテストを追加する。
実装は変更しない（テストのみ）。既存の `buildLinePatch` テスト群（stage forward / unstage reverse /
フルハンク / context-only null / no-newline null / 日本語）が、untracked の全行挿入ハンクを通しても
同じ変換ルールで動くことを実験 2 で確認済み。新規テストは untracked 固有の入力形式（`--- /dev/null`・
全行 `+`・`@@ -0,0`）を pin し、将来のリバートを検出するのが目的。

**4 件追加の理由（レビュー指摘反映）**:
1. **基本**: 部分選択で `@@ -0,0 +1,N @@` が出ることを pin。
2. **フルハンク選択**: 受け入れ基準 2（全行選択 ≈ `git add`）をカバー。`buildLinePatch` 出力が
   `buildPatch` と等価であることを既存の tracked テストと同じ形で検証する。
3. **No-newline 境界**: 受け入れ基準 8（修正後）を pin。最終 `+` 行を選択すればマーカーが保持されて
   有効なパッチが出ること（`null` ではない）を検証。これをテストしないと「文脈化に起因する null」が
   untracked でも起きるとの誤解が再発する恐れがある。
4. **日本語 body**: CLAUDE.md の日本語カバー重視に準拠。untracked 形式入力でも日本語が行単位で
   正しく処理されることを pin する。

#### テスト 1: 部分選択（基本）

```zig
test "buildLinePatch on untracked (--no-index form): only selected + lines, @@ -0,0 +1,N @@" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,4 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n" ++
        "+L4\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // +L2(行7) と +L3(行8) だけ選択して stage。
    const maybe = try buildLinePatch(a, p, 0, 7, 8, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -0,0 +1,2 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L4\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "--- /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+++ b/new.txt") != null);
    try std.testing.expect(patch[patch.len - 1] == '\n');
}
```

#### テスト 2: フルハンク選択（受け入れ基準 2 のカバー）

```zig
test "buildLinePatch on untracked: full-hunk selection equals buildPatch output" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // ハンク本文を丸ごと覆うレンジ（@@ 行〜末尾本文）。
    const h = p.hunks[0];
    const maybe = try buildLinePatch(a, p, 0, h.start_line, h.start_line + h.line_count - 1, false);
    try std.testing.expect(maybe != null);
    const line_patch = maybe.?;
    defer a.free(line_patch);
    const hunk_patch = try buildPatch(a, p, 0);
    defer a.free(hunk_patch);
    // 全行選択なら buildPatch と等価（`git add` 相当の index 状態になることの純粋層での裏付け）。
    try std.testing.expectEqualStrings(hunk_patch, line_patch);
}
```

#### テスト 3: No-newline 境界（受け入れ基準 8 のカバー・最終行選択で有効パッチ）

```zig
test "buildLinePatch on untracked: selected final + line keeps No-newline marker (not null)" {
    const a = std.testing.allocator;
    // 末尾改行無しの untracked 3 行ファイル。最終行にのみ \ No newline マーカー。
    const diff =
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n" ++
        "\\ No newline at end of file\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // 最終行 +L3(行8) のみ選択。L1/L2 は未選択→dropped、L3 は選択→kept、マーカーも prev=.kept で保持。
    // untracked では contextified 状態に到達しないため null-conflict は発火せず、有効パッチが返る。
    const maybe = try buildLinePatch(a, p, 0, 8, 8, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -0,0 +1,1 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "\\ No newline at end of file") != null); // マーカー保持
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+L2\n") == null);
}
```

#### テスト 4: 日本語 body（CLAUDE.md の日本語カバー重視への準拠）

```zig
test "buildLinePatch on untracked with Japanese body: only selected line" {
    const a = std.testing.allocator;
    const diff =
        "diff --git a/日本語.txt b/日本語.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/日本語.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+一行目\n" ++
        "+二行目\n" ++
        "+三行目\n";
    var p = try parse(a, diff);
    defer p.deinit(a);
    // +二行目(行7) だけ選択。
    const maybe = try buildLinePatch(a, p, 0, 7, 7, false);
    try std.testing.expect(maybe != null);
    const patch = maybe.?;
    defer a.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+二行目\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+一行目\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+三行目\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@ -0,0 +1,1 @@") != null);
}
```

### 4.2 Reducer テスト（`src/update.zig` 内・既存 1 件書き換え + 新規 1 件）

#### 既存テストの書き換え

現状の `test "stage_lines guards: untracked / busy"` は untracked を no-op で弾くことを検証しているが、
本変更で untracked は弾かなくなる。テストを 2 つに分割する:

- `test "stage_lines guards: busy"`（既存の busy 部分だけ残す）。
- `test "stage_lines on untracked builds apply_patch (reverse=false) for partial stage"`（下記・新規）。

#### 新規 reducer テスト

```zig
test "stage_lines on untracked builds apply_patch (reverse=false) for partial stage" {
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "new.txt", .untracked);
    try m.setStr(&m.diff_text,
        "diff --git a/new.txt b/new.txt\n" ++
        "new file mode 100644\n" ++
        "index 0000000..0123456 100644\n" ++
        "--- /dev/null\n" ++
        "+++ b/new.txt\n" ++
        "@@ -0,0 +1,3 @@\n" ++
        "+L1\n" ++
        "+L2\n" ++
        "+L3\n");
    m.diff_cursor = 7; // +L2 の絶対行（file_header 5 行 + @@ が行5, +L1=6, +L2=7, +L3=8）
    var cmd = try update(&m, .stage_lines);
    defer cmd.deinit(a);
    try std.testing.expect(cmd == .apply_patch);
    try std.testing.expect(!cmd.apply_patch.reverse);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "+L3\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, cmd.apply_patch.patch, "@@ -0,0 +1,1 @@") != null);
}
```

### 4.3 結合テスト（`src/appcmd.zig` 内・新規 1 件のみ）

既存の `TmpRepo` パターンで、実際の untracked ファイルに対して `apply_patch` が通ることを検証する。
実験 1 で成功した経路そのものを回帰テスト化する。実装は変更しない（テストのみ）。

```zig
test "apply_patch stages a partial hunk of an untracked file (new-file create via --cached)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const hunk = @import("diff/hunk.zig");
    var repo = try TmpRepo.init(a, io);
    defer repo.deinit();
    try repo.writeFile(io, "new.txt", "L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10\n");
    var dmsg = try runOwned(a, io, repo.cwd(), .{ .load_diff = .{
        .path = try a.dupe(u8, "new.txt"), .orig_path = null, .section = .untracked,
    } });
    defer dmsg.deinit(a);
    try std.testing.expect(dmsg == .diff_loaded);
    var parsed = try hunk.parse(a, dmsg.diff_loaded);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.hunks.len >= 1);
    // +L4 と +L6 の絶対行を splitScalar で探す。
    var plus_l4: usize = 0;
    var plus_l6: usize = 0;
    {
        var it = std.mem.splitScalar(u8, dmsg.diff_loaded, '\n');
        var i: usize = 0;
        while (it.next()) |ln| : (i += 1) {
            if (std.mem.eql(u8, ln, "+L4")) plus_l4 = i;
            if (std.mem.eql(u8, ln, "+L6")) plus_l6 = i;
        }
    }
    const maybe = try hunk.buildLinePatch(a, parsed, 0, plus_l4, plus_l6, false);
    try std.testing.expect(maybe != null);
    var msg = try runOwned(a, io, repo.cwd(), .{ .apply_patch = .{
        .patch = maybe.?, .reverse = false,
    } });
    defer msg.deinit(a);
    try std.testing.expect(msg == .status_loaded);
    var has_staged = false;
    var has_unstaged = false;
    for (msg.status_loaded) |e| {
        if (std.mem.eql(u8, e.path, "new.txt")) {
            if (e.section == .staged) has_staged = true;
            if (e.section == .unstaged) has_unstaged = true;
        }
    }
    try std.testing.expect(has_staged and has_unstaged);
    const sd = try stagedDiff(&repo, a, io, "new.txt");
    defer a.free(sd);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L1\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, sd, "+L10\n") == null);
}
```

### 4.4 worktree / submodule との整合性

既存の `apply_patch with git_dir works in a linked worktree` / `works in a real submodule` の 2 件は
tracked ファイルを対象としているが、untracked ファイルでも同一の `apply_patch` 経路を通るため、
これらの回帰テストが「untracked でも `git_dir` 経路が壊れていない」ことを間接的に担保する。
untracked 専用の worktree/submodule 結合テストは追加しない（スコープ膨張を避ける。`apply_patch` 本体が
untracked/tracked で分岐しないため冗長）。

### 4.5 手動検証（tmux pty）

`CLAUDE.md`「TUI の手動検証」に従い、tmux で untracked ファイルを開き `j/k` でハンク行へ移動 →
`v` で選択 → `s` で部分 stage が busy スピナと共に動き、status が `1 AM` に遷移することを目視確認する
（実装完了後）。コマンド例: `tmux new-session -x 120 -y 40` → `send-keys` で `zig build && cd <repo> &&
zig-out/bin/git-tui` → ファイル選択・diff フォーカス・`j/k/v/s` → `capture-pane -p`。

## 5. 受け入れ基準

1. **untracked ファイルの部分行 stage**: 10 行の untracked ファイルのうち L4-L6 の 3 行だけ選択して `s`
   を押すと、その 3 行のみが index に入り、残り 7 行は worktree のみ残る（status `1 AM`）。
2. **untracked ファイルの全行 stage**: 全行選択（`v` で先頭から末尾まで）すると、従来のファイル単位
   `space`/`s`（`toggle_stage` → `git add`）と同等の結果になる（index に全行・status は `A ` または `AM`）。
   パッチの形式が `--- /dev/null` → `+++ b/<file>` の新規作成になる点だけが異なるが、最終状態は同一。
3. **untracked のハンク stage**: `--no-index` diff は通常単一の全挿入ハンクになるため、1 ハンクの一部を
   行選択して stage することが基本ユースケース。複数ハンクにまたがる選択は既存の stage_lines の挙動
   （カーソルの属するハンクにクランプ）に従う。
4. **worktree / submodule でも動く**: 既存の `git_dir` 経路（既知の制約 3 で解消済み）をそのまま使うため、
   untracked の部分 stage も linked worktree・submodule で成功する（既存回帰テストが担保）。
5. **既存の tracked stage/unstage 挙動は不変**: staged・unstaged ファイルの `stage_lines`・`toggle_stage`・
   既存の全 `apply_patch` 結合テストが変更なしで green。
6. **rename ファイルは従来どおり no-op + ガイダンス**: `orig_path != null` のガードは残すため、rename
   ファイルで `s` を押すと従来どおり「rename はファイル単位で stage してください」のエラーメッセージが出る。
7. **エラーを握り潰さない**: 不正なパッチで `git apply --cached` が exit!=0 のとき、既存の `git_error`
   経路で stderr が status バーへ出る（既存の `apply_patch surfaces git_error on a corrupt patch`
   テストが担保）。
8. **No-newline 境界は untracked でも安全**: untracked の全行挿入ハンクでは `+` 行が「選択→kept」か
   「未選択→dropped」の 2 択のみで `contextified` に到達しないため、`\ No newline` マーカーは直前の `+` 行の
   処理に従い保持/削除される。**最終 `+` 行を選択すればマーカーも保持された有効なパッチが出る（`null` ではない）。**
   未選択なら行とマーカーが共に落ちる。`null`（no-op）になるのは「選択された変更行ゼロ」の既存ガードのみ。
   ※「文脈化に起因する no-newline 矛盾の null」は tracked diff 専門（既存テスト `context-ifying a No-newline-owning line yields null`）であり、untracked では到達不能。
9. **busy 中の操作は直列化**: untracked の部分 stage 実行中にもう一度 `s` を押しても、`model.busy` ゲートと
   main.zig の `pending` latest-wins で直列化される（既存の全副作用と同一経路）。

## 6. 実装順（純粋層 TDD → 結合）

1. **`src/diff/hunk.zig`**: untracked 形式入力の `buildLinePatch` テスト 4 件を追加（実装は変更不要・
   テストのみ）: (a) 部分選択の基本、(b) フルハンク選択で `buildPatch` と等価、(c) No-newline 境界で
   最終行選択が有効パッチ（`null` ではない）、(d) 日本語 body。`zig build test` で green を確認。
2. **`src/update.zig`**:
   1. `stage_lines` arm の `if (f.section == .untracked) { ... return .none; }` ブロック（4 行）を削除。
   2. 既存テスト `stage_lines guards: untracked / busy` を busy のみへ縮小（`test "stage_lines guards: busy"`）。
   3. 新規テスト `stage_lines on untracked builds apply_patch (reverse=false) for partial stage` を追加。
3. **`src/appcmd.zig`**: 結合テスト `apply_patch stages a partial hunk of an untracked file` を追加
   （実装は変更不要・テストのみ）。
4. **`zig build test --summary all`**: 全テスト green を確認（Debug 既定・安全チェック維持）。
5. **手動検証（tmux）**: untracked ファイルで `j/k` → `v` → `s` の部分 stage が動くことを目視。
6. **`TODO.md` 更新**: §7 に従い該当チェックボックスを `[x]` 化。

## 7. TODO.md 更新

`TODO.md` の TODO 1「Sub Tasks」セクション:

変更前:

```
- [ ] untracked ファイルのハンク stage（intent-to-add `git add -N`）（phase 2）
```

変更後:

```
- [x] untracked ファイルのハンク stage（phase 2）
  - **方式**: `git add -N`（intent-to-add）ではなく `git apply --cached` 単体で新規作成ハンクを
    直接 apply する（実証実験で受理を確認）。`buildLinePatch(reverse=false)` が `--no-index`
    形式の全行挿入 diff を自然に処理するため、`update.stage_lines` の untracked ガードを削除する
    だけ（`hunk.zig`/`appcmd.zig`/`messages.zig` は一切変更不要）。部分 stage 後は status が `1 AM`
    となり `replaceFiles` が staged+unstaged 2 エントリへ展開する（既存挙動で吸収）。
```

「留意点」セクションの冒頭に追記（`- パッチのコンテキスト行...` の前）:

```
- **untracked の部分 stage は `--no-index` 形式の diff が前提**。`git apply --cached` は index 未登録
  パスでも `--- /dev/null` / `+++ b/<file>` 形式の新規作成ハンクを受理する（実証実験 2026-06-17）。
  `git add -N`（intent-to-add）は不要。`buildLinePatch` の変換ルールが全行挿入 diff でそのまま成立つ。
```

## 8. 既知の制約（phase 境界として明記）

- **rename ファイルのハンク stage は未対応**: `orig_path != null` のガードを維持するため、rename は
  引き続きファイル単位 stage のみ（後続 spec で対応）。
- **discontiguous 選択・ドラッグ範囲拡張・Shift クリック**: 本 spec では扱わない（TODO 1 の
  「行単位 stage の phase 2 で未対応（さらに将来）」に既出。`MouseEvent` への修飾キー追加が前提）。
- **`git add -N` 状態へ依存しない**: 本方式は `git add -N` を使わないため、intent-to-add 状態の取り回しを
  Model に持たせる必要がない（状態遷移の複雑化を回避）。

## 9. 影響を受けない既存の挙動（回帰安全性）

- `toggle_stage`（ファイル単位）の untracked → `git add` 全行 stage: 不変。
- `diff_cursor`/`diff_anchor`/`selectionRange` の振る舞い: 不変（untracked でも既存どおり）。
- `renderDiff` のハイライト・カーソル・`ensureVisible`: 不変。
- `fromZigzagMouse` の diff ペインクリック → `select_line_at`: 不変。
- `replaceFiles` の section ソート・選択追従: 不変（`1 AM` を 2 エントリへ展開する既存ロジックで吸収）。
- `main.zig` の `dispatchSideEffect`/`reapWorker`/`pending`: 不変（`apply_patch` を変更しないため）。

## 10. テスト規約（既存に従う）

- 実装と同じ `.zig` 内の `test {}` ブロック。
- `std.testing.allocator` 必須（リーク検出）。view の arena 関数は `ArenaAllocator`（本 spec では対象外）。
- 各ファイル `test { std.testing.refAllDecls(@This()); }`。
- 新規 `.zig` モジュールは作らない（変更が `update.zig` の 4 行削除のみのため）。
- 結合テスト（`appcmd.zig`）は既存 `TmpRepo` パターンを拡張。

## 11. レビュー経緯（設計の妥当性裏付け）

本設計は subagent と codex CLI の並行レビューを経て確定した（第 3 回既知の制約 spec と同形式）。

- **両者共通の blocker 1（反映済み）**: 受け入れ基準 8 が `buildLinePatch` の no-newline 挙動と矛盾していた。
  当初「untracked で末尾改行無しの最終行のみ選択 → `null`（no-op）」と書いていたが、実際のコードをトレースすると
  untracked の全行挿入ハンクでは `+` 行が「選択→kept」「未選択→dropped」の 2 択のみで `contextified` 状態に
  到達しないため、`\ No newline` マーカーの `switch (prev)` は `.kept`/`.dropped` しか見ない。最終 `+` 行を
  選択すればマーカーも保持された有効パッチが出る。spec 自身の §2 実験 2 と矛盾していたため、§5 受け入れ基準 8 を
  正しい記述へ書き直し、§3.1 コメントに no-newline 追従の 1 行を追記した。
- **両者共通の nit 1（反映済み）**: フルハンク選択のテストが無く受け入れ基準 2 が未カバーだった。
  §4.1 へ「`buildLinePatch` 出力が `buildPatch` と等価」の純粋テストを追加。
- **両者共通の nit 2（反映済み）**: 日本語 body の untracked テストが無く、CLAUDE.md の日本語カバー重視に
  準拠していなかった。§4.1 へ日本語 body の純粋テストを追加。
- **codex の nit 3（反映済み）**: §5.3「複数ハンク」が過表現だった（`--no-index` は通常単一ハンク）。
  「単一の全挿入ハンクの部分選択が基本ユースケース」へ修正。
- **subagent の nit 3（反映済み）**: §3.1 の「変更後」コメントに no-newline 追従の記載が無く、
  blocker 1 と同じ誤解が再発する恐れがあったため 1 行追記。

両者とも以下の核心設計を承認（Verified claims）:
- `buildLinePatch(reverse=false)` が untracked 全行挿入を変更不要で処理（`old_count=0`, `new_count=選択数`）。
- `parseHeader` の `old_start="0"`, `new_start="1"` 抽出。
- 所有権安全性（`errdefer` 二重ガードは untracked ガード削除後も不変）。
- 回帰安全性（busy / rename ガードは不変）。
- `1 AM` 吸収（`status.zig` の X/Y 二重エントリ + `replaceFiles` の section ソート）。
- `apply_patch` は section 非依存で untracked/tracked 同一経路。
- TODO.md 更新の方向性が選定方式（`git add -N` ではなく `git apply --cached` 単体）を正しく反映。
