# ログ / コミットグラフ表示 設計 — TODO 2 / phase 1（線形一覧 + detail）

- 日付: 2026-06-18（rev.9: codex 8 次レビュー反映版・show-ref --quiet で ref 不存在時の正しい exit code 取得）
- 対象: `TODO.md`「TODO 2. ログ / コミットグラフ表示」のうち **phase 1**（線形コミット一覧 + 選択コミットのファイル一覧 + diff）
- 親設計: `docs/superpowers/specs/2026-06-14-git-tui-design.md`
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（既存 `src/git/process.zig`/`commands.zig`/`appcmd.zig` の実例を正とする）
- スコープ外: phase 2（グラフ罫線・レーン割当）/ フィルタ / log 中の stage / **author・日時の表示**（phase 2 ヘ移行・§5 参照）

---

## 0. codex レビュー反映の対応表

### 0.1 1 次レビュー（rev.1 → rev.2）

| 指摘 ID | 重要度 | 内容 | 反映節 |
|---|---|---|---|
| H1 | 高 | stale result 拒否（結果 Msg へ request_hash/path/skip/max_count/generation） | §1.3, §1.4, §1.6 |
| H2 | 高 | paging busy 方針統一（専用フラグ削除・既存 worker 一系統・`log_page_requested` のみ） | §1.3, §1.6, §2 |
| H3 | 高 | log_loaded/log_page_loaded へ max_count/skip を持たせる | §1.4 |
| H4 | 高 | merge の name-status と diff を `--diff-merges=first-parent` で統一 | §1.7, §4 |
| H5 | 高 | name-status を NUL 区切り・header なし（`--format=` + `-z`） | §1.2, §1.7 |
| H6 | 高 | appendLogCommits/replaceLogCommits/replaceDetailFiles の所有権具体化（deep-copy → swap） | §1.3 |
| H7 | 高 | Zig の既定関数引数は不可能（`*ForMode` wrapper 新設） | §3 |
| M1 | 中 | ページング発火経路（down 操作が `load_log_page` を直接返す） | §1.6, §3 |
| M2 | 中 | `log_page_offset` 削除・skip は常に `log_commits.items.len` | §1.3, §1.6 |
| M3 | 中 | EOF 判定（`< max_count` で確定・`==` で maybe-more） | §1.6, §6 |
| M4 | 中 | 空リポジトリ扱い（unborn 判定・それ以外は error） | §1.7, §6 |
| M5 | 中 | log 侵入時の focus `.changes` 正規化・log 中の tab は `.changes ↔ .diff` | §1.6, §3 |
| M6 | 中 | マウス用 Msg（`log_select_index`/`detail_select_index`）と row 解析 | §1.4, §3 |
| M7 | 中 | detail 戻り操作キー統一（Esc/Backspace/`u`） | §3 |
| M8 | 中 | author/日時表示は phase 2 ヘ移行（phase 1 受け入れ基準から除外・TODO.md ヘ明記） | §5 |
| M9 | 中 | log/detail 描画で `std.mem.join(a, "\n", ...)` 明記 | §3 |
| M10 | 中 | テスト戦略拡張（stale/paging error/page boundary/mouse/focus 正規化/merge detail） | §6 |
| M11 | 中 | `r`（log 中）は generation を進めて load_log・選択 hash 復元・detail 消去 | §1.6 |
| L1-L5 | 低 | phase 2 lane frontier / `--decorate=short --no-color` / 共通ヘルパ / detail_diff 破棄 / auto-refresh 抑止明記 | §2, §3, §5, §7 |

### 0.2 2 次レビュー（rev.2 → rev.3）で追加反映

| 指摘 ID | 重要度 | 内容 | 反映節 |
|---|---|---|---|
| R1 | 高 | `next.append(a, try cloneCommit(...))` の clone リーク（append 失敗時）。ローカル変数 + errdefer で対処 | §1.3 |
| R2 | 高 | 空履歴 guard（`log_commits.items.len == 0` での `items[0]`/`len-1` panic）。空分岐で owner/detail 消去 + `.none` | §1.6 |
| R3 | 高 | mode 退出時の generation 無効化（log 中に changes へ戻った後の遅延結果適用防止）。全結果 arm で `view_mode == .log` も検証 | §1.6 |
| R4 | 高 | refresh 選択 hash 復元が実装不能（一覧空化後に対象 hash が失われる）。`log_restore_hash: ?[]u8` で保持 | §1.3, §1.6 |
| R5 | 高 | `hasHead` は unborn と他エラーを区別できない。tri-state helper `headState()` 新設（unborn/error/ok） | §1.7 |
| R6 | 高 | unborn 時に page command でも常に `log_loaded` を返す→`log_page_requested` が下がらない。command tag で `log_loaded`/`log_page_loaded` を切替 | §1.7 |
| R7 | 高 | page 失敗の全経路（spawn/parse/OOM）を `log_page_failed` へ。appcmd が全エラーを catch し request metadata 付きで返す | §1.7 |
| R8 | 高 | busy setter と spawn fallback の両立（reducer が busy を触らないなら runtime が fallback 完了後に busy/working を下ろす） | §1.6, §7 |
| R9 | 高 | `isMutating` と `seedInitialStatus` の exhaustive switch 更新（新 AppCmd を足さないとコンパイル不能） | §7 |
| R10 | 中 | `log_page_loaded` の戻り値が節間で矛盾（§1.6 `.none` vs §2/§7 `load_commit_detail`）。成功適用後は選択があれば `load_commit_detail` を返すよう統一 | §1.6, §2, §7 |
| R11 | 中 | `log_page_failed` の skip 照合（generation のみならず期待 skip と一致判定）。`log_page_requested: ?usize`（期待 skip）へ拡張 | §1.3, §1.6 |
| R12 | 中 | `parseNameStatus` の R/C フィールド順序（`R100\0old\0new\0` で最初が旧パス）。`orig_path=first`, `path=second` | §1.2 |
| R13 | 中 | log/detail スクロール Msg 追加（`log_scroll`/`detail_files_scroll`/`detail_diff_scroll`）。Ctrl+d/u・ホイール | §1.4, §3 |
| R14 | 中 | マウス選択時の focus 更新（`log_select_index` arm で `.changes`・`detail_select_index` arm で `.diff` へ） | §1.6 |
| R15 | 中 | log parser の終端（trailing NUL 有無両方を受理）。実コマンドは「最終 NUL なし」でテスト | §1.1, §6 |
| R16 | 中 | OOM 時の owner と payload 順序（payload 構築 + errdefer → owner 更新・既存 `loadDiffCmd` と同順） | §1.6 |

### 0.3 3 次レビュー（rev.3 → rev.4）で追加反映

| 指摘 ID | 重要度 | 内容 | 反映節 |
|---|---|---|---|
| R17 | 高 | `len - 5` が履歴 1-4 件で `usize` underflow し Debug で panic。`log_commits.items.len >= 5` を条件へ追加 | §1.6, §2 |
| R18 | 高 | page 要求が worker 稼働中で pending に入り detail 要求で上書きされると消え、`log_page_requested` が永久 non-null に。reducer ゲートで `log_page_requested != null` の間は `load_commit_detail` を発行しない（page 完了後に `log_page_loaded` arm が自動発火・R10）。★4 次レビューで `log_open_detail`/`detail_select_file`/`log_select_index` にもゲート追加 | §1.6, §2 |
| R19 | 高 | `rev-parse --verify HEAD` の exit 128 は unborn 固定ではなく壊れた HEAD・object 欠損・権限エラーでも返る。★4 次レビューで `headState` を 3 段階判定（rev-parse exit 128 → symbolic-ref で branch 名取得 → `git rev-parse --verify refs/heads/<branch>` で ref 実在確認）へ強化 | §1.7 |
| R20 | 高 | `allocPrint(...) catch "固定文字列"` は所有 `[]u8` と文字列リテラルの型不整合でコンパイル不能。さらに `headState()` 自体の spawn/OOM が catch 範囲外で R7 違反。全経路で `a.dupe(u8, ...)` で所有確保・`headState` のエラーも `log_page_failed` へ | §1.7 |
| R21 | 高 | 4 次レビュー: R20 の OOM フォールバックの dupe も失敗すると `error.OutOfMemory` が伝播し `log_page_failed` が届かない→`log_page_requested` が永久 non-null で再試行も不能。`log_page_failed_silent`（payload 無し・所有ポインタ無し・deinit 不要）独立 Msg を新設し、OOM 極限ではこちらを返す | §1.4, §1.6, §1.7 |
| R22 | 高 | 5 次レビュー: `log_page_loaded` arm で `appendLogCommits(entries)` が OOM だと `log_page_requested = null` に到達せずページング永久停止。順序入替（先に `log_page_requested = null`・その後 `appendLogCommits` で OOM なら error return・次回 down で再試行可能） | §1.6 |
| R23 | 高 | 5 次レビュー: R19 の dangling branch ref 対策不十分（`git rev-parse --verify refs/heads/<branch>` は dangling でも exit 128）。`git show-ref --verify refs/heads/<branch>` で ref ファイルの存在だけを判定（object 検証しない）へ変更。HEAD exit 128 + show-ref exit 0 = dangling → .err。★8 次レビュー: `show-ref --verify <ref>` は ref 不存在時に **exit 128** を返す（exit 1 ではない）ため、`--quiet` 付きで実行し exit 1（unborn）を正しく取得 | §1.7 |
| R23b | 高 | 5 次レビュー: R20 の擬似コードがコンパイル不能（`mkPageFailedOrSilent` の `err` 未定義・`mkPageFailedSilent` の `a` 未使用）。シグネチャと呼び出しを整合させ、`a` は OOM fallback 用に受け取る（使わない場合は `_` で受ける） | §1.7 |
| R24 | 高 | 5 次レビュー: マウス仕様矛盾（ホイールで `log_scroll_*` と `log_cursor_*` を両方発火としたが `mouseToMsgForMode` は `?Msg` 1 件）。ホイールは scroll 系のみへ統一（cursor は j/k と `log_select_index` クリックのみ・page 発火は j/k のみ） | §3.4, §3.5 |
| R25 | 高 | 6 次レビュー: `keyToMsgForLog(focus, key)` は `detail_kind`（files/diff）を判定できず右ペインのキー割当が実装不能。引数へ `detail_kind` を追加。`*ForMode` wrapper 系も同様 | §3.1 |
| R26 | 高 | 6 次レビュー: `commit_detail_loaded`/`detail_diff_loaded` 構築時に複数 dupe の errdefer が無く、途中 OOM で先に確保した entries/hash/path がリーク。各 dupe の順序付け + errdefer で対処 | §1.7 |

