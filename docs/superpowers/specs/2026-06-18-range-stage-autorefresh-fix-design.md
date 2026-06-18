# TODO 1 ブロッカー 2 件の修正（範囲 stage の auto-refresh 破壊 + 部分 stage 後の選択追従）— 設計

- 日付: 2026-06-18
- 対象: `TODO.md` TODO 1「部分ステージング」の 2026-06-18 QA で発見された下記 2 バグ。
  1. **範囲 stage が auto-refresh で破壊されるバグ**（ブロッカー・TODO 1 完了を据え置いている）
  2. **部分 stage 後の選択ファイル追従バグ**（UX ノイズ）
- **対象外（本 spec の範囲外）**:
  - TODO 1 の他サブタスク（ログ表示・rebase・ACP 等）。
  - 行単位 stage の phase 2 残課題（飛び飛び選択・ドラッグ範囲拡張）。
  - rename ファイル（`2 .R` / `2 R.`）の部分 stage（既存ガード維持）。
- 親 spec:
  - `docs/superpowers/specs/2026-06-14-git-tui-design.md`（全体アーキテクチャ）
  - `docs/superpowers/specs/2026-06-16-line-staging-design.md`（行単位: diff_cursor/anchor 導入）
  - `docs/superpowers/specs/2026-06-17-todo1-known-constraints-design.md`（phase 1 制約 3-5 解消）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（食い違う場合はノート優先）

## 1. スコープと前提

2 つのバグは**互いに独立**（片方は `update.zig` の anchor クリア、もう一方は `model.zig` の
選択復元）。同じファイル群には触れるが変更箇所は分離しており、実装もテストも各バグごとに完結する。
実装順は Bug 1（ブロッカー）→ Bug 2（UX ノイズ）。両バグとも**純粋層に集約**されており、
非決定的な worker thread やタイミングに依存しない単体テストで再現・検証できる。

### 共通の前提（既存コードから確認済み）

- `update.zig` の `clampCursor(model)` は `diff_loaded` arm と `select_line_at` arm から呼ばれる。
  現状は**冒頭で無条件に `model.diff_anchor = null`** を実行する。
- ユーザー能動的なファイル切替（`key_down`/`key_up`/`select_index`）とハンク間ジャンプ
  （`diff_hunk_next`/`diff_hunk_prev`）は各 arm 内で**明示的に** `model.diff_anchor = null` を実行する
  （`clampCursor` に依存しない）。つまり `clampCursor` の無条件 clear はこれらの経路では**冗長**。
- `toggle_line_selection`（`v`）は `model.diff_anchor` を `model.diff_cursor` へセットするだけ
  （`clampCursor` を呼ばない）。
- `main.zig` の auto-refresh（`maybeAutoRefresh`）は `dispatchSideEffect(.refresh_status)` を 1500ms 間隔で呼ぶ。
  これは `refresh_status → status_loaded → loadDiffCmd → load_diff → diff_loaded → clampCursor`
  という Msg 連鎖を起動し、結果として選択中ファイルの diff 再読込を引き起こす。
- `model.zig replaceFiles` は選択復元を `(section, path)` 完全一致で行う。部分 stage で section が
  変わると（`? untracked.txt` → `1 AM` 展開で `.untracked` → `.staged` + `.unstaged`）追従できない。
- `hunk.zig` に `pub fn hunkIndexForLine(parsed, abs_line) ?usize` が既存（file_header/範囲外は null を返す）。
  また `isBodyLine` 相当は `update.zig` 内 private で既存（`abs != parsed.hunks[i].start_line` で本文行判定）。

## 2. Bug 1 — 範囲 stage が auto-refresh で破壊される

### 問題

標準フロー `v`（選択開始）→ `j`（選択拡張）→ `s`（stage）で、選択範囲ではなく**最終カーソル位置の
単一行**しか stage されない。単一行 stage（`v` 押さずに `s`）は正常。

### 根拠（実証済み）

- `update.zig` の `clampCursor` が `diff_loaded`/`status_loaded` 経由で**無条件に** `model.diff_anchor = null` を実行。
- `main.zig` の auto-refresh（1500ms ポーリング）やファイル切替時の `loadDiffCmd` がこのパスを起動するため、
  `v` 押下から `s` 押下までの間に高確率で anchor が null 化される（stderr デバッグで実証）。
