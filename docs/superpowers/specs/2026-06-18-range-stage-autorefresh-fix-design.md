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

### 解決方針（採用: A — clampCursor の無条件 clear を検証付き保持へ + ファイル同一性ゲート）

本修正は 2 層の防御から成る。両方とも `update.zig` の純粋層に集約される。

#### 層 1: ファイル同一性ゲート（`diff_loaded` arm 先頭）

`clampCursor` は現在の `model.diff_text` しか見えず、「この diff がどのファイルのものか」を知らない。
そのため、`status_loaded → replaceFiles` で `model.selected` が**別ファイルへクランプされた**後に
`diff_loaded` が届いても（外部プロセスが選択中ファイルを commit/削除した場合等）、`clampCursor` 単独では
「anchor が本文行かつ cursor と同ハンク」だけを見てしまい、偶然行番号が一致すれば **stale anchor が生存**する。
これは従来の無条件 clear では起きなかった、本修正が導入する回帰リスク（codex レビュー B1）。

よって `diff_loaded` arm の先頭で、今読み込んだ diff が**現在選択中のファイルと同一か**を検証し、
不一致なら anchor を clear してから `clampCursor` へ流す。同一なら anchor を保持したまま `clampCursor` へ。

「同一性」の判定には Model に新フィールド `diff_owner`（最後に `load_diff` を発行したファイル識別子:
`path` + `section`、`orig_path` は含めない＝untracked→tracked 等の section 変化も検知するため）を持たせ、
`loadDiffCmd` が `load_diff` を返すときに `diff_owner` を更新し、`diff_loaded` で `selected` ファイルと比較する。

#### 層 2: clampCursor の無条件 clear → 検証付き保持（validateAnchor）

ファイル同一性が確認された（同ファイルの再描画）上で、anchor が新しい diff_text で有効かを検証する:

- **auto-refresh（同ファイル再描画）**: 層 1 を pass → 層 2 で anchor が検証を pass すれば保持 → 範囲選択維持（バグ根治）。
- **ユーザー能動操作（`key_down`/`key_up`/`select_index`/`diff_hunk_next`/`diff_hunk_prev`）**:
  各 arm が既に明示的に `model.diff_anchor = null` を実行するため、層 1・層 2 を問わず従来どおり選択クリア。
  `clampCursor` の無条件 clear はこれらの経路では元々**冗長**だった。
- **`select_line_at`（マウスクリック）**: 本来「明示的な選択解除」のセマンティクス。層 2 から clear が消えると
  このセマンティクスが失われるため、`select_line_at` arm に**明示的に** `model.diff_anchor = null` を追加する（回帰保護）。
- **外部プロセスで選択中ファイルが消えた/別ファイルへ切替**: 層 1 で anchor clear → 従来どおり安全。

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

#### 2.0 `src/model.zig` — `diff_owner` フィールド追加（層 1 用）

最後に `load_diff` を発行したファイル識別子を保持する。`diff_loaded` で「同ファイルの再描画か、
別ファイルへの切替か」を判定するために使う（層 1: codex レビュー B1 対策）。

```zig
pub const DiffOwner = struct { path: []u8, section: status.Section };

pub const Model = struct {
    // ... 既存フィールド ...
    diff_owner: ?DiffOwner, // 最後に load_diff を発行したファイル。null = 未発行（初回）。
    // ...
};
```

- **`init`**: `.diff_owner = null` で初期化。
- **`deinit`**: `if (self.diff_owner) |o| a.free(o.path);`（`diff_text` の free の直後等）。
- **所有権**: `path` は persistent allocator 所有。`section` は enum（コピー）。
- **`orig_path` は含めない**: untracked → tracked 等の section 変化も同一性破綻として検出するため。
  `path` のみで追跡すると、partial stage で `? f` → `1 AM` と展開されたとき「path は同じ」になってしまい、
  section 変化を取り逃がす。`section` も比較対象へ含める。

#### 2.0b `src/model.zig` — `setDiffOwner` ヘルパ（層 1 用）

`setStr` と同型だが `?DiffOwner` 向け。`loadDiffCmd` が呼ぶ。

```zig
/// diff_owner を置換する（旧を free して dup）。null でクリアも可能。
pub fn setDiffOwner(self: *Model, path: []const u8, section: status.Section) !void {
    const a = self.allocator;
    const new_path = try a.dupe(u8, path);
    if (self.diff_owner) |old| a.free(old.path);
    self.diff_owner = .{ .path = new_path, .section = section };
}

/// diff_owner をクリアする（ファイル一覧が空になった等）。純粋。
pub fn clearDiffOwner(self: *Model) void {
    const a = self.allocator;
    if (self.diff_owner) |old| a.free(old.path);
    self.diff_owner = null;
}
```