---

## 1. アーキテクチャ（純粋層への追加）

### 1.1 新モジュール `src/git/log.zig`（NUL 区切り `git log` パーサ）

`logArgv`（§1.7）が生成する `git log --pretty=format:...%x00%d -z --decorate=short --no-color` 出力をパースする。

```zig
pub const Commit = struct {
    hash: []u8,          // 40 hex (sha-1) / 64 hex (sha-256)。persistent 所有。
    parents: [][]u8,     // persistent 所有（各要素も）。phase 2 レーン割当の伏線。空 = root。
    author: []u8,        // 日本語可
    epoch_sec: i64,
    subject: []u8,       // 日本語可
    refs: []u8,          // decorate 結果（" (HEAD -> main, tag: v1)"）。空可。raw 文字列（phase 1 は表示のみ・パースしない）。
    pub fn deinit(self: *Commit, a: std.mem.Allocator) void {
        a.free(self.hash);
        for (self.parents) |p| a.free(p);
        a.free(self.parents);
        a.free(self.author);
        a.free(self.subject);
        a.free(self.refs);
    }
};

/// 呼び出し側が返り値スライスと各要素を deinit する（status.parse と同じ契約）。
pub fn parse(a: std.mem.Allocator, raw: []const u8) ![]Commit {
    // -z はコミット間を NUL(\0) で区切る。format 内の %x00 も NUL でフィールド区切り。
    // よって「連続する 6 トークン（hash/P/an/at/s/d）ごとに 1 commit」。
    // ★R15: trailing NUL 有無を両方受理。実 git log -z は「最終 commit の後に NUL 無し」で終わる
    //   （最後の %d が空なら subject トークンの直後で終端）。splitScalar は空トークンを返すので
    //   6 の倍数で無い余剰トークンは単に無視する（実 git 出力とテストフィクスチャの両方で通る）。
    // %P は空白区切りの hash 列（マージで 2 個以上）→ splitScalar(u8, p, ' ') で parents へ。
    // %at は Unix epoch 秒 → std.fmt.parseInt(i64, at, 10)。
    // 空リポジトリ（raw が空）は &.{} を返す（appcmd 側で headState 判定済み・R5）。
    // checkAllAllocationFailures で部分確保失敗時の不正 free/leak を検証する。
}
```

### 1.2 新モジュール `src/git/show.zig`（`git show --name-status` パーサ）★H5 対応

detail 右ペインのファイル一覧用。`showNameStatusArgv`（§1.7）が生成する
`git show --diff-merges=first-parent --format= --name-status -z <hash>` 出力をパースする。
`--format=`（空 format）で commit header を消し、`-z` で NUL 区切りにする（H5）。

```zig
pub const NameStatus = struct {
    status: u8,          // 'A'/'M'/'D'/'R'/'C'（R/C は similarity score 付き R100/C75 等の先頭 1 文字）
    path: []u8,          // 新パス（R/C の新側・tracked は当該パス）。persistent 所有。
    orig_path: ?[]u8,    // R/C の旧パス（★R12: -z 出力で先に来る方）。tracked 変更は null。persistent 所有。
    pub fn deinit(self: *NameStatus, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.orig_path) |p| a.free(p);
    }
};

/// 呼び出し側が返り値スライスと各要素を deinit する。
pub fn parseNameStatus(a: std.mem.Allocator, raw: []const u8) ![]NameStatus {
    // -z 形式: status トークン → path トークン（→ R/C は更に orig_path トークン）→ 次 status…
    //   ★R12: 実 git の -z 出力は "M\0f.txt\0R100\0old.txt\0new.txt\0A\0new.txt\0"。
    //   R/C は「旧パスが先・新パスが次」（git の --name-status 仕様）。
    //   よって parseNameStatus は status トークン先頭（'A'/'M'/'D'/'R'/'C'）を見て
    //   R/C のとき次トークンを orig_path（旧）、その次を path（新）として消費する。
    //   tracked 変更（A/M/D）は次トークンを path とし orig_path = null。
    // similarity score 付き（R100/C75 等）は先頭 1 文字だけで判定（score は phase 1 で未使用）。
    // タブ/改行を含む合法パスも NUL 区切りなので安全（splitScalar(u8, raw, 0)）。
    // 空コミット（raw 空）は &.{} を返す。
    // checkAllAllocationFailures で部分確保失敗時の不正 free/leak を検証する。
}
```

### 1.3 `Model` への追加フィールド（H1, H2, H6, M2 対応）

```zig
pub const ViewMode = enum { changes, log };
pub const DetailKind = enum { files, diff };

pub const Model = struct {
    // 既存フィールド...
    view_mode: ViewMode,                  // 新設（既定 .changes）

    // log 一覧（左ペイン）
    log_commits: std.ArrayList(log.Commit),   // persistent 所有・deinit で各要素を deinit
    log_selected: usize,                      // 選択コミットの格納 index
    log_scroll: usize,                        // 表示先頭 visual row
    log_has_more: bool,                       // まだ未取得のコミットがあるか（EOF で false）
    log_request_generation: u64,              // ★H1/M11/R3: load_log 要求の世代。結果 Msg がこれと一致する時のみ適用。
    log_page_requested: ?usize,               // ★H2/R11: 次ページ要求済みの期待 skip（重複防止のみ・worker 直列化とは別）。null = 要求無し。
    log_restore_hash: ?[]u8,                  // ★R4: refresh（log 中の `r`）で一覧を空にする前の選択 hash を退避。log_loaded で復元後 null へ。
    // ★削除: log_page_offset（M2）・log_paging_busy（H2）。skip は log_commits.items.len から計算。

    // detail（右ペイン）: 選択コミットの所有物 + ★H1 stale-result オーナー
    detail_kind: DetailKind,                  // .files or .diff
    detail_files: std.ArrayList(show.NameStatus),  // persistent 所有
    detail_selected: usize,
    detail_scroll: usize,
    detail_owner_hash: ?[]u8,                 // ★H1: 現在表示中の detail が何の hash に対応するか。結果受領時に照合。
    detail_diff: []u8,
    detail_diff_scroll: usize,
    detail_diff_owner_hash: ?[]u8,            // ★H1: 現在表示中の diff が何の (hash, path) に対応するか。
    detail_diff_owner_path: ?[]u8,

    pub fn init(a, repo_root) !Model {
        // 既存 + 新規フィールドを全て既定値で初期化（log_commits/detail_files = .empty、各 owner_* = null、
        // log_request_generation = 0、log_page_requested = null、log_restore_hash = null、
        // log_has_more = false、view_mode = .changes）。
    }
    pub fn deinit(self: *Model) void {
        // 既存解放 + log_commits の各要素 deinit + detail_files の各要素 deinit + detail_diff の free
        //   + detail_owner_hash/detail_diff_owner_hash/detail_diff_owner_path/log_restore_hash の free。
    }
};
```

**所有権とトランザクショナル更新（H6 対応）**:

```zig
/// 入力 `entries`（Msg 所有）を deep-copy して新 ArrayList を構築し、成功後に旧を解放して swap（H6）。
/// 入力 `entries` 自体は呼び出し元（Msg の消費者）が deinit する（Model は借用・複製所有）。
pub fn replaceLogCommits(self: *Model, entries: []const log.Commit) !void {
    const a = self.allocator;
    var next: std.ArrayList(log.Commit) = .empty;
    errdefer {
        for (next.items) |*c| c.deinit(a);
        next.deinit(a);
    }
    for (entries) |e| {
        // ★R1: clone をローカル変数で受け、append 成功まで errdefer で保護する。
        //   `next.append(a, try cloneCommit(...))` は clone 成功後に append が失敗すると clone がリークする。
        var cloned = try cloneCommit(a, e);
        errdefer cloned.deinit(a);
        try next.append(a, cloned);
    }
    // 成功後に旧を解放して swap
    for (self.log_commits.items) |*c| c.deinit(a);
    self.log_commits.deinit(a);
    self.log_commits = next;
}

/// 既存 log_commits.items と入力 new_entries を全て deep-copy した unified list を構築 → swap（H6）。
/// **shallow copy は絶対にしない**（cleanup 時の二重 free を防ぐ）。
pub fn appendLogCommits(self: *Model, new_entries: []const log.Commit) !void {
    const a = self.allocator;
    var next: std.ArrayList(log.Commit) = .empty;
    errdefer {
        for (next.items) |*c| c.deinit(a);
        next.deinit(a);
    }
    for (self.log_commits.items) |c| {
        var cloned = try cloneCommit(a, c);     // ★R1
        errdefer cloned.deinit(a);
        try next.append(a, cloned);
    }
    for (new_entries) |e| {
        var cloned = try cloneCommit(a, e);     // ★R1
        errdefer cloned.deinit(a);
        try next.append(a, cloned);
    }
    for (self.log_commits.items) |*c| c.deinit(a);
    self.log_commits.deinit(a);
    self.log_commits = next;
}

/// replaceLogCommits と同型。detail_files への適用。NameStatus も同様に deep-copy し append 毎に errdefer。
pub fn replaceDetailFiles(self: *Model, entries: []const show.NameStatus) !void { /* 同上 */ }

/// H1: detail_owner_hash / detail_diff_owner_* のセット（旧を free して dup）。
pub fn setDetailOwnerHash(self: *Model, hash: []const u8) !void { /* setStr 相当 */ }
pub fn setDetailDiffOwner(self: *Model, hash: []const u8, path: []const u8) !void { /* 両方セット */ }
pub fn clearDetailOwner(self: *Model) void { /* hash を free して null */ }
pub fn clearDetailDiffOwner(self: *Model) void { /* hash/path を free して null */ }

/// R4: log_restore_hash のセット（refresh 時に選択 hash を退避）。
pub fn setLogRestoreHash(self: *Model, hash: []const u8) !void { /* setStr 相当 */ }
pub fn clearLogRestoreHash(self: *Model) void { /* free して null */ }

/// ヘルパ: Commit の deep-copy（新 allocator へ全フィールド複製）。
/// ★R1: 各フィールド毎に errdefer で順次 rollback する（途中 OOM で確保済みバッファを漏らさない）。
fn cloneCommit(a: std.mem.Allocator, c: log.Commit) !log.Commit {
    var out: log.Commit = undefined;
    out.hash = try a.dupe(u8, c.hash);
    errdefer a.free(out.hash);
    out.parents = try cloneStringSlice(a, c.parents);
    errdefer freeStringSlice(a, out.parents);
    out.author = try a.dupe(u8, c.author);
    errdefer a.free(out.author);
    out.subject = try a.dupe(u8, c.subject);
    errdefer a.free(out.subject);
    out.refs = try a.dupe(u8, c.refs);
    errdefer a.free(out.refs);
    out.epoch_sec = c.epoch_sec;
    return out;
}
fn cloneStringSlice(a: std.mem.Allocator, src: []const []u8) ![][]u8 { /* 各要素 dupe + errdefer */ }
fn freeStringSlice(a: std.mem.Allocator, src: [][]u8) void { /* 各要素 free + slice free */ }
```