- **純粋層は正常**: `update.zig`/`hunk.zig` の単体テストは全て PASS。reducer 単体を直接駆動する再現 exe でも
  正しく複数行 stage される。バグは `main.zig` のランタイム配線（auto-refresh の diff 再読込）にある。

### 解決方針（採用: A — clampCursor の無条件 clear を検証付き保持へ）

`clampCursor` の「無条件 `model.diff_anchor = null`」を削除し、代わりに**anchor 検証**を追加する。
検証を pass すれば anchor を保持、fail すれば null 化する。これにより:

- **auto-refresh（同ファイル再描画）**: anchor が検証を pass すれば保持 → 範囲選択が維持される（バグ根治）。
- **ユーザー能動操作（`key_down`/`key_up`/`select_index`/`diff_hunk_next`/`diff_hunk_prev`）**:
  各 arm が既に明示的に `model.diff_anchor = null` を実行するため、`clampCursor` の clear が無くても
  従来どおり選択クリア。`clampCursor` の無条件 clear はこれらの経路では元々**冗長**だった。
- **`select_line_at`（マウスクリック）**: 本来「明示的な選択解除」のセマンティクス。`clampCursor` から
  clear が消えるとこのセマンティクスが失われるため、`select_line_at` arm に**明示的に**
  `model.diff_anchor = null` を追加する（回帰保護）。

### anchor 検証ルール（2 条件の AND）

`diff_loaded` 後の anchor は、diff_text が変わった可能性があるため**絶対行 index の再検証**が必要。
下記 (a) AND (b) を満たすときだけ anchor を保持、それ以外は null 化する。

- **(a) anchor が本文行である**: `anchor != null` かつ `isBodyLine(parsed, anchor)`。
  `@@` ヘッダ行 / file_header / 範囲外 は不可（`hunkIndexForLine` が null を返す行、または
  `parsed.hunks[i].start_line` と一致する行）。
- **(b) anchor と cursor が同じハンクである**: `hunkIndexForLine(parsed, anchor) ==
  hunkIndexForLine(parsed, cursor)`（両方 non-null で同値）。
  file_header 行数が変動した場合（コンテキスト行の増減等）に anchor と cursor が別ハンクへズレる
  可能性があり、そのズレは「見た目の選択」と「stage 対象」が不一致になる元なので検証で落とす。

`anchor == null` のときは検証不要（そのまま null を維持）。

### cursor が本文外で clampCursor が再配置したときの anchor 扱い

`clampCursor` は cursor が本文行でない（`@@` ヘッダ / file_header / 範囲外）とき、先頭ハンク本文先頭へ
cursor を再配置する。このとき anchor は:

- **(a)(b) を再評価して保持可なら保持**（採用）。cursor が再配置されたハンクと anchor のハンクが一致すれば
  anchor は保持される。ユーザが明示的に `v` を押して作った選択なので、cursor だけがズレていた（diff 未変更）なら
  選択を維持するのが自然。auto-refresh で cursor のみズレた稀なケースでも選択が消えない。

実装上の順序: `clampCursor` 内で (1) parsed を構築、(2) cursor の本文判定と再配置、(3) anchor 検証、
の順で処理する。cursor 再配置後に anchor 検証を行うことで、上記「cursor が再配置されても anchor 保持」が
成立する（cursor の新しいハンクと anchor のハンクを比較する）。

### 変更箇所

#### 2.1 `src/update.zig` — `clampCursor` の本体変更

現状:

```zig
fn clampCursor(model: *Model) !void {
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    model.diff_anchor = null;                              // ★無条件 clear（削除対象）
    if (parsed.hunks.len == 0) {
        model.diff_cursor = 0;
        return;
    }
    if (!isBodyLine(parsed, model.diff_cursor)) {
        model.diff_cursor = hunkBodyTop(parsed.hunks[0]);
    }
}
```

変更後:

```zig
/// diff 再読込/カーソル移動後にカーソルを本文行へ正規化し、anchor を**検証**する（純粋）。
/// - ハンク 0 個: cursor=0, anchor=null。
/// - カーソルが本文行でない（file_header / @@ ヘッダ行 / 範囲外）: 先頭ハンク本文先頭へ。
/// - 既にいずれかのハンク本文内: そのまま維持（リフレッシュ時のジャンプ防止）。
/// anchor は「(a) 本文行、(b) cursor と同じハンク」を両方満たすときだけ保持。それ以外は null。
/// ★この関数は `diff_loaded`（auto-refresh 含む）から呼ばれる。無条件 clear すると
///   `v → j → s` の間に auto-refresh が走っただけで選択が消える（TODO 1 ブロッカー）。
///   ユーザー能動的なファイル切替（key_down/key_up/select_index/diff_hunk_next/prev）は
///   各 arm が明示的に anchor を clear するため、ここでの clear はそれら経路では冗長だった。
fn clampCursor(model: *Model) !void {
    var parsed = try hunk.parse(model.allocator, model.diff_text);
    defer parsed.deinit(model.allocator);
    if (parsed.hunks.len == 0) {
        model.diff_cursor = 0;
        model.diff_anchor = null; // ハンク無しでは選択は無意味
        return;
    }
    // カーソルが本文行でない（@@ ヘッダ/file_header/範囲外）なら先頭ハンク本文先頭へ再配置
    // （spec: ヘッダクリックも本文へクランプ）。本文内ならジャンプ防止で維持。
    if (!isBodyLine(parsed, model.diff_cursor)) {
        model.diff_cursor = hunkBodyTop(parsed.hunks[0]);
    }
    // anchor 検証: (a) 本文行、(b) cursor と同じハンク、の AND を満たすときだけ保持。
    // §2「cursor が本文外で再配置」: cursor 再配置後に検証するので、新しい cursor ハンクと
    // anchor ハンクが一致すれば保持される（ユーザが v で作った選択をCursor ズレだけで消さない）。
    model.diff_anchor = validateAnchor(parsed, model.diff_cursor, model.diff_anchor);
}

/// anchor が「(a) 本文行」「(b) cursor と同じハンク」を両方満たすかを検証し、満たすならそのまま
/// 返し、満たさない（または anchor==null）なら null を返す。純粋・allocator 不要。
fn validateAnchor(parsed: hunk.ParsedDiff, cursor: usize, anchor: ?usize) ?usize {
    const a = anchor orelse return null;
    if (!isBodyLine(parsed, a)) return null; // (a) 本文行でない（@@ ヘッダ/file_header/範囲外）
    const a_hunk = hunk.hunkIndexForLine(parsed, a) orelse return null; // (a) の念のため（isBodyLine と同値）
    const c_hunk = hunk.hunkIndexForLine(parsed, cursor) orelse return null; // cursor が本文でない（通常到達不能: clampCursor で本文へ正規化済み）
    if (a_hunk != c_hunk) return null; // (b) 異ハンク
    return a;
}
```

- `validateAnchor` を新設。`clampCursor` から呼ぶだけでなく、単体テストから直接駆動して
  (a)(b) の各条件を確実に検証できるようにする（非決定的なランタイムを介さない）。
- `hunks.len == 0` の枝でも明示的に `anchor = null` を入れる（従来は冒頭無条件 clear で暗黙に null 化）。

#### 2.2 `src/update.zig` — `select_line_at` arm への明示的 anchor clear 追加

現状:

```zig
.select_line_at => |line| {
    model.focus = .diff;
    model.diff_cursor = line;
    try clampCursor(model); // 本文外クリックはハンク本文へクランプ・anchor リセット
    return .none;
},
```

変更後:

```zig
.select_line_at => |line| {
    model.focus = .diff;
    model.diff_cursor = line;
    // ★マウスクリックは「明示的な選択解除」のセマンティクス。clampCursor が anchor を保持する
    //   ようになった（Bug 1 修正）ため、ここで明示的に clear しないとクリックで選択が残る。
    //   従来は clampCursor の無条件 clear に依存していたが、それは auto-refresh も clear する
    //   バグの根因だった。ユーザー能動操作経路はここだけ clampCursor 経由で anchor を clear する
    //   必要がある（key_down/up/select_index/diff_hunk_next/prev は arm 内で直接 clear するため非依存）。
    model.diff_anchor = null;
    try clampCursor(model); // 本文外クリックはハンク本文へクランプ
    return .none;
},
```

- `clampCursor` 呼出の**前**に clear する。順序は問わない（`clampCursor` は anchor が null なら
  そのまま null を維持するため）が、読み手に「クリックで選択解除」の意図を明示するために前へ置く。

### テスト（新規・`update.zig` 内）

全て reducer を直接駆動する単体テスト（worker thread 非依存・非決定性なし）。