#### 2.1 `src/update.zig` — `loadDiffCmd` の更新（層 1: diff_owner 記録）

`load_diff` を発行する前に `model.diff_owner` を現在の `selected` ファイルへ更新する。
ファイル一覧が空のときは `diff_owner` を clear する。

```zig
fn loadDiffCmd(model: *Model) !AppCmd {
    if (model.files.items.len == 0) {
        try model.setStr(&model.diff_text, "");
        model.clearDiffOwner(); // ファイル無し → diff_owner も無し
        return .none;
    }
    const f = model.files.items[model.selected];
    try model.setDiffOwner(f.path, f.section); // ★層 1: 発行時にオーナーを記録
    return .{ .load_diff = .{
        .path = try model.allocator.dupe(u8, f.path),
        .orig_path = if (f.orig_path) |p| try model.allocator.dupe(u8, p) else null,
        .section = f.section,
    } };
}
```

#### 2.2 `src/update.zig` — `diff_loaded` arm の更新（層 1: 同一性ゲート）

`diff_loaded` arm の先頭で、`model.diff_owner` と現在の `model.selected` ファイルが一致するか検証する。
不一致（ファイルが切り替わった・外部プロセスで selected が別へクランプされた）なら **anchor を clear**
してから `clampCursor` へ。一致なら anchor を保持したまま `clampCursor` へ（層 2 へ）。

```zig
.diff_loaded => |text| {
    model.busy = false;
    try model.setStr(&model.diff_text, text);
    // ★層 1: ファイル同一性ゲート（codex B1）。
    //   clampCursor は diff_text しか見えず「どのファイルの diff か」を知らないため、
    //   ここで selected ファイルが load_diff 発行時と同じか検証する。不一致なら stale anchor を消す。
    //   例: 外部プロセスが選択中ファイルを commit し、replaceFiles が selected を別ファイルへ
    //   クランプした後、その別ファイルの diff_loaded が届く。このとき anchor が偶然本文行かつ
    //   cursor と同ハンクなら clampCursor 単独では保持してしまう（回帰）。層 1 で未然に防ぐ。
    if (!isDiffOwnerCurrent(model)) {
        model.diff_anchor = null;
    }
    try clampCursor(model); // 層 2: validateAnchor（同一性が確認された上で anchor を検証）
    return .none;
},
```

`isDiffOwnerCurrent` ヘルパ（純粋・allocator 不要）:

```zig
/// model.diff_owner（最後に load_diff を発行したファイル）が現在の selected ファイルと一致するか。
/// 一致しない（ファイル切替・外部プロセスで selected が別へクランプ・初回ロード前）は false。
fn isDiffOwnerCurrent(model: *const Model) bool {
    const owner = model.diff_owner orelse return false; // 初回ロード前
    if (model.files.items.len == 0) return false; // ファイル無し（diff_owner は clear 済みのはずだが念のため）
    if (model.selected >= model.files.items.len) return false; // 範囲外（通常到達不能: replaceFiles がクランプ）
    const f = model.files.items[model.selected];
    return f.section == owner.section and std.mem.eql(u8, f.path, owner.path);
}
```

- **セマンティクス**: 「`load_diff` を発行した瞬間の selected」と「今の selected」が同じ (section, path) か。
  違えば、その `diff_loaded` は別ファイルのものであり、anchor は無効。
- **partial stage 後の section 変化**（`? f` → `1 AM`）は層 1 で「不一致」と判定され anchor が消える。
  これは Bug 2（選択追従）とは独立: 部分 stage 完了時は一度選択をリセットし、ユーザに新しいエントリで
  選び直してもらう。Bug 2 は `replaceFiles` の selected 復元で diff ペインの**表示ファイル**を追従させる
  （anchor の保持ではない）。両者の責務は分離されている。