`replaceLogCommits`/`appendLogCommits`/`replaceDetailFiles` には `checkAllAllocationFailures` を適用する（既存 `status.zig`/`model.zig` と同パターン）。

### 1.4 `Msg` 追加バリアント（messages.zig）★H1/H3/M6 対応

```zig
pub const Msg = union(enum) {
    // 既存...
    // --- log/detail 系入力 ---
    toggle_view_mode,                 // L キー（changes <-> log）
    log_cursor_down, log_cursor_up,   // log ペイン j/k（末尾到達で page 要求も兼ねる・M1）
    log_open_detail,                  // Enter/Space: 選択コミットのファイル一覧の明示的再取得
    log_scroll_down, log_scroll_up,   // ★R13: log ペインの Ctrl+d/u・ホイール（選択移動無し・scroll のみ）
    detail_cursor_down, detail_cursor_up,
    detail_select_file,               // Enter/Space: 選択ファイルの diff 要求（.files → .diff）
    detail_back_to_files,             // Esc/Backspace/u: .diff → .files（L4: detail_diff を空へ）
    detail_files_scroll_down, detail_files_scroll_up,  // ★R13: detail files ペインの Ctrl+d/u・ホイール
    detail_diff_scroll_down, detail_diff_scroll_up,    // ★R13: detail diff ペインの Ctrl+d/u・ホイール
    log_select_index: usize,          // ★M6: log ペインのマウスクリック
    detail_select_index: usize,       // ★M6: detail ファイル一覧のマウスクリック

    // --- 解釈器からの結果（全て所有・複製済み）★H1 構造体化 ---
    log_loaded: LogLoaded,            // 初回ロード結果（H1/H3）
    log_page_loaded: LogLoaded,       // 追加ページ結果（H1/H3）。appendLogCommits へ。
    log_page_failed: LogPageFailed,   // ★H2/R7: paging 失敗専用（全エラー経路・spawn/parse/OOM 含む）
    log_page_failed_silent: LogPageFailedSilent,  // ★R21: OOM 極限で error_text すら構築不能な時の silent 版。payload 無し・log_page_requested を確実に下ろすことだけが目的。
    commit_detail_loaded: CommitDetailLoaded,   // ★H1 構造体（stale reject 用 request_hash）
    detail_diff_loaded: DetailDiffLoaded,       // ★H1 構造体

    pub const LogLoaded = struct {
        request_skip: usize,          // ★H3: 要求時の skip（log_commits.items.len と照合）
        request_max_count: usize,     // ★H3: 要求時の max_count（EOF 判定に使用）
        request_generation: u64,      // ★H1/M11: 要求時の generation（model.log_request_generation と照合）
        entries: []log.Commit,        // 所有（consumer が deinit）
    };
    pub const LogPageFailed = struct {
        request_skip: usize,          // ★R11: 失敗した要求の skip（model.log_page_requested の期待値と照合）
        request_generation: u64,      // ★H1/M11
        error_text: []u8,             // 所有
    };
    /// ★R21: OOM 極限（error_text の dupe も失敗）で log_page_failed が構築不能なときの silent 版。
    ///   request_skip/request_generation のみ（所有ポインタ無し）・deinit 不要。
    ///   reducer は log_page_failed と同じ処理（log_page_requested = null・error_text は空のまま）。
    pub const LogPageFailedSilent = struct {
        request_skip: usize,
        request_generation: u64,
    };
    pub const CommitDetailLoaded = struct {
        request_hash: []u8,           // ★H1: 要求時の hash（model.detail_owner_hash と照合・不一致は破棄）
        entries: []show.NameStatus,   // 所有
    };
    pub const DetailDiffLoaded = struct {
        request_hash: []u8,           // ★H1
        request_path: []u8,           // ★H1（model.detail_diff_owner_hash/path と照合）
        text: []u8,                   // 所有
    };

    pub fn deinit(self: *Msg, a: std.mem.Allocator) void {
        // 網羅的 switch（else 無しで新バリアント強制）。
        // log_loaded/log_page_loaded: entries の各要素を deinit + entries を free。
        // log_page_failed: error_text を free。
        // commit_detail_loaded: request_hash を free + entries の各要素を deinit + entries を free。
        // detail_diff_loaded: request_hash/request_path/text を free。
        // それ以外（入力系・既存）: 解放不要。
    }
};
```

### 1.5 `AppCmd` 追加バリアント（messages.zig）

```zig
pub const AppCmd = union(enum) {
    // 既存...
    load_log: LoadLog,             // 初回（skip=0）/ 再取得（generation 更新）
    load_log_page: LoadLog,        // 追加ページ（skip = 現在の items.len）
    load_commit_detail: []u8,      // hash 所有・git show --name-status
    load_detail_diff: LoadDetailDiff,  // git show <hash> -- <path>
    pub const LoadLog = struct { skip: usize, max_count: usize, generation: u64 };  // 単純値・free 不要
    pub const LoadDetailDiff = struct { hash: []u8, path: []u8 };  // 所有・deinit で free

    pub fn deinit(self: *AppCmd, a: std.mem.Allocator) void {
        // 網羅的 switch。load_commit_detail/load_detail_diff の所有ポインタを free。他は解放不要。
    }
};
```

### 1.6 `update.zig` reducer 拡張点（純粋）★H1/H2/M1/M2/M3/M5/M11/R2/R3/R4/R10/R11/R14/R16 対応

reducer は結果 Msg の `request_*` と Model の owner / generation が一致する場合のみ適用（H1）。
**busy の setter は runtime 側 only**（reducer は `model.busy` を触らない・R8）。
**全 log/detail 結果 arm の先頭で `view_mode == .log` を検証**（R3: changes へ戻った後の遅延結果適用防止）。不一致は deinit して `.none`。
**空履歴 guard（R2）**: `log_commits.items.len == 0` のとき `log_cursor_*`/`log_open_detail`/`detail_*` は owner/detail を消去して `.none`（panic 回避）。

- `toggle_view_mode`（M5: focus 正規化・R3: generation 無効化）:
  - `.changes → .log`: `view_mode = .log`、`focus = .changes`（★正規化・`.commit` から入っても `.changes` へ）、`log_request_generation += 1`（★R3: 以前の遅延結果を無効化）、`log_page_requested = null`、`log_has_more = false`、`clearDetailOwner()`/`clearDetailDiffOwner()`、`replaceDetailFiles(&.{})`、`setStr(&detail_diff, "")`。`return .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = model.log_request_generation } };`
  - `.log → .changes`（★R3）: `view_mode = .changes`、`focus = .changes`（M5: 復元しない・固定）、**`log_request_generation += 1`**（★R3: これにより以降に到着する log 系結果 Msg は全て generation 不一致で破棄される）、`log_page_requested = null`。`return .refresh_status;`

- `log_cursor_down`（M1: page 発火経路・R2 空 guard・★R17 underflow 対策）:
  - **R2**: `log_commits.items.len == 0` なら `clearDetailOwner()`・`replaceDetailFiles(&.{})`・`setStr(&detail_diff, "")`・`.none`。
  - `log_selected` を動かす（最大 `log_commits.items.len - 1`）。
  - **M1 + ★R17**: `log_has_more and log_page_requested == null and log_commits.items.len >= 5 and (log_selected >= log_commits.items.len - 5)` のとき（★R17: `len >= 5` も条件へ追加し `len - 5` の underflow を防止・`std.math.Order`/saturating sub 相当）、`log_page_requested = log_commits.items.len`（★R11: 期待 skip を保持）にして `return .{ .load_log_page = .{ .skip = model.log_commits.items.len, .max_count = 100, .generation = model.log_request_generation } };`（detail の load は次回 down/結果受領時へ遅延）。
  - **★R18**: `log_page_requested != null`（page 要求 in-flight 中）のときは `load_commit_detail` を発行せず `.none`（page 完了後に `log_page_loaded` arm が自動発火・選択 hash で）。
  - それ以外: `setDetailOwnerHash(log_commits.items[log_selected].hash)` して `return .{ .load_commit_detail = dupe(hash) };`（★R16: dupe 成功後に setDetailOwnerHash。payload 先に構築）。