#### Bug 1 再現テスト（auto-refresh シナリオの決定論的再現）

```zig
test "Bug 1: range selection survives diff_loaded (auto-refresh simulation)" {
    // v → j → j → (auto-refresh が diff_loaded を発火) → s で範囲 stage されること。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6 (' a'/-b/+B)

    // 1) v で選択開始 (cursor=5 → anchor=5)
    m.diff_cursor = 5;
    var c1 = try update(&m, .toggle_line_selection);
    c1.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor);

    // 2) j で選択拡張 (cursor=5 → 6)
    var c2 = try update(&m, .diff_cursor_down);
    c2.deinit(a);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor); // 選択維持

    // 3) auto-refresh シミュレーション: 同じ diff_text で diff_loaded を再送
    //    （main.zig の maybeAutoRefresh → status_loaded → load_diff → diff_loaded と同効果）
    const same_diff = try a.dupe(u8, m.diff_text);
    defer a.free(same_diff);
    var c3 = try update(&m, .{ .diff_loaded = same_diff });
    c3.deinit(a);
    // ★Bug 1 の核心: diff_loaded 後も anchor が保持されること
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor);
    try std.testing.expectEqual(@as(usize, 6), m.diff_cursor);

    // 4) s で stage → 選択範囲 [5,6] がパッチへ含まれること（単一行ではなく 2 行分）
    //    ★Bug 1 無修正なら anchor が diff_loaded で null 化し、selectionRange(6,null)={6,6}
    //      なので '-b' は未選択→文脈化(' b')されてパッチから消え、'+B' のみ残る。
    //      修正後は anchor=5 保持で selectionRange(6,5)={5,6} となり、'-b' も選択→保持される。
    var c4 = try update(&m, .stage_lines);
    defer c4.deinit(a);
    try std.testing.expect(c4 == .apply_patch);
    try std.testing.expect(std.mem.indexOf(u8, c4.apply_patch.patch, "+B\n") != null); // 選択された追加行
    try std.testing.expect(std.mem.indexOf(u8, c4.apply_patch.patch, "-b\n") != null); // 選択された削除行（文脈化されず保持）
}
```

#### anchor 検証の各条件（`validateAnchor` の単体テスト）

```zig
test "validateAnchor: null anchor stays null" { ... }
test "validateAnchor: anchor on @@ header is cleared (cond-a fail)" { ... }
test "validateAnchor: anchor on file_header is cleared (cond-a fail)" { ... }
test "validateAnchor: anchor on different hunk from cursor is cleared (cond-b fail)" { ... }
test "validateAnchor: anchor on body line in same hunk as cursor is kept (both pass)" { ... }
```

#### cursor 再配置時の anchor 扱い

```zig
test "clampCursor keeps anchor when cursor reclamped to same hunk as anchor" {
    // cursor が範囲外 → 先頭ハンク本文先頭へ再配置。anchor が同ハンクなら保持。
    // （ユーザが v で選択後、cursor のみズレた稀なケースでも選択が消えない）
    ...
}
test "clampCursor clears anchor when cursor reclamped to different hunk from anchor" {
    // cursor が範囲外 → 再配置先が anchor と別ハンク → cond-b fail で null 化。
    ...
}
```

#### 回帰テスト（既存挙動の保護）

```zig
test "select_line_at still clears anchor after Bug 1 fix (regression)" {
    // マウスクリックは明示的選択解除。clampCursor が anchor を保持するようになっても
    // select_line_at 単独で anchor を clear する。
    ...
}
test "key_down/key_up/select_index still clear anchor (regression)" { ... }
test "diff_hunk_next/prev still clear anchor (regression)" { ... }
test "diff_loaded with no hunks clears anchor (regression)" { ... }
```

### 受け入れ基準（Bug 1）

1. `v → j → j → s` で選択範囲全体が stage される（auto-refresh の `diff_loaded` が間に挟まっても選択維持）。
2. `validateAnchor` が (a) 本文行、(b) cursor と同じハンク、の AND を正しく判定する。
3. `select_line_at`（マウスクリック）の anchor clear 挙動は不変（回帰）。
4. `key_down/key_up/select_index/diff_hunk_next/diff_hunk_prev` の anchor clear 挙動は不変（回帰）。
5. 既存の全単体テストが green。特に「diff_loaded clamps cursor into a hunk body and resets anchor」は
   **テスト名こそ "resets anchor" だが、同じハンクの本文行に anchor が無いセットアップ（cursor=999, anchor=3
   で @@ 行3 = 本文行でない）なので cond-a で null になり、従来どおりの期待値で green を維持**する。
   テスト名は実態（anchor 検証）へ更新する。