#### 2.3 `src/update.zig` — `clampCursor` の本体変更（層 2: validateAnchor）

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
    const a_hunk = hunk.hunkIndexForLine(parsed, a) orelse return null; // isBodyLine=true なら必ず non-null（ボディ行はハンク内）。到達不能だが念のためガード。
    const c_hunk = hunk.hunkIndexForLine(parsed, cursor) orelse return null; // cursor が本文でない（通常到達不能: clampCursor で本文へ正規化済み）
    if (a_hunk != c_hunk) return null; // (b) 異ハンク
    return a;
}
```

- `validateAnchor` を新設。`clampCursor` から呼ぶだけでなく、単体テストから直接駆動して
  (a)(b) の各条件を確実に検証できるようにする（非決定的なランタイムを介さない）。
- `hunks.len == 0` の枝でも明示的に `anchor = null` を入れる（従来は冒頭無条件 clear で暗黙に null 化）。
- **cond-a の 2 段チェックは非冗長**（subagent N1 を訂正）: `isBodyLine` は `@@` ヘッダ行
  （`start_line` に等しい行）を拒否するが、`hunkIndexForLine` は `@@` ヘッダ行に対して **non-null**
  （`[start_line, start_line+line_count)` に含まれるため）を返す。つまり `isBodyLine=true` を通過した
  anchor は必ずハンク内本文行であり、後続の `hunkIndexForLine` は non-null になることが論理的に保証される。
  2 つめの `orelse return null` は到達不能だが、`isBodyLine` と `hunkIndexForLine` の契約が独立しているため
  防御的に残す（片方の契約変更で破綻しない）。cond-b のハンク比較に `c_hunk` が必要なので、
  結果として `a_hunk` の unwrap も必要（到達不能でも消せない）。

#### 2.4 `src/update.zig` — `select_line_at` arm への明示的 anchor clear 追加

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

このテストは層 1（ファイル同一性）と層 2（validateAnchor）の両方を通過する完全なパスを検証する。
ポイント: `diff_owner` を設定するために、テスト内で `load_diff` cmd を 1 回発行させる
（reducer の `status_loaded` を流すか、`loadDiffCmd` と同値の setup を直接行う）。

```zig
test "Bug 1: range selection survives diff_loaded (auto-refresh simulation)" {
    // v → j → (auto-refresh が diff_loaded を発火) → s で範囲 stage されること。
    // ★層 1（diff_owner 一致）+ 層 2（validateAnchor 通過）の両方を検証。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try seedTwoHunkDiff(&m); // h0 本文 4-6 (' a'/-b/+B)

    // ★層 1 セットアップ: diff_owner を "f.txt"/.unstaged へ設定。
    //   実機では loadDiffCmd（status_loaded → load_diff）がこれを行う。テストでは直接 setup。
    try m.setDiffOwner("f.txt", .unstaged);

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
    //    ★層 1: diff_owner == selected ファイル ("f.txt"/.unstaged) → 一致 → anchor 保持へ進む
    //    ★層 2: validateAnchor が anchor=5(本文行) と cursor=6(同 h0) を確認 → 保持
    const same_diff = try a.dupe(u8, m.diff_text);
    defer a.free(same_diff);
    var c3 = try update(&m, .{ .diff_loaded = same_diff });
    c3.deinit(a);
    try std.testing.expectEqual(@as(?usize, 5), m.diff_anchor); // ★Bug 1 の核心: 保持される
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

#### 層 1: ファイル同一性ゲートのテスト（`isDiffOwnerCurrent` と `diff_loaded` arm）

codex レビュー B1 の回帰保護。外部プロセスで selected が別ファイルへ切り替わった後に diff_loaded が
届くと、stale anchor が消えることを検証する。

```zig
test "Bug 1 layer-1: diff_loaded clears anchor when selected file changed (codex B1)" {
    // f.txt 選択中に anchor=5 → 外部プロセスで f.txt が commit され g.txt へ切替 →
    // g.txt の diff_loaded が届く。anchor は消えるべき（stale ではない）。
    const a = std.testing.allocator;
    var m = try Model.init(a, "/r");
    defer m.deinit();
    try addFile(&m, "f.txt", .unstaged);
    try addFile(&m, "g.txt", .unstaged);
    try seedTwoHunkDiff(&m);
    m.diff_cursor = 5;
    m.diff_anchor = 5;
    // f.txt を load した記録（実機では loadDiffCmd が設定）
    try m.setDiffOwner("f.txt", .unstaged);

    // 外部プロセスで f.txt が commit され、files が [g.txt] だけになったとする。
    const e_new = [_]status.StatusEntry{
        .{ .path = try a.dupe(u8, "g.txt"), .orig_path = null, .section = .unstaged },
    };
    defer for (e_new) |e| a.free(e.path);
    var c1 = try update(&m, .{ .status_loaded = &e_new });
    c1.deinit(a); // replaceFiles で selected が g.txt(0) へ。loadDiffCmd が diff_owner=g.txt へ更新。
    try std.testing.expectEqualStrings("g.txt", m.files.items[m.selected].path);
    try std.testing.expectEqualStrings("g.txt", m.diff_owner.?.path); // loadDiffCmd が更新済み

    // f.txt 時代の anchor=5 が残っている状態で、g.txt の diff_loaded が届く。
    // ★層 1: diff_owner(g.txt) != 直前の load 発行時の selected... 待てよ、loadDiffCmd が
    //   diff_owner を g.txt へ更新しているので、この時点で isDiffOwnerCurrent は true になる。
    //   本テストが検証したいのは「f.txt 時代の anchor が g.txt の diff で生き残らない」こと。
    //   そのためには層 1 ではなく層 2 が効く: anchor=5 が g.txt の diff_text で本文行かつ同ハンク
    //   かどうか。seedTwoHunkDiff は f.txt と同じレイアウトなので偶然本文行/同ハンクになってしまう。
    //   → テストは異なる diff_text を使うか、層 1 の意図を明確にするため diff_owner を f.txt の
    //         まま残す（loadDiffCmd を呼ばず selected だけ変える）セットアップにする。
    //   ★正しいセットアップ: loadDiffCmd を呼ばずに selected を変え、diff_owner を f.txt のままにする。
    //         これは「load_diff を発行したが結果が届く前に selected が変わった」レースを模倣。
    ...
}

test "isDiffOwnerCurrent: null owner returns false (first load)" { ... }
test "isDiffOwnerCurrent: matching section+path returns true" { ... }
test "isDiffOwnerCurrent: section change (partial stage) returns false" {
    // ? f → 1 AM で section が untracked → staged へ。diff_owner が古い section を持っていれば false。
    ...
}
test "isDiffOwnerCurrent: path change returns false" { ... }
```

※ 層 1 の「selected 切替 + diff_owner 更新」レースのテスト設計は実装時に詰める。
   重要な不変条件は: `diff_loaded` arm は「`loadDiffCmd` が発行した直後の `diff_owner`」と
   「今の `selected` ファイル」を比較し、一致しなければ anchor を clear すること。

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
2. `validateAnchor`（層 2）が (a) 本文行、(b) cursor と同じハンク、の AND を正しく判定する。
3. `isDiffOwnerCurrent`（層 1）が「load_diff 発行時と selected が同じ (section, path)」を正しく判定し、
   外部プロセスで selected が別ファイルへ切り替わった後に diff_loaded が届くと stale anchor を消す（codex B1 回帰保護）。
4. `select_line_at`（マウスクリック）の anchor clear 挙動は不変（回帰）。
5. `key_down/key_up/select_index/diff_hunk_next/diff_hunk_prev` の anchor clear 挙動は不変（回帰）。
6. 既存の全単体テストが green。特に「diff_loaded clamps cursor into a hunk body and resets anchor」は
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

### Bug 2 と Bug 1 層 1 の責務分離（重要）

Bug 2（選択ファイル追従）と Bug 1 層 1（ファイル同一性ゲート）は**どちらも `section`/`path` を比較するが
別物**。混同しないよう明示する:

- **Bug 2（`replaceFiles` の選択復元）**: 旧 `(section, path)` → 新 files の中で**どのエントリを選ぶか**を決める。
  `model.selected`（diff ペインが表示するファイル）を追従させる。partial stage で section が変わっても
  **同 path のエントリを選び直す**（unstaged 優先）。
- **Bug 1 層 1（`diff_loaded` arm の `isDiffOwnerCurrent`）**: `load_diff` 発行時の `selected` と、
  `diff_loaded` 到着時の `selected` が**同じ (section, path) か**を検証する。異なれば **anchor を消す**。
  partial stage で section が変わると、`loadDiffCmd` が新しい section で `diff_owner` を更新するため、
  層 1 は「新しい section のエントリと比較」になる → 一致すれば anchor は保持へ進む。

両者の協調動作（partial stage 完了時のシーケンス）:
1. `apply_patch` 成功 → `status_loaded`（新しい porcelain）→ `replaceFiles`（Bug 2: unstaged 側へ selected 復元）。
2. `loadDiffCmd`（`diff_owner` を新しい selected=unstaged 側へ更新）→ `load_diff` → `diff_loaded`。
3. `diff_loaded` arm: `isDiffOwnerCurrent` は「load 発行時の selected」と「今の selected」を比較 →
   両者とも新しい unstaged エントリ → 一致 → 層 2（validateAnchor）へ。
4. 層 2: anchor が新しい diff_text で有効なら保持、無効（コンテキスト行増減等で行ズレ）なら消す。

つまり Bug 2 は「表示ファイルの追従」、Bug 1 層 1 は「anchor の陳腐化防止」であり、両立する。
partial stage 直後は anchor が層 2 で消える可能性が高い（diff が変わるため）が、それは**期待動作**:
部分 stage 後は一度選択をリセットし、新しい diff で選び直すのが自然。Bug 2 が保証するのは
「diff ペインが別ファイルへ飛ばない」ことであり、「anchor まで維持する」ことではない。

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
/// index を返す。純粋・allocator 不要。
///
/// 呼び出し側は `found_path_only != null`（path に一致するエントリが少なくとも1つ存在）を保証して
/// 呼ぶため、本関数は常にヒットする。末尾の `return 0` は防御的フォールバックで、契約違反の呼出し
/// （path 一致エントリが無いのに呼んだ）時に index 0 へ退化して安全性を保つ。`unreachable` には
/// しない（一部のエッジで契約が崩れたときの安全側）。
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
    // 防御的フォールバック（契約違反時）: index 0 へ退化。本関数は `found_path_only != null` を
    // 前提とするが、前提が崩れてもクラッシュしない（subagent N2 / codex N3）。
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

1. **Bug 1 層 1（ファイル同一性ゲート）**:
   1. `model.zig`: `DiffOwner` struct・`diff_owner` フィールド・`setDiffOwner`/`clearDiffOwner` ヘルパ・`deinit` 更新。
   2. `update.zig`: `loadDiffCmd` で `setDiffOwner`/`clearDiffOwner` を呼ぶ。
   3. `update.zig`: `isDiffOwnerCurrent` ヘルパ新設（純粋・単体テスト可能）。
   4. `update.zig`: `diff_loaded` arm へ同一性ゲート追加（不一致で anchor clear）。
   5. 新規テスト: `isDiffOwnerCurrent` 各条件・codex B1 回帰（selected 切替で stale anchor 消去）。
2. **Bug 1 層 2（clampCursor の anchor 検証）**:
   1. `update.zig`: `validateAnchor` ヘルパ新設（純粋・単体テスト可能）。
   2. `update.zig`: `clampCursor` 本体変更（無条件 clear → `validateAnchor` 呼出・`hunks.len==0` 枝で明示 null）。
   3. `update.zig`: `select_line_at` arm へ明示的 `model.diff_anchor = null` 追加。
   4. `update.zig`: 既存テスト「diff_loaded clamps cursor...」のテスト名とコメント更新
      （期待値は不変・セットアップの意図を明記）。
   5. 新規テスト: Bug 1 再現（層 1 + 層 2 の完全パス）・`validateAnchor` 各条件・cursor 再配置時・回帰。
3. **Bug 2（replaceFiles の path-only フォールバック）**:
   1. `model.zig`: `selectByPathPriority` ヘルパ新設（純粋・単体テスト可能）。
   2. `model.zig`: `replaceFiles` の選択復元を 2 段階へ拡張。
   3. 新規テスト: Bug 2 再現・`selectByPathPriority` 各優先順位・回帰（既存テストは変更なしで green）。

### UI 層への配線は不要

両バグとも純粋層（`update.zig` / `model.zig`）に集約されている。`main.zig` の auto-refresh 経路も
`diff_loaded` Msg を reducer へ流すだけで、reducer 側の修正だけでバグが根治する。view/input は触らない。

## 5. TODO.md 更新

`TODO.md` TODO 1 の Sub Tasks から下記 2 項目を `[ ]` → `[x]` 化し、それぞれ「解消」の 1 行メモを追記:

- `[x] ★範囲 stage が auto-refresh で破壊されるバグの修正（2026-06-18 QA で発見・ブロッカー）`
  → 解消: 2 層構成。(1) `diff_loaded` arm にファイル同一性ゲート（`isDiffOwnerCurrent` + `model.diff_owner`）を追加し、外部プロセスで selected が別ファイルへ切り替わった後の stale anchor を防止（codex B1）。(2) `clampCursor` の無条件 anchor clear を `validateAnchor`（本文行 AND cursor と同ハンク）へ置換。
- `[x] ★部分 stage 後の選択ファイル追従バグの修正（2026-06-18 QA で発見・UX ノイズ）`
  → 解消: `replaceFiles` の選択復元に path-only フォールバック（unstaged 優先）を追加（`selectByPathPriority` 新設）。

両バグの解消により、TODO 1 の全 Sub Tasks が `[x]` となる。ただし「phase 2 でさらに未対応」の
行単位機能（飛び飛び選択・ドラッグ範囲拡張・tracked No-newline 境界）は別件として残る。

## 6. テスト規約（既存に従う）

- 実装と同じ `.zig` 内の `test {}` ブロック。
- `std.testing.allocator` 必須（リーク検出）。view の arena 関数は `ArenaAllocator`。
- 各ファイル `test { std.testing.refAllDecls(@This()); }`。
- 新規 `.zig` モジュールは作らない（`validateAnchor`/`isDiffOwnerCurrent` は `update.zig` 内、
  `selectByPathPriority`/`setDiffOwner`/`clearDiffOwner` は `model.zig` 内のプライベート関数）。
- Bug 1 の auto-refresh シナリオは「`diff_loaded` を reducer に直接流す」連続シーケンステストで再現
  （worker thread / タイミングに依存しない・決定論的）。

## 7. レビュー経過（spec を subagent + codex で並行レビュー実施済み）

本 spec を subagent（`worker` droid）と codex CLI（`gpt-5.2-codex` 試行失敗後デフォルトモデル）で
並行レビューし、両者の指摘を反映した:

### subagent（worker）レビュー: APPROVE-WITH-NITS
- **N1（反映）**: `validateAnchor` の cond-a（`isBodyLine`）と後続 `hunkIndexForLine != null` は
  「同値」というコメントが不正確（@@ ヘッダ行は `isBodyLine=false` だが `hunkIndexForLine` は non-null）。
  → コメントを「`isBodyLine=true` なら必ず non-null（ボディ行はハンク内）。到達不能だが防御的に残す」へ訂正。
- 全技術的主張（anchor-clear 監査・validateAnchor 正確性・行番号・優先順位逆転・所有権）を C1-C11 で確認済み。

### codex レビュー: NEEDS-CHANGES → 修正で APPROVE 相当へ
- **B1（ブロッカー・反映）**: `clampCursor` 単独では「diff がどのファイルのものか」を知れないため、
  外部プロセスで `selected` が別ファイルへ切り替わった後に `diff_loaded` が届くと stale anchor が生存する
  （従来の無条件 clear では起きなかった回帰）。`src/update.zig:198-201`（status_loaded → replaceFiles → loadDiffCmd）と
  `clampCursor` の責務分離が不十分だった。
  → **層 1（ファイル同一性ゲート）**を新設: `model.diff_owner` フィールド + `isDiffOwnerCurrent` ヘルパ +
  `diff_loaded` arm の先頭で同一性検証（不一致なら anchor clear）。解決方針・変更箇所 2.0/2.0b/2.1/2.2 へ展開。
- **N1（反映）**: Bug 1 再現テストのプロse「`v → j → j`」とテスト本体（`diff_cursor_down` 1 回）のズレ。
  → プロse を「`v → j`」へ修正し、層 1 のセットアップ（`setDiffOwner`）をテストへ明記。
- **N2（反映）**: `found_path_only` 1 パス + `selectByPathPriority` 2 パスの冗長。
  → 仕様レベルで「entries は小規模（部分 stage で高々 2-3 エントリ増）なので計算量は問題にならない」を明記。
  実装時に単一パスへ統合するかは実装者の判断（振る舞いは等価）。
- **N3（反映）**: `selectByPathPriority` の「unreachable」コメントが括弧漏れかつ実際は `return 0`。
  → 「防御的フォールバック（契約違反時）」へ訂正。`unreachable` にはしない（安全側）。
- 全技術的主張（C1-C10）を確認済み。B1 以外は全て confirmation。

### 両レビューを統合した設計判断
- 両者とも「`validateAnchor` と `selectByPathPriority` の純粋性・所有権」を確認（リーク無し）。
- 両者とも「既存テストの回帰なさ」を確認（完全一致・index クランプ・既存の anchor clear 経路）。
- codex のみが「ファイル同一性」の抜け（B1）を指摘。subagent はこれを見逃していた。
  並行レビューの価値を示す例（単一レビューでは B1 が未検出のまま実装へ進むリスクがあった）。

実装後も subagent + codex でコードレビューを行う（ユーザー指示）。