- `log_cursor_up`（R2 空 guard・R18）:
  - **R2**: `log_commits.items.len == 0` なら `.none`。
  - **R18**: `log_page_requested != null` のときは `.none`（page 完了後に `log_page_loaded` arm が自動発火）。
  - `log_selected` を減らす（`> 0` のとき）。
  - `setDetailOwnerHash(log_commits.items[log_selected].hash)` して `return .{ .load_commit_detail = dupe(hash) };`（★R16）。

- `log_open_detail`（R2 空 guard・R18 pending ゲート）:
  - **R2**: `log_commits.items.len == 0` なら `.none`。
  - **R18**: `log_page_requested != null` のときは `.none`（page 完了後に `log_page_loaded` arm が自動発火）。
  - 現在の選択 hash で detail を明示再取得。`setDetailOwnerHash(hash)` → `return .{ .load_commit_detail = dupe(hash) };`

- `log_scroll_down`/`log_scroll_up`（★R13）: `log_scroll` を増減（0 以上・`log_commits.items.len` 以下へクランプ）。`.none`（scroll は page 要求と無関係・R18 ゲート無し）。

- `detail_cursor_down`/`detail_cursor_up`（R2 空 guard）: `detail_files.items.len == 0` なら `.none`。`detail_selected` を動かすだけ（diff は load しない・`.none`）。★R18 ゲート不要（detail 内移動は log page と無関係）。
- `detail_files_scroll_down`/`detail_files_scroll_up`（★R13）: `detail_scroll` を増減。`.none`。
- `detail_diff_scroll_down`/`detail_diff_scroll_up`（★R13）: `detail_diff_scroll` を増減（0 以上・`detail_diff` 行数未満へクランプ）。`.none`。

- `detail_select_file`（R2 空 guard・R16 順序・R18 pending ゲート）:
  - **R2**: `detail_files.items.len == 0` なら `.none`。
  - **R18**: `log_page_requested != null` のときは `.none`（page 完了後に `log_page_loaded` arm が `load_commit_detail` を発火→detail 再ロードで `detail_files` が更新されるので、その後ユーザが再 Enter で diff 表示。page 中は diff 表示を遅延）。
  - payload を先に構築: `const hash = try dupe(log_commits.items[log_selected].hash); errdefer a.free(hash); const path = try dupe(detail_files.items[detail_selected].path); errdefer a.free(path);`（★R16）。
  - 成功後: `detail_kind = .diff`・`setDetailDiffOwner(hash, path)`・`detail_diff_scroll = 0`・`return .{ .load_detail_diff = .{ .hash = hash, .path = path } };`（所有権移譲）。

- `detail_back_to_files`（L4）: `detail_kind = .files`・`setStr(&detail_diff, "")`・`detail_diff_scroll = 0`・`clearDetailDiffOwner()`・`.none`（R18 ゲート不要・純粋な state 切替）。

- `log_select_index: |i|`（M6・R2 空 guard・R18 pending ゲート・R14 focus 更新）:
  - **R2**: `log_commits.items.len == 0` なら `.none`。
  - **R18**: `log_page_requested != null` のときは `log_selected = i`（範囲内）・`focus = .changes` まで更新し `.none`（detail ロードは page 完了後の `log_page_loaded` arm が発火）。
  - 範囲内なら `log_selected = i`・`focus = .changes`（★R14: クリックで left ペインへフォーカス）。
  - その後 `log_cursor_down`/`up` と同じ detail 再ロード経路へ（setDetailOwnerHash + load_commit_detail）。

- `detail_select_index: |i|`（M6・R14 focus 更新）:
  - `detail_kind == .files and i < detail_files.items.len` のとき `detail_selected = i`・`focus = .diff`（★R14: クリックで right ペインへフォーカス）。`.none`。
  - `detail_kind == .diff` のときは無視（diff 中はマウスクリックでファイル移動しない）。`.none`。

- `request_refresh`（log モード時・M11・R3/R4）:
  - `log_request_generation += 1`（★R3）・`log_page_requested = null`・`log_has_more = false`。
  - **R4**: 選択 hash を refresh 前に退避。`if (log_commits.items.len > 0) setLogRestoreHash(log_commits.items[log_selected].hash) else clearLogRestoreHash();`
  - `replaceLogCommits(&.{})` で一旦空へ・`clearDetailOwner()`・`replaceDetailFiles(&.{})`・`setStr(&detail_diff, "")`・`detail_kind = .files`。
  - `return .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = model.log_request_generation } };`

- 結果 Msg（全て `view_mode == .log` 検証 + generation/skip/hash/path 照合で stale reject・不一致時は deinit して `.none`）:
  - `log_loaded`（H1/H3/M3/R4）:
    - `view_mode != .log or request_generation != model.log_request_generation or request_skip != 0` → 破棄。
    - 適用: `replaceLogCommits(entries)` → ★R4: `if (log_restore_hash) |h| { 選択を hash 一致で復元（無ければ 0）; clearLogRestoreHash(); } else { log_selected = 0; }`。`log_has_more = (entries.len >= request_max_count)`（M3）。`log_page_requested = null`。`detail_kind = .files`。
    - **R2**: `log_commits.items.len == 0` なら `clearDetailOwner()`・`replaceDetailFiles(&.{})`・`return .none;`
    - `setDetailOwnerHash(log_commits.items[log_selected].hash)` → `return .{ .load_commit_detail = dupe(hash) };`（★R16）。
  - `log_page_loaded`（H1/H3/M3/R10/R11/R22）:
    - `view_mode != .log or request_generation != model.log_request_generation or request_skip != model.log_page_requested`（★R11: 期待 skip と一致判定）→ 破棄。
    - ★R22: `appendLogCommits(entries)` の**前に** `log_page_requested = null` を実行（OOM で reducer が error return しても `log_page_requested` は既に null・ページング永久停止を防ぐ）。順序: (1) `model.log_page_requested = null`・(2) `appendLogCommits(entries) catch return error.OutOfMemory;`（※appcmd ではなく update の reducer 内なので error return は runtime へ伝播するが、`log_page_requested` は既に null なので次回 down で再試行可能・busy は runtime 側で結果 Msg の処理有無に関わらず下ろす）。
    - 成功後: `log_has_more = (entries.len >= request_max_count)`・**R10**: 選択が存在すれば（`log_commits.items.len > 0`）`setDetailOwnerHash(log_commits.items[log_selected].hash)` して `return .{ .load_commit_detail = dupe(hash) };`（選択と detail の不一致を防ぐ）。空なら `.none`。
  - `log_page_failed`（H2/R7/R11）と `log_page_failed_silent`（R21）:
    - `view_mode != .log or request_generation != model.log_request_generation or (model.log_page_requested != null and request_skip != model.log_page_requested.?)` → 破棄（★R11）。
    - `log_page_requested = null`（H2/R7/R21: 失敗でも確実に下ろす）。`log_page_failed` のみ `setStr(&model.error_text, error_text)`（silent 版は error_text 空のまま）。`.none`。
  - `commit_detail_loaded`（H1/R3）:
    - `view_mode != .log or request_hash != model.detail_owner_hash`（不一致）→ 破棄。一致なら `replaceDetailFiles(entries)`・`detail_selected = 0`・`detail_kind = .files`・`.none`。
  - `detail_diff_loaded`（H1/R3）:
    - `view_mode != .log or request_hash != model.detail_diff_owner_hash or request_path != model.detail_diff_owner_path`（不一致）→ 破棄。一致なら `setStr(&detail_diff, text)`・`detail_diff_scroll = 0`・`.none`。

### 1.7 `appcmd.zig` 解釈器拡張点（H4/H5/L2/M4 対応）

`commands.zig` へ argv 生成を追加（L2: `--decorate=short --no-color` 明示）:

```zig
pub fn logArgv(a: std.mem.Allocator, skip: usize, max_count: usize) ![]const []const u8 {
    // git -c core.quotePath=false log --skip=<skip> --max-count=<max_count>
    //     --pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d -z --decorate=short --no-color
    // ※ skip=0 のとき --skip=0 は付けない（git が警告するため）。引数リストを分岐で構築。
}

pub fn showNameStatusArgv(a: std.mem.Allocator, hash: []const u8) ![]const []const u8 {
    // ★H4/H5: 第一親との差・header なし・NUL 区切り。
    // git -c core.quotePath=false show --diff-merges=first-parent --format= --name-status -z <hash>
}

pub fn showFileDiffArgv(a: std.mem.Allocator, hash: []const u8, path: []const u8) ![]const []const u8 {
    // ★H4: name-status と同じ第一親基準。root コミットでは --diff-merges=first-parent は無視され initial patch が返る。
    // git -c core.quotePath=false show --diff-merges=first-parent --format= <hash> -- <path>
}
```

`appcmd.run` の switch へ arm 追加（既存 `refresh_status`/`.load_diff` と同型・結果 Msg の構築で request_* を埋める）:

**R5/R19/R23: `headState` tri-state helper** を `commands.zig` へ新設:
```zig
pub const HeadState = enum { ok, unborn, err };
/// ★R19/R23: rev-parse --verify HEAD だけでも symbolic-ref HEAD だけでも dangling branch ref と unborn を
/// 完全に区別できない。よって **3 段階**で厳密判定する:
///   (1) `git rev-parse --verify HEAD` の exit code:
///       - exit 0  → .ok（HEAD あり・正常）
///       - exit 128 → (2) へ
///       - それ以外の非 0 → .err（壊れたリポジトリ・権限エラー等・ unborn ではない）
///   (2) exit 128 のとき、HEAD が symbolic ref か確認（`git symbolic-ref --short HEAD`）:
///       - 失敗（detached HEAD や broken HEAD）→ .err
///       - 成功（branch 名を取得）→ (3) へ
///   (3) ★R23: 取得した branch 名で `git show-ref --verify --quiet refs/heads/<branch>` を実行:
///       - exit 0 → ★R23: ref が存在するが HEAD が exit 128 なら dangling ref（object が無い）→ .err
///         （※`git rev-parse --verify refs/heads/<branch>` は dangling でも exit 128 になるため区別不能。
///           ★R23b 実測: `git show-ref --verify <ref>` は ref 不存在時に **exit 128** を返す（exit 1 ではない）。
///           `--quiet` を付けると ref 不存在時に exit 1・存在時に exit 0 になるので、判定は必ず
///           `--quiet` 付きで実行する。これで (1) HEAD exit 128 + (3) show-ref --quiet exit 1 = unborn 確定。）
///       - exit 1 → ref が存在しない = unborn（空リポジトリ）→ .unborn
///       - その他 → .err（権限等）
///   ※unborn 確定には (1) exit 128 + (2) symbolic-ref 成功 + (3) show-ref exit 1 が全て必要。
///   ★R23: dangling branch ref（ref は有るが object が無い）を unborn と誤判定しない。
/// 既存 hasHead（bool・M4 の落とし穴）と置き換え、log 系では必ずこちらを使う。
/// ★R20: `headState` 自体の spawn/OOM も考慮。RunError/OOM は `!HeadState` で伝播させ、
///   appcmd 側で `log_page_failed` へ変換する（R7 の全失敗経路保証）。
pub fn headState(a: std.mem.Allocator, io: std.Io, cwd: Cwd) !HeadState { /* 3 段階判定 */ }
```

- `.load_log`/`.load_log_page`（M4/R5/R6/R7/R19/R20/R21/R23）:
  - ★R20/R21/R23b: `headState` 呼び出しを catch し、`log_page_failed` を構築する。所有 `[]u8` と文字列リテラルの型不整合を避けるため、error_text は常に `a.dupe(u8, "...")` で所有確保する。OOM 極限では `log_page_failed_silent` へフォールバック:
    ```zig
    const hs = cmds.headState(a, io, cwd) catch
        return mkPageFailedOrSilent(a, cmd, "git リポジトリ状態の確認に失敗");
    switch (hs) {
      - `.unborn`: 空配列を返す。**★R6: command tag で切替**（`.load_log` → `Msg.log_loaded`、`.load_log_page` → `Msg.log_page_loaded`）。`request_skip`/`request_max_count`/`request_generation` は cmd から転写。entries は `&.{}`。
      - `.err`: ★R20/R21/R23: `mkPageFailedOrSilent(a, cmd, "git リポジトリ状態が壊れています")` を返す（★R19/R23: 壊れた HEAD・object 欠損・権限エラー・dangling branch ref もこちらへ）。
      - `.ok`: 下へ。
    }
    ```
  - `logArgv(skip, max_count)` → `process.run`。**★R7/R21/R23b: spawn/parse/OOM も catch**。`runLogInt` 内で全エラーを catch し `mkPageFailedOrSilent` で包む:
    ```zig
    fn runLogInt(a, io, cwd, cmd) !Msg {
        const res_bytes = process.run(a, io, argv, cwd) catch
            return mkPageFailedOrSilent(a, cmd, "git log 実行エラー");
        defer res_bytes.deinit(a);
        if (res_bytes.exit_code != 0) {
            // stderr の複製が失敗したら silent 版へ。
            const text = a.dupe(u8, res_bytes.stderr) catch return mkPageFailedSilent(cmd);
            return .{ .log_page_failed = .{ .request_skip = cmd.skip, .request_generation = cmd.generation, .error_text = text } };
        }
        const entries = log.parse(a, res_bytes.stdout) catch
            return mkPageFailedOrSilent(a, cmd, "git log パース失敗");
        return switch (cmd_tag) { .load_log => Msg.log_loaded(...), .load_log_page => Msg.log_page_loaded(...) };
    }
    /// ★R20/R21/R23b: prefix から allocPrint でメッセージ構築。OOM で dupe(prefix)・それも失敗したら silent 版。
    ///   `_` で a を受け取る（OOM 時に silent 版へ fallback するため a は使わないがシグネチャ上一致）。
    fn mkPageFailedOrSilent(a: std.mem.Allocator, cmd: AppCmd.LoadLog, prefix: []const u8) Msg {
        const text = std.fmt.allocPrint(a, "{s}", .{prefix}) catch {
            // prefix の dupe も試みる（短いので成功しやすい）。
            const dup = a.dupe(u8, prefix) catch return mkPageFailedSilent(cmd);
            return Msg{ .log_page_failed = .{ .request_skip = cmd.skip, .request_generation = cmd.generation, .error_text = dup } };
        };
        return Msg{ .log_page_failed = .{ .request_skip = cmd.skip, .request_generation = cmd.generation, .error_text = text } };
    }
    /// ★R21: OOM 極限の silent 版。payload 無し・log_page_requested を確実に下ろすことだけが目的。
    ///   allocator 不要（request_skip/request_generation のみ）。
    fn mkPageFailedSilent(cmd: AppCmd.LoadLog) Msg {
        return Msg{ .log_page_failed_silent = .{ .request_skip = cmd.skip, .request_generation = cmd.generation } };
    }
    ```
- `.load_commit_detail`（R26: 複数 dupe の errdefer）:
  - `showNameStatusArgv` → `process.run`。exit_code != 0 は `Msg{ .git_error = dupe(stderr) }`（H4 一貫性・detail は stale reject されるので安全）。spawn 失敗等も `git_error` へ（detail は stale reject で消えるので log_page_failed 程の厳密さは不要）。
  - 成功時: `show.parseNameStatus(a, stdout)` で entries を取得→★R26: `Msg{ .commit_detail_loaded = .{ ... } }` 構築時に request_hash と entries の両方を所有する。**entries は既に所有済み（parse が alloc）・request_hash を dupe**。順序: (1) `const entries = try show.parseNameStatus(a, stdout); errdefer { for (entries) |*e| e.deinit(a); a.free(entries); }`・(2) `const hash = try a.dupe(u8, cmd.load_commit_detail); errdefer a.free(hash);`・(3) `return Msg{ .commit_detail_loaded = .{ .request_hash = hash, .entries = entries } };`（所有権移譲）。OOM で reducer/runtime は回復不能だが、少なくとも leak しない（errdefer が entries と hash を解放）。

- `.load_detail_diff`（R26）:
  - `showFileDiffArgv` → `process.run`。exit_code != 0 は `Msg{ .git_error = dupe(stderr) }`。
  - 成功時: text/hash/path の 3 つを所有。★R26: 順序 (1) `const text = try a.dupe(u8, stdout); errdefer a.free(text);`・(2) `const hash = try a.dupe(u8, cmd.hash); errdefer a.free(hash);`・(3) `const path = try a.dupe(u8, cmd.path); errdefer a.free(path);`・(4) `return Msg{ .detail_diff_loaded = .{ .request_hash = hash, .request_path = path, .text = text } };`（所有権移譲）。

---

## 2. ページング戦略（H2/M1/M3/R7/R8/R10/R11/L5 対応）

- **1 回 100 件**（`--max-count=100`）。初回 `skip=0`、末尾到達で次 `skip = log_commits.items.len`（M2: `log_page_offset` は廃止）。
- **H2: busy ゲートは既存 worker 一系統のみ**。`dispatchSideEffect` の pending latest-wins に乗る。新設 `log_paging_busy` 等の並行実行用フラグは**持たない**。
- **R11: 重複要求防止のみ**: `log_page_requested: ?usize`（期待 skip）を Model へ。`log_cursor_down` が page 要求時に期待 skip をセット、`log_page_loaded`/`log_page_failed` の両方で `null` へ戻す（H2/R7: 成功・失敗両方で確実に下ろす）。
- **R7: page 失敗の全経路**: spawn・process・parse・OOM も `log_page_failed` へ（appcmd が catch して request metadata 付きで返す・§1.7）。`git_error` 汎用では log_page_requested が永久 true になる事故を防ぐ。
- **★R18: page 要求の pending 上書き問題**: 既存 `dispatchSideEffect` の pending latest-wins は pending が上書きされると破棄する。page 要求（`load_log_page`）が worker 稼働中で pending に入り、その後 detail 要求（`load_commit_detail`）が発火すると page が pending から消え、`log_page_requested` が永久 non-null になりページング不能になる。**対策（後者推奨・runtime 側に触れない）**: `log_page_requested != null` の間は reducer の `log_cursor_down`/`up`/`log_select_index` が `load_commit_detail` を発行しない（`.none` を返すか scroll のみ）。page 完了後に `log_page_loaded` arm が★R10 のとおり `load_commit_detail` を自動発火するので、結果的に選択と detail は整合する。
- **R8: busy setter と spawn fallback の両立**: reducer は `model.busy` を触らない（H1）。runtime `dispatchSideEffect` の spawn 失敗 fallback 経路（`workerRun` を直接呼ぶ）完了後に、runtime が `busy = false`/`working = false` をセットする（既存の「結果 reducer が busy=false にする」契約から変更）。これにより log 系に限らず全副作用で spawn fallback が busy を残さない。
- **page 取得中の j/k**: 既存 `pending` 機構で間引かれる。page 結果受領後に reducer が自動で `load_commit_detail` を再発火（`log_page_loaded` arm が★R10: 選択が存在すれば `load_commit_detail` を返す）。UX 若干悪化だが実装単純・安定。
- **M3 EOF 判定**: `entries.len < request_max_count` で EOF 確定（`log_has_more = false`）。`==` は maybe-more（`log_has_more = true`）。100/101/200 件でテスト。
- **M1 page 発火契約**: `log_cursor_down`（または wheel_down・`log_select_index`）が `log_has_more and log_page_requested == null and log_commits.items.len >= 5 and (log_selected >= log_commits.items.len - 5)`（★R17: underflow 防止のため `len >= 5` 追加）のとき page 要求を直接返す。
- **auto-refresh 協調（L5）**: `autorefresh.shouldAutoRefresh` が `view_mode == .log` で即 `false`。**log モード中は外部で履歴が変わっても自動反映しない**（仕様として明記）。`r` で明示的再取得のみ。