### 既存テスト「diff_loaded clamps cursor into a hunk body and resets anchor」の取り扱い

```zig
test "diff_loaded clamps cursor into a hunk body and resets anchor" {
    ...
    m.diff_cursor = 999;
    m.diff_anchor = 3;
    const diff = "...@@ -1,1 +1,2 @@\n a\n+B\n";
    var cmd = try update(&m, .{ .diff_loaded = diff });
    cmd.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), m.diff_cursor);
    try std.testing.expectEqual(@as(?usize, null), m.diff_anchor); // ★この期待値は変わらない
}
```

- セットアップ `diff_anchor = 3` は @@ ヘッダ行（`parsed.hunks[0].start_line == 3`）を指すため、
  `isBodyLine(parsed, 3)` が false → cond-a fail → `validateAnchor` が null を返す。
- **期待値 `m.diff_anchor == null` は変わらない**ため、アサーションは更新不要。
- テスト名を「resets anchor」から「validates anchor」へ更新し、セットアップの意図（@@ 行 = cond-a fail）
  をコメントへ明記する。

## 3. Bug 2 — 部分 stage 後の選択ファイル追従

### 問題

`untracked.txt` を部分 stage すると porcelain が `? untracked.txt` → `1 AM untracked.txt` へ変わり、
`replaceFiles` が staged と unstaged の 2 エントリへ展開する。`replaceFiles` の選択復元は
`(section, path)` 完全一致で行うため、section が `.untracked` → `.staged`（または `.untracked` 残存側）へ
変わると追従できず、diff ペインが別ファイル（先頭マッチ or index クランプ）へ切り替わることがある。

### 影響

機能破壊ではない（stage 自体は成功）が、連続して部分 stage を繰り返す際の UX ノイズ。

### 解決方針（採用: path-only フォールバック・unstaged 優先）

`replaceFiles` の選択復元を 2 段階へ拡張する:

1. **第 1 段階（従来）**: `(section, path)` 完全一致で選択復元。見つかればそれを使う。
2. **第 2 段階（新設・フォールバック）**: 第 1 段階で見つからなければ `path` のみで一致検索。
   複数ヒット時の優先順位は **unstaged > staged > untracked**。

unstaged 優先の理由: 部分 stage 後に「まだ作業が残っている」側へ選択を誘導し、連続 stage を継続しやすくする。
完全 stage したなら unstaged 側は消えて staging 済み側（staged）のみが残り、第 2 段階で staged がヒットするため
「全部 stage したら staged 側へ」も自然に成立する。

### 変更箇所

#### 3.1 `src/model.zig` — `replaceFiles` の選択復元ロジック拡張

現状:

```zig
// 選択を (section, path) で復元（旧 files 解放前に照合）。見つからなければ index クランプにフォールバック。
var new_selected: usize = self.selected;
if (prev) |p| {
    for (next.items, 0..) |f, i| {
        if (f.section == p.section and std.mem.eql(u8, f.path, p.path)) {
            new_selected = i;
            break;
        }
    }
}
```

変更後:

```zig
// 選択を復元。2 段階: (1) (section, path) 完全一致、(2) path のみでフォールバック（unstaged>staged>untracked優先）。
// 第 2 段階は部分 stage で section が変わったケース（? untracked.txt → 1 AM で .untracked → .staged+.unstaged）へ
// 選択を追従させる（Bug 2）。unstaged 優先は「まだ作業が残っている」側へ誘導し連続 stage を継続しやすくする。
var new_selected: usize = self.selected;
if (prev) |p| {
    var found_exact: ?usize = null;
    var found_path_only: ?usize = null;
    for (next.items, 0..) |f, i| {
        if (found_exact == null and f.section == p.section and std.mem.eql(u8, f.path, p.path)) {
            found_exact = i;
            // 完全一致ヒット時は break しない: path-only サーチも同ループで済ませるため最後まで回す。
            // ただし完全一致が優先されるため、found_exact が non-null ならそれを使う（下で分岐）。
        }
        if (found_path_only == null and std.mem.eql(u8, f.path, p.path)) {
            // path のみ一致の最初の候補。優先順位は下で選び直す（unstaged>staged>untracked）。
            found_path_only = i;
        }
    }
    if (found_exact) |i| {
        new_selected = i;
    } else if (found_path_only != null) {
        // 完全一致無し。path のみで一致するエントリから優先順位（unstaged>staged>untracked）で選ぶ。
        new_selected = selectByPathPriority(next.items, p.path);
    }
    // どちらも見つからなければ new_selected は self.selected のまま（下で index クランプ）。
}
```

#### 3.2 `src/model.zig` — `selectByPathPriority` ヘルパ新設

```zig
/// path のみが一致するエントリのうち、優先順位（unstaged > staged > untracked）で最も高いものの
/// index を返す。見つからなければ unreachable 呼び出し側で path_only が non-null のときだけ呼ぶ）。
/// 純粋・allocator 不要。
fn selectByPathPriority(items: []const FileItem, path: []const u8) usize {
    // 優先順位に従い、最初に見つけたエントリの index を返す。
    // 2 パス（優先順位ごと）で走査する。entries は通常小規模（部分 stage で高々 2-3 エントリ増）のため
    // 計算量は問題にならない。
    const priorities = [_]status.Section{ .unstaged, .staged, .untracked };
    for (priorities) |sec| {
        for (items, 0..) |f, i| {
            if (f.section == sec and std.mem.eql(u8, f.path, path)) return i;
        }
    }
    // 呼び出し側が path_only != null を保証するため、ここには到達しない。
    // 到達した場合は index 0 へ退化（フォールバック）。
    return 0;
}
```

- 優先順位は `sectionRank`（staged=0 < unstaged=1 < untracked=2）とは**逆**（unstaged が先頭）。
  `sectionRank` は表示順（staged が先頭）用で、選択追従の優先順位とは別物。混同しないよう個別に定義する。

### テスト（新規・`model.zig` 内）

#### Bug 2 再現テスト

```zig
test "Bug 2: partial stage of untracked follows selection to unstaged entry" {
    // untracked.txt 選択中 → 部分 stage で ? → 1 AM 展開。.unstaged 側へ追従すること。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();

    // 初回: untracked.txt のみ
    const e1 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e1) |e| a.free(e.path);
    try m.replaceFiles(&e1);
    try std.testing.expectEqualStrings("untracked.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.untracked, m.files.items[m.selected].section);

    // 部分 stage 後: 1 AM 展開で staged + unstaged の 2 エントリ + 別の untracked が残ったとする
    const e2 = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .staged },
        .{ .path = try a.dupe(u8, "untracked.txt"), .orig_path = null, .section = .unstaged },
        .{ .path = try a.dupe(u8, "other.txt"), .orig_path = null, .section = .untracked },
    };
    defer for (e2) |e| a.free(e.path);
    try m.replaceFiles(&e2);
    // ★Bug 2 の核心: 同 path の .unstaged 側（index 1、表示順では unstaged head の下）へ追従
    try std.testing.expectEqualStrings("untracked.txt", m.files.items[m.selected].path);
    try std.testing.expectEqual(status.Section.unstaged, m.files.items[m.selected].section);
}
```

#### `selectByPathPriority` の単体テスト

```zig
test "selectByPathPriority prefers unstaged over staged and untracked" { ... }
test "selectByPathPriority falls back to staged when no unstaged match" { ... }
test "selectByPathPriority falls back to untracked when only untracked matches" { ... }
```

#### 回帰テスト（既存挙動の保護）

既存の下記テストは**変更なしで green** を維持する（第 1 段階の完全一致でヒットするため第 2 段階へ行かない）:

- `replaceFiles preserves selection by (section, path) across refresh`（完全一致でヒット）
- `replaceFiles falls back to index clamp when selected file is gone`（path も一致しない → 第 2 段階も
  ヒットせず → index クランプ。従来どおり）

### 受け入れ基準（Bug 2）

1. untracked ファイルの部分 stage 後、選択が同 path の unstaged 側エントリへ追従する。
2. 完全 stage（unstaged 側が消える）の場合は staged 優先で追従する。
3. 完全一致するエントリが残る場合は第 1 段階でヒットし、従来どおりの挙動（回帰）。
4. path も一致しない（ファイル削除等）場合は index クランプへフォールバック（回帰）。

## 4. 実装順（純粋層 TDD → 配線）

両バグは独立。Bug 1（ブロッカー）を先に実装する。