---

## 3. UI 統合とフォーカス（H7/M5/M6/M7/M9/L3 対応）

### 3.1 キー/マウス正規化（H7: wrapper 新設・既存は変更しない）

**既存 `pub fn keyToMsg(focus: Focus, key: Key) ?Msg` は変更しない**（既存テスト・call site を壊さない）。
新設:

```zig
/// ★R25: `detail_kind` 引数追加（focus==.diff の detail 右ペインが files/diff でキー割当を変えるため）。
///   focus==.changes（log 左ペイン）のときは detail_kind を無視。
pub fn keyToMsgForMode(mode: ViewMode, focus: Focus, detail_kind: DetailKind, key: Key) ?Msg {
    return switch (mode) {
        .changes => keyToMsg(focus, key),  // 既存へ delegating（detail_kind は無視）
        .log => keyToMsgForLog(focus, detail_kind, key),
    };
}
/// ★R25: focus==.diff（detail 右ペイン）のキー割当は `detail_kind`（files/diff）で変わるため引数へ追加。
///   focus==.changes（log 左ペイン）は detail_kind 無視。
fn keyToMsgForLog(focus: Focus, detail_kind: DetailKind, key: Key) ?Msg { /* log モード専用マップ（下表） */ }
```

`keyToMsgForMode` の呼び出し側（`main.handleKey`）は `keyToMsgForMode(app.model.view_mode, app.model.focus, app.model.detail_kind, key)` のように model から detail_kind を渡す。

同様に `mouseToMsgForMode(mode, ev, detail_kind)`/`fromZigzagMouseForMode(mode, ev, detail_kind, ...)` を新設（既存 `mouseToMsg`/`fromZigzagMouse` は変更しない）。★R25: detail_kind 引数追加。`main.handleKey`/`handleMouse` は `*ForMode` を呼ぶ。

### 3.2 フォーカス（M5: 正規化）

- `toggle_view_mode` で `.changes → .log` のとき `focus = .changes`（正規化）。`.commit` から入っても `.changes` へ。
- log モード中の `focus_next`（tab）: `.changes ↔ .diff` のみ（`.commit` へは行かない）。
- `.log → .changes` へ戻るとき `focus = .changes`（復元しない）。

### 3.3 レイアウト（L3: 極小端末ヘルパ共通化）

```zig
/// 共通ヘルパ（L3）: status 1 行確保・top の最低高さ 1・u16 clamp。
fn computeTopAndStatus(w: u16, h: u16) struct { top_h: u16, status_h: u16 } { /* 既存 computeLayout から抽出 */ }

/// changes モード（既存・変更なし）。
pub fn computeLayout(w, h, commit_h) Layout { /* computeTopAndStatus を使うよう内部だけリファクタ */ }

/// log モード（新設）。
pub const LogLayout = struct { log: Rect, detail: Rect, status: Rect };
pub fn computeLogLayout(w: u16, h: u16) LogLayout {
    const ts = computeTopAndStatus(w, h);
    const left_w: u16 = if (w == 0) 0 else @intCast(@as(u32, w) * 40 / 100);
    return .{
        .log = .{ .x = 0, .y = 0, .w = left_w, .h = ts.top_h },
        .detail = .{ .x = left_w, .y = 0, .w = w - left_w, .h = ts.top_h },
        .status = .{ .x = 0, .y = h - ts.status_h, .w = w, .h = ts.status_h },
    };
}
```

### 3.4 キーバインド一覧（log モード・M7: detail 戻りキー統一・R13: スクロール系・R24: マウス仕様）

| キー | left(log) focus | right(detail) focus |
|---|---|---|
| `j`/`↓` | `log_cursor_down`（末尾付近で page 要求） | `detail_cursor_down`（.files）/ `detail_diff_scroll_down`（.diff） |
| `k`/`↑` | `log_cursor_up` | `detail_cursor_up`（.files）/ `detail_diff_scroll_up`（.diff） |
| `Enter`/`Space` | `log_open_detail` | `detail_select_file`（.files）/ no-op（.diff） |
| `Esc`/`Backspace`/`u` | no-op | `detail_back_to_files`（.diff → .files）★M7 |
| `tab` | `focus = .diff` | `focus = .changes` |
| `L` | `toggle_view_mode`（→ .changes） | 同左 |
| `q` | 終了 | 終了 |
| `r` | `request_refresh`（log 再取得） | 同左 |
| `Ctrl+d`/`Ctrl+u` | ★R13 `log_scroll_down`/`up` | ★R13 `detail_files_scroll_down`/`up`（.files）/ `detail_diff_scroll_down`/`up`（.diff） |
| ホイール down/up（★R24） | ★R24 `log_scroll_down`/`up` のみ（cursor 移動はしない・1 Msg 制約） | ★R24 対応する detail scroll 系のみ |

既存 changes キー（`s`/`space` で stage・`c` で commit focus・`v`/`#`/`H` で選択）は **log モードでは無効化**（`keyToMsgForLog` が null を返す）。

★R24: `mouseToMsgForMode` は `?Msg`（1 件）を返す契約のため、ホイールで scroll と cursor を両方発火することはできない。**ホイールは scroll 系のみ**（cursor 移動はキーボード j/k・クリック `log_select_index` で行う）。末尾到達時の page 発火は j/k の `log_cursor_down` のみ（ホイールでは発火しない・実装単純化）。

### 3.5 マウス（M6: log_select_index/detail_select_index・R24: ホイールは scroll のみ）

- `input.MouseEvent` に `log_row: ?usize`/`detail_row: ?usize` を追加（changes の `file_row` と同型）。
- `view.logRowLayout(model, out)`/`view.detailRowLayout(model, out)` 純粋関数を新設（`changesRowLayout` と同型・描画と当たり判定で共有）。
- `fromZigzagMouseForMode(.log, detail_kind, ...)` が `computeLogLayout` を使い log/detail ペインの当たり判定へ分岐。`log_scroll`/`detail_scroll`/`detail_diff_scroll` を考慮して絶対 visual row を解く（`changesRowLayout` と同じ方式）。
- `mouseToMsgForMode(.log, ev, detail_kind)` の契約（★R24 統一・1 Msg 制約）:
  - `left_click`:
    - log ペインのクリック → `log_select_index`（cursor 移動 + focus=.changes・detail は reducer 側で遅延ロード・R18 ゲート考慮）
    - detail ファイル一覧（.files）のクリック → `detail_select_index`（focus=.diff へ）
    - detail diff（.diff）のクリック → `set_focus=.diff`（cursor 移動しない・diff は読み取り専用）
    - ペイン境界・見出し行 → `set_focus`
  - `wheel_down`/`wheel_up`: **★R24 scroll 系のみ**（cursor 移動はしない）:
    - log ペイン → `log_scroll_down`/`up`
    - detail files（.files）→ `detail_files_scroll_down`/`up`
    - detail diff（.diff）→ `detail_diff_scroll_down`/`up`
    - ※cursor 移動・page 発火はキーボード j/k とクリックのみ。ホイールは純粋に scroll。
- ダブルクリックは phase 1 では単クリックと同じ（stage 無し）。

### 3.6 描画（M9: プレーン `\n` 結合明記）

- `view.render` が `view_mode` で分岐。`.changes` は既存 4 矩形へ。`.log` は新設:
  - `renderLog(model, ctx, height)`: `std.mem.join(a, "\n", lines.items)` でプレーン改行結合（★M9: `zz.joinVertical` は使わない）。`fitPane` で幅/高さクランプ。形式 `<short-hash> <subject> <refs>`（refs は `zz.Color.green`・ANSI 含む行を `zz.measure.truncate` で切り詰め）。
  - `renderDetail(model, ctx, height)`: `detail_kind` で分岐。`.files` は NameStatus 一覧（`<status> <path>`・rename は `R old → new`）。`.diff` は既存 `renderDiff` の選択/ハイライト無し版（`+`/`-` 色分けのみ・`detail_diff` を表示）。どちらも `std.mem.join(a, "\n", ...)`。
- 最終全体配置のみ `zz.joinHorizontal`（log | detail）→ `zz.joinVertical`（top + status）。
- 回帰テスト（`fitPane` 既存テストと同型）: 長い ANSI refs 行・日本語 subject・幅 0/1 ペインで桁超過・`...` 付加がないことを検証。

### 3.7 README/TODO 更新

- README.md: log モードのキー操作追記。
- TODO.md: TODO 2 の phase 1 達成チェックボックスと phase 2 残（グラフ罫線・author/日時表示）を明記。

---

## 4. detail（ファイル一覧 / diff）の切り替け（H4 対応）

- **コミット選択 → ファイル一覧**: 自動ロード（`log_cursor_down`/`up`/`log_select_index` が `load_commit_detail` を発行）。j/k 連打は pending latest-wins + H1 stale reject で整合性確保。
- **ファイル選択 → diff**: `detail_select_file` が `load_detail_diff` を発行。`showFileDiffArgv` は `--diff-merges=first-parent --format=` を使い name-status と同じ第一親基準（H4）。
- **マージコミット**: name-status も diff も第一親との差で一貫。phase 2 で `--cc`（combined diff）対応を検討。
- **root コミット**: 親無し。`--diff-merges=first-parent` は無視され initial patch/name-status が返る（結合テストで検証）。
- **既存 `diff/hunk.zig`**: `detail_diff` は通常 unified diff なので `hunk.parse` が通る。phase 1 では stage 系（`buildPatch`/`buildLinePatch`）は使わない（log は読み取り専用）。phase 2 で `git checkout <hash> -- <path>` 等の cherry-pick 系を足す際に再利用可能。

---

## 5. 参照ラベル と author/日時（M8 対応）

- **参照ラベル**: `logArgv` が `--pretty=format:...%x00%d --decorate=short --no-color`（L2）。`Commit.refs` に raw 文字列（` (HEAD -> main, tag: v1)`）を保持。phase 1 はパースせず表示のみ。phase 2 で色分け時にパース。
- **表示位置**: コミット行 `<short-hash> <subject> <refs>`。refs は `zz.Color.green`。長い subject で refs が隠れる場合は `fitPane` の `truncate` で許容（phase 2 でカラム固定を検討）。
- **author/日時（M8）**: ★phase 1 では**表示しない**。`Commit.author`/`epoch_sec` は Model に保持するが描画は phase 2 ヘ移行。理由: phase 1 のスコープを「線形一覧 + detail」へ集中し、カラムレイアウト（hash/author/date/subject/refs）は phase 2（グラフ罫線）と同時に検討。**TODO.md の該当 subtask「日本語の作者名・コミットメッセージ・参照ラベルの桁計算」を phase 2 残として明記**。phase 1 受け入れ基準から author/日時表示を除外。

---

## 6. テスト戦略（M10 拡張）

### 6.1 `git/log.zig` 単体（`std.testing.allocator` 必須）
- NUL 区切り基本（1 コミット・hash/P/an/at/s/d の 6 フィールド）。
- 複数親（マージ: `%P` が 2 個 hash）。
- root（`%P` 空・`parents.len == 0`）。
- 日本語 author/subject（`山田太郎`/`日本語の件名`）。
- 複数 refs（` (HEAD -> main, origin/main, tag: v1.0)`）。
- 空 raw（空配列）。
- ★R15: trailing NUL 有り・無しの両方を受理（実 git log -z は「最終 NUL 無し」。テストフィクスチャは両方を用意）。
- ★R15: 最終 commit の `%d` が空（refs 無し）のケースも終端確認。
- `checkAllAllocationFailures`。

### 6.2 `git/show.zig` 単体
- `A`/`M`/`D`/`R100 old→new`/`C75 old→new`/日本語パス/空コミット。
- ★R12: R/C は `R100\0old\0new\0` 形式（旧パスが先）。`orig_path=old`, `path=new` となることを検証。
- NUL 区切り・`--format=` で header 無しを前提とした入力。
- `checkAllAllocationFailures`。

### 6.3 `update.zig` reducer（M10: stale/paging error/boundary/focus 正規化/R2/R3/R4/R10/R11/R14）
- `toggle_view_mode`: `.changes → .log` で focus 正規化（`.commit` → `.changes`）+ `load_log` 発行 + generation 更新。`.log → .changes` で `focus = .changes` + `refresh_status` + ★R3 generation 更新（遅延結果無効化）。
- `log_cursor_down`: 末尾 N 件以内 + `log_has_more` で `load_log_page`（`skip = items.len`）+ `log_page_requested = 期待 skip`（R11）。
- ★R2: 空履歴（`log_commits.items.len == 0`）での `log_cursor_down`/`up`/`log_open_detail`/`detail_*` が panic せず `.none`。
- `log_page_loaded`: `appendLogCommits` + `log_page_requested = null` + EOF 判定（`<` vs `==`）+ ★R10 選択が存在すれば `load_commit_detail` を返す。
- `log_page_failed`: `log_page_requested = null` + error_text 設定 + ★R11 skip 照合で破棄。
- `commit_detail_loaded` stale reject: A 要求 → B 要求 → A 結果（破棄）→ B 結果（適用）。
- `detail_diff_loaded` stale reject: 同上（hash/path 両方で照合）。
- `log_loaded` stale reject: generation 不一致で破棄 + ★R3 mode 退出後（`view_mode != .log`）の到着結果も破棄。
- ★R4: `request_refresh`（log 中）→ 選択 hash を `log_restore_hash` へ退避 → `log_loaded` で hash 一致 index へ復元（不一致は 0）+ `clearLogRestoreHash()`。
- ★R14: `log_select_index` arm で `focus = .changes`、`detail_select_index` arm で `focus = .diff` へ更新される。
- page boundary: 100/101/200 件での `log_has_more` 遷移。

### 6.4 `appcmd.zig` 結合（`TmpRepo` ヘルパ再利用・M10/R5/R6/R7: merge detail 一貫性・全 page failure 経路）
- 初回コミット 1 個で `load_log` → 1 件・`parents.len == 0`・`load_commit_detail` で initial patch が返る（root）。
- 3 コミット + ブランチ + タグで `load_log` → `refs` に ` (HEAD -> main, tag: v1)`。
- マージコミット（`git merge`）で `load_log` → `parents.len == 2`。★`load_commit_detail` と `load_detail_diff` が第一親との差で一貫（name-status に載るファイルが diff にも載る）。
- 100/101/200 件のダミーコミットで `load_log` + `load_log_page` の `skip`/`max_count`/EOF。
- ★R5/R6: 空リポジトリ（HEAD unborn）で `load_log`/`load_log_page` が空配列を返す（command tag で `log_loaded`/`log_page_loaded` を切替・M4）。壊れた HEAD・権限エラーは `log_page_failed`（`headState == .err`）。
- ★R7: page failure の全経路（意図的に `git log` を壊す・存在しない HEAD・spawn 不能な状況のモック）が `log_page_failed` を返し `log_page_requested` を下ろす。
- 日本語ファイル名の `load_detail_diff` が raw UTF-8（`core.quotePath=false`）。
- argv 単体: `logArgv`/`showNameStatusArgv`/`showFileDiffArgv` が `--diff-merges=first-parent`/`--format=`/`-z`/`--decorate=short --no-color` を含む。★R5: `headState` が tri-state（ok/unborn/err）を返す。

### 6.5 `input.zig`/`view.zig`（M10: mouse hit-test/R13 scroll）
- `keyToMsgForMode(.log, ...)` の全キーマップ（§3.4 表・★R13 scroll 系含む）。
- `keyToMsgForMode(.changes, ...)` が既存 `keyToMsg` と同一結果（回帰）。
- `fromZigzagMouseForMode(.log, ...)` の log/detail ペイン当たり判定・`log_row`/`detail_row` 解析・スクロールオフセット考慮。
- `computeLogLayout` の 40/60 分割・極小端末クランプ・`computeLayout` との共通ヘルパ一致。
- `fitPane` の log/detail 適用（長い ANSI refs・日本語 subject・幅 0/1 で崩れない）。

---

## 7. リスクと未解決事項（L1/R8/R9 対応）

- **既存コードへの影響**:
  - `view.render`: `view_mode` 分岐追加。`renderChanges`/`renderDiff`/`renderCommit` は changes 専用のまま・log は `renderLog`/`renderDetail` 新設。
  - `input.keyToMsg`/`mouseToMsg`/`fromZigzagMouse`: **変更しない**（H7）。`*ForMode` wrapper を新設。`main.handleKey`/`handleMouse` のみ切り替え。
  - `main.maybeAutoRefresh`: `view_mode == .log` で即 return（1 行）。
  - `main.applyAppCmd`: 網羅的 switch へ新 4 arm 追加。全て `dispatchSideEffect` 経由。
  - **★R9: `main.isMutating` と `main.seedInitialStatus` の exhaustive switch**: 新 AppCmd バリアント（`load_log`/`load_log_page`/`load_commit_detail`/`load_detail_diff`）を追加しないとコンパイル不能。`isMutating` は全 load 系を `false`（読み取り専用・スピナ無し）へ追加。`seedInitialStatus` の switch は起動時（`.changes` モード固定）なので log 系は到達不能だが、網羅性のため `else => {}` ではなく各バリアントを明示的に `.none` 扱いで追加する（既存 `.none/.quit/.apply_patch` と同様）。
  - **★R8: `main.dispatchSideEffect` の spawn fallback**: thread spawn 失敗時に `workerRun` を直接呼ぶ経路で、完了後に runtime が `busy = false`/`working = false` をセットする（既存の「結果 reducer が busy=false にする」契約を runtime へ移動）。reducer が busy を触らない（H1）こととの整合。
  - `autorefresh.shouldAutoRefresh`: `view_mode` 引数追加（log で false）。既存 call site は `.changes` を明示渡しへ更新（既定引数は使わない・H7）。
  - `seedInitialStatus`: 起動は `.changes` 固定なので log 系は呼ばれないが、★R9 のとおり switch の網羅性のため log 系バリアントを明示追加する。
- **phase 2（グラフ罫線）への拡張（L1）**: `Commit.parents: [][]u8` と `view_mode` は拡張を妨げない。phase 2 では「全 loaded commits を append 後に再計算」or「frontier 保持で増分計算」を選ぶ（phase 2 spec で決定）。phase 1 の `log_commits` 格納順 = git log 出力順（拓浦順）= phase 2 レーン割当の入力順。
- **ワーカー直列化と paging の競合**: `load_log_page`（page）と `load_commit_detail`（j/k）が同時 in-flight になると pending latest-wins で後者が間引かれる。page 完了後に `log_page_loaded` arm が★R10 のとおり `load_commit_detail` を自動再発火するので最終的には整合する（UX 若干悪化・H2 推奨）。
- **`%d`（decorate）出力形式**: git version 間で安定。`--decorate=short --no-color` で環境設定に委ねない（L2）。

---

## 8. 実装順序の提案（TDD・純粋層 → UI 層・R1-R16 反映）