1. **Bug 1（clampCursor の anchor 検証）**:
   1. `update.zig`: `validateAnchor` ヘルパ新設（純粋・単体テスト可能）。
   2. `update.zig`: `clampCursor` 本体変更（無条件 clear → `validateAnchor` 呼出）。
   3. `update.zig`: `select_line_at` arm へ明示的 `model.diff_anchor = null` 追加。
   4. `update.zig`: 既存テスト「diff_loaded clamps cursor...」のテスト名とコメント更新
      （期待値は不変・セットアップの意図を明記）。
   5. 新規テスト: Bug 1 再現・`validateAnchor` 各条件・cursor 再配置時・回帰。
2. **Bug 2（replaceFiles の path-only フォールバック）**:
   1. `model.zig`: `selectByPathPriority` ヘルパ新設（純粋・単体テスト可能）。
   2. `model.zig`: `replaceFiles` の選択復元を 2 段階へ拡張。
   3. 新規テスト: Bug 2 再現・`selectByPathPriority` 各優先順位・回帰（既存テストは変更なしで green）。

### UI 層への配線は不要

両バグとも純粋層（`update.zig` / `model.zig`）に集約されている。`main.zig` の auto-refresh 経路も
`diff_loaded` Msg を reducer へ流すだけで、reducer 側の修正だけでバグが根治する。view/input は触らない。

## 5. TODO.md 更新

`TODO.md` TODO 1 の Sub Tasks から下記 2 項目を `[ ]` → `[x]` 化し、それぞれ「解消」の 1 行メモを追記:

- `[x] ★範囲 stage が auto-refresh で破壊されるバグの修正（2026-06-18 QA で発見・ブロッカー）`
  → 解消: `clampCursor` の無条件 anchor clear を検証付き保持へ変更（`validateAnchor` 新設）。
- `[x] ★部分 stage 後の選択ファイル追従バグの修正（2026-06-18 QA で発見・UX ノイズ）`
  → 解消: `replaceFiles` の選択復元に path-only フォールバック（unstaged 優先）を追加（`selectByPathPriority` 新設）。

両バグの解消により、TODO 1 の全 Sub Tasks が `[x]` となる。ただし「phase 2 でさらに未対応」の
行単位機能（飛び飛び選択・ドラッグ範囲拡張・tracked No-newline 境界）は別件として残る。

## 6. テスト規約（既存に従う）

- 実装と同じ `.zig` 内の `test {}` ブロック。
- `std.testing.allocator` 必須（リーク検出）。view の arena 関数は `ArenaAllocator`。
- 各ファイル `test { std.testing.refAllDecls(@This()); }`。
- 新規 `.zig` モジュールは作らない（`validateAnchor` は `update.zig` 内、`selectByPathPriority` は
  `model.zig` 内のプライベート関数）。
- Bug 1 の auto-refresh シナリオは「`diff_loaded` を reducer に直接流す」連続シーケンステストで再現
  （worker thread / タイミングに依存しない・決定論的）。

## 7. レビュー計画

本 spec を subagent（`scrutiny-feature-reviewer` 相当）と codex CLI で並行レビューし、下記観点を確認する:

- **Bug 1**: `clampCursor` から無条件 clear を削除したことによる他経路（`key_down/up/select_index/
  diff_hunk_next/prev`）への影響が無いか（各 arm が明示的に clear しているか）。
- **Bug 1**: `validateAnchor` の (a)(b) 条件が過剰（必要以上に anchor を消す）でも不足（見た目と stage 対象が
  不一致になる）でもないか。
- **Bug 1**: `select_line_at` への明示的 clear 追加が本来のセマンティクス（マウスクリック＝選択解除）を
  回復しているか。
- **Bug 2**: `selectByPathPriority` の優先順位（unstaged>staged>untracked）が部分 stage のユースケースで
  適切か。完全 stage 時の挙動（unstaged が消えて staged のみ残る）も正しいか。
- **Bug 2**: `replaceFiles` の 2 段階復元が既存テスト（完全一致・index クランプ）を壊さないか。
- **所有権・リーク**: 新設ヘルパ（`validateAnchor`/`selectByPathPriority`）は純粋で allocator 不要。
  `replaceFiles` の拡張も `next.items` の借用ループのみで新規確保なし。

実装後も subagent + codex でコードレビューを行う（ユーザー指示）。