1. `src/git/log.zig`: `Commit`/`parse` + 単体（NUL 区切り・複数親・日本語・refs・★R15 trailing NUL 有無・`checkAllAllocationFailures`）。
2. `src/git/show.zig`: `NameStatus`/`parseNameStatus` + 単体（A/M/D/R100/C75・日本語・NUL 区切り・★R12 R/C は orig_path 先・`checkAllAllocationFailures`）。
3. `src/git/commands.zig`: `logArgv`/`showNameStatusArgv`/`showFileDiffArgv` + ★R5 `headState`/`HeadState` + argv 単体（`--diff-merges=first-parent`/`--format=`/`-z`/`--decorate=short --no-color` 含む・`headState` tri-state 検証）。
4. `src/root_test.zig`: `@import("git/log.zig")`/`@import("git/show.zig")` を有効化。
5. `src/model.zig`: `ViewMode`/`DetailKind` + log/detail フィールド + owner 系（H1）+ `log_request_generation`/`log_page_requested: ?usize`（H2/R11）+ `log_restore_hash`（R4）+ `init`/`deinit` 拡張 + `replaceLogCommits`/`appendLogCommits`/`replaceDetailFiles`/`setDetailOwnerHash`/`setDetailDiffOwner`/`clearDetail*`/`setLogRestoreHash`/`clearLogRestoreHash`/`cloneCommit`/`cloneStringSlice`/`freeStringSlice`（H6/R1: append 毎に errdefer で clone を保護）+ 単体（`checkAllAllocationFailures` 含む）。
6. `src/messages.zig`: `Msg`/`AppCmd` 新バリアント + 構造体（`LogLoaded`/`LogPageFailed`/`CommitDetailLoaded`/`DetailDiffLoaded`/`LoadLog`/`LoadDetailDiff`）+ ★R13 scroll 系 Msg（`log_scroll_*`/`detail_files_scroll_*`/`detail_diff_scroll_*`）+ 網羅的 `deinit` + 単体（所有ペイロード free 検証）。
7. `src/update.zig`: 新 arm + 結果 Msg arm（★R2 空 guard・★R3 view_mode 検証・stale reject・generation/skip/hash/path 照合・★R10 log_page_loaded 後の load_commit_detail 自動発火・★R14 focus 更新・★R16 payload 先構築）+ 単体（M10/R10 全ケース）。
8. `src/appcmd.zig`: 新 arm（`load_log`/`load_log_page`/`load_commit_detail`/`load_detail_diff`）+ ★R5 `headState` で unborn/err 判定・★R6 command tag で `log_loaded`/`log_page_loaded` 切替・★R7 全エラー経路を `log_page_failed` へ・`runLogInt` helper（spawn/parse/OOM を catch）+ 結合（`TmpRepo` で merge/tag/日本語/100-101-200/root/unborn/broken-HEAD/page-failure・H4 一貫性）。
9. `src/input.zig`: `keyToMsgForMode`/`mouseToMsgForMode`/`fromZigzagMouseForMode` + `keyToMsgForLog` + ★R13 scroll 系キーマップ + 単体（H7 wrapper・既存 `keyToMsg` 等は変更しない）。
10. `src/view.zig`: `computeTopAndStatus`（共通ヘルパ抽出）+ `computeLogLayout` + `logRowLayout`/`detailRowLayout` + `renderLog`/`renderDetail` + `render` の `view_mode` 分岐 + 単体（`computeLogLayout`・`fitPane` 回帰）。
11. `src/autorefresh.zig`: `shouldAutoRefresh` へ `view_mode` 引数追加・log で false・既存 call site へ `.changes` 明示渡し・単体。
12. `src/main.zig`: `applyAppCmd` 網羅 switch へ 4 arm・★R9 `isMutating`/`seedInitialStatus` の網羅的 switch へ新バリアント追加（load 系は `false`/`.none` 扱い）・★R8 `dispatchSideEffect` spawn fallback で busy/working を runtime が下ろす・`maybeAutoRefresh` の log 抑止・`handleKey`/`handleMouse` の `*ForMode` 切替。
13. README.md: log モードのキー操作追記。
14. TODO.md: TODO 2 phase 1 達成 + phase 2 残（グラフ罫線・author/日時表示）を明記。
15. 手動 pty 検証（`tmux capture-pane`）: 100 件超で page 発火・merge コミット detail・日本語 author・refs 表示・空リポジトリで log モード投入。

---

## 9. 設計判断サマリ（codex レビュー反映版・rev.5）

| # | 判断 | 推奨（rev.5） | 理由 |
|---|---|---|---|
| A | Focus 拡張 vs `view_mode` 新設 | **`view_mode` 新設 + 既存 Focus 使い回し + ★mode 切替時の `.changes` 正規化 + log 用 tab reducer（`.changes ↔ .diff`）+ ★R3 mode 退出時の generation 無効化** | Focus に `.log`/`.detail` を足すと全レンダ分岐が倍化。codex 指摘通り focus 正規化・tab reducer・stale 無効化は必須（M5/R3） |
| B | detail 自動ロード vs 明示 Enter | **自動ロード + ★stale-result reject（H1）+ ★空履歴 guard（R2）+ ★R16 payload 先に構築 + ★R18 page pending 中は detail ロードを抑制** | latest-wins 単独では不十分。結果 Msg へ request_hash を持たせ reducer で照合。空配列での panic と page pending 上書き事故を防ぐ |
| C | `git show` vs `git diff <parent>..<hash>` | **`git show --diff-merges=first-parent`（name-status も diff も同じ・H4）+ ★R5/R19 `headState` 3 段階 tri-state で unborn 判定** | name-status と diff の一貫性。root では無視されて initial patch。phase 2 で `--cc` 拡張 |
| D | ページング busy ゲート | **★既存 worker 一系統のみ（`log_paging_busy` 等は廃止・`log_page_requested: ?usize` で重複防止のみ・R11）・成功・失敗両方で下ろす・★R7 page 失敗の全経路を `log_page_failed` へ・★R8 busy setter は runtime 専用・★R21 OOM 極限は `log_page_failed_silent` で確実解除** | 実装単純・安定。失敗時の `log_page_failed`/`_silent` 独立 Msg で確実解除。runtime が spawn fallback でも busy を下ろす |
| E | 参照ラベル取得 | **`%d` + ★`--decorate=short --no-color` 明示（L2）** | 環境設定に委ねない。phase 1 は raw 表示・phase 2 で色分け時にパース |
| F | log モードの auto-refresh | **完全抑止 + ★外部履歴変更の自動非反映を明記（L5）+ ★R3 mode 退出時の generation 無効化で遅延結果適用防止** | log は読み取り専用・`r` で明示的再取得のみ |

---

## 付録: 既存コードパターンの明示参照

- **パーサ**: `src/git/status.zig parse`（NUL 区切り・`splitScalar(u8, raw, 0)`・`ArrayList(StatusEntry).empty`/`toOwnedSlice`・errdefer で未初期化スロット保護・`checkAllAllocationFailures`）を `log.zig`/`show.zig` が模倣。★R15: splitScalar の空トークンは無視（trailing NUL 有無両対応）。
- **argv 生成**: `src/git/commands.zig diffArgv`（`ArrayList([]const u8).empty`・`appendSlice`・`-c core.quotePath=false` 挿入）を `logArgv`/`showNameStatusArgv`/`showFileDiffArgv` が模倣。★R5: `hasHead` と同型の `headState`/`HeadState` tri-state helper を新設。
- **appcmd run switch**: `src/appcmd.zig run` の `.refresh_status`/`.load_diff` arm（`process.run` → `cmds.*Argv` → `parse` → `Msg.*_loaded`・exit_code != 0 で `git_error`）を新 4 arm が模倣。但し結果 Msg は構造体化（H1）・★R5 `headState` 判定・★R6 command tag 切替・★R7 `runLogInt` で全エラーを `log_page_failed` へ。
- **Msg/AppCmd deinit**: `src/messages.zig` の網羅的 switch（`else` 無しで新バリアント強制）へ新バリアントと構造体を追加。
- **Model 所有権**: `src/model.zig replaceFiles`（トランザクショナル・errdefer で新リスト解放・旧リストは成功後に入れ替え・`checkAllAllocationFailures`）を `replaceLogCommits`/`appendLogCommits`/`replaceDetailFiles` が模倣（H6: deep-copy → swap・★R1 append 毎に clone を errdefer で保護・shallow copy 禁止）。`setStr` を `setDetailOwnerHash`/`setLogRestoreHash` 等が模倣。
- **reducer**: `src/update.zig update` の `switch (msg)` 網羅化・`loadDiffCmd` パターン（payload dupe + `setDiffOwner`）を log/detail 系 arm が模倣。但し `busy` setter は runtime 専用（H1/R8）・★R2 空 guard・★R3 view_mode 検証・★R16 payload 先構築・stale reject を追加。
- **レイアウト**: `src/view.zig computeLayout`（u16 クランプ・`status_h=1`・極小端末対応）から `computeTopAndStatus` を抽出し `computeLogLayout` と共有（L3）。
- **描画**: `src/view.zig renderChanges`/`renderDiff`（`std.mem.join(a, "\n", ...)`・`fitPane` でクランプ・`zz.joinHorizontal`/`joinVertical` は最終配置のみ）を `renderLog`/`renderDetail` が模倣（M9）。
- **入力 wrapper**: 既存 `keyToMsg`/`mouseToMsg`/`fromZigzagMouse` は**変更しない**（H7）。`*ForMode` wrapper を新設し `main.handleKey`/`handleMouse` のみ切り替え。★R13 scroll 系 Msg を新設。
- **runtime**: `src/main.zig dispatchSideEffect`（worker 一系統・pending latest-wins）に log 系も乗せる（H2）。★R8 spawn fallback で runtime が busy/working を下ろす。★R9 `isMutating`/`seedInitialStatus` の網羅的 switch を更新。
- **テスト**: `src/appcmd.zig TmpRepo`（`std.testing.tmpDir`・`git init`・`writeFile`・`git` ヘルパ）を log/show 結合テストが再利用。
