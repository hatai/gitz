# zigzag / std 実 API メモ（Task 1 スパイク成果）

> 後続タスクが依存する API を、**固定リビジョンの実ソース**から確認して記録したもの。
> 推測ではなく、下記の実ファイルを grep/read した結果。差異がある箇所は「⚠️ 計画との差異」で明記。

## 固定したリビジョン

- 依存: `build.zig.zon` の `.dependencies.zigzag`
  - URL: `https://github.com/meszmate/zigzag/archive/refs/tags/v0.1.5.tar.gz`（**v0.1.5 タグ**）
  - hash: `zigzag-0.1.2-YXwYS17aEQBlpxPETTrhY5leFh7vV0DpnXJbHogs4Lsv`
  - ⚠️ **注意**: ハッシュ／内部 `build.zig.zon` の `.version` は `0.1.2` と表示される。これは
    **upstream が v0.1.5 タグで zon の version を上げ忘れているだけ**で、ピン対象は正しく v0.1.5 タグ
    のアーカイブ。後で「違うバージョンが固定された」と誤解しないこと。
- zigzag 実ソース展開先（このマシン）: `<repo>/zig-pkg/zigzag-0.1.2-YXwYS17aEQBlpxPETTrhY5leFh7vV0DpnXJbHogs4Lsv/`
  （`ZIG_GLOBAL_CACHE_DIR` がリポジトリ内 `zig-pkg/` に向いている。通常は `~/.cache/zig/p/`）
- zig std ソース: `/home/hatai/.local/share/mise/installs/zig/0.16.0/lib/std/`
- zigzag のモジュール名は **`zigzag`**（`zigzag.module("zigzag")`、build.zig L6 で確認）。
- tarball には `examples/` `tests/` は含まれない（zon の `.paths` が `src/` 等のみ）。API 確認は `src/` と README で実施。

## ビルド結果

- `zig build` → **成功（exit 0）**、`zig-out/bin/git-tui` を生成。
- `zig build test` → **成功（exit 0）**。Task 1 は `src/root_test.zig` の集約 import を
  すべてコメントアウト（main.zig のみ存在）しているので 0 テストでグリーン。
- `timeout 3 zig build run </dev/null` → exit 124（タイムアウト）。**想定どおり**:
  対話的 TUI を非 tty で動かすとブロックするため。これは判定ゲートに使わない（API が型として
  通ってコンパイルできることが検証の核）。

---

## std（Zig 0.16）

### エントリポイント — `std.process.Init`（`std/process.zig` L30-）
`main` は引数で `std.process.Init` を受け取れる（zigzag の Program はこれ前提）。

```zig
pub fn main(init: std.process.Init) !void { ... }
```
`Init` のフィールド（抜粋）:
- `gpa: std.mem.Allocator` — 汎用アロケータ（Debug でリーク検出）。
- `io: std.Io` — ターゲットに応じた既定 Io 実装。**これをそのまま zigzag / git 実行系に渡せる**。
- `environ_map: *Environ.Map` — 環境変数。zigzag の `Program.init` が要求（`*const Environ.Map`）。
- `arena: *std.heap.ArenaAllocator`, `minimal`, `preopens` も有り。

> ⚠️ **計画との差異（重要）**: 計画は「`main` で `std.Io.Threaded` を構築して `.io()` を得る」と
> 想定していた。実際は **`main(init: std.process.Init)` を使えば `init.io` がそのまま使え、手動で
> `Io.Threaded` を組む必要はない**（`Io.Threaded.init(gpa, InitOptions{...})` は environ 等の構築が
> 必要で煩雑）。`std.testing.io` はテスト用に別途存在（下記）。**main.zig / Task 11 は
> `std.process.Init` 方式を採用すること。**

### `std.Io` の入手
- **テスト**: `std.testing.io`（`std/testing.zig` L34-35）。
  ```zig
  pub var io_instance: Io.Threaded = undefined;
  pub const io = if (builtin.is_test) io_instance.io() else @compileError("not testing");
  ```
  → テストコードでは `std.testing.io` をそのまま渡せる（無料）。`std.testing.io` は **テストビルド時のみ**有効。
- **本番(main)**: `init.io`（上記）。`std.Io.Threaded` を手で組む必要はない。

### `std.process.run`（`std/process.zig` L496）
```zig
pub fn run(gpa: Allocator, io: Io, options: RunOptions) RunError!RunResult
```
- `std.process.Child.run` は**無い**（計画の前提どおり）。`std.process.run(gpa, io, options)` を使う。
- `RunOptions`（L458）:
  - `argv: []const []const u8`
  - `stdout_limit: Io.Limit = .unlimited`、`stderr_limit: Io.Limit = .unlimited`
    （`max_output_bytes` は無い — 計画どおり）
  - `cwd: Child.Cwd = .inherit`
  - `environ_map: ?*const Environ.Map = null`、`timeout: Io.Timeout = .none`、`reserve_amount` 等。
- `RunResult`（L488）: `{ term: Child.Term, stdout: []u8, stderr: []u8 }`。成功時 stdout/stderr の所有権は呼び出し側。
- `RunError`（L454）: `error{ StreamTooLong } || SpawnError || Io.File.MultiReader.UnendingError || Io.Timeout.Error`。

> ⚠️ **計画との差異（process.zig が要修正）**: `stdout_limit`/`stderr_limit` は **`std.Io.Limit` 型
> （`enum(usize)`、非網羅）であって整数リテラルではない**。計画 Task 2 の
> `.stdout_limit = 16 * 1024 * 1024` は **コンパイルできない**。正しくは:
> ```zig
> .stdout_limit = .limited(16 * 1024 * 1024),
> .stderr_limit = .limited(16 * 1024 * 1024),
> ```
> （`Io.Limit.limited(n)` / `.unlimited` / `.nothing`。`std/Io.zig` L626-）。
> もしくは `.unlimited` で割り切る。**Task 2 の process.zig はここを直すこと。**

### `Child.Cwd`（`std/process/Child.zig` L101）
```zig
pub const Cwd = union(enum) {
    inherit,
    dir: Io.Dir,        // POSIX: fork 後に fchdir
    path: []const u8,   // POSIX: chdir
};
```
→ アプリは `.{ .path = repo_root }`、テスト一時リポジトリは `.{ .dir = tmp.dir }`。`?[]const u8` ではない（計画どおり）。

### `Child.Term`（`std/process/Child.zig` L94）
```zig
pub const Term = union(enum) {
    exited: u8,                 // ← タグは小文字 .exited、ペイロードは既に u8（@intCast 不要）
    signal: std.posix.SIG,
    stopped: std.posix.SIG,
    unknown: u32,
};
```
計画 Task 2 の `switch (result.term) { .exited => |c| c, else => 255 }` は**そのまま正しい**。

### `std.testing.tmpDir` / `Dir.writeFile`
- `std.testing.tmpDir(opts: Io.Dir.OpenOptions) TmpDir`（`std/testing.zig` L634）。
  - `TmpDir = struct { dir: Io.Dir, parent_dir: Io.Dir, sub_path: [..]u8 }`（L618）。
  - `pub fn cleanup(self: *TmpDir) void`（内部で `io` を使う＝`std.testing.io`）。
  - 使い方: `var td = std.testing.tmpDir(.{}); defer td.cleanup();` → cwd は `.{ .dir = td.dir }`。
- `Dir.writeFile(dir: Dir, io: Io, options: WriteFileOptions) WriteFileError!void`（`std/Io/Dir.zig` L658）。
  - `WriteFileOptions = struct { sub_path: []const u8, data: []const u8, flags: CreateFileOptions = .{} }`。
  - → `try td.dir.writeFile(io, .{ .sub_path = name, .data = content });`（io 必須。計画どおり）。

### `std.ArrayList`（`std/std.zig` L49-59, `std/array_list.zig`）
- **`std.ArrayList(T)` は 0.16 では unmanaged が既定**。`std.ArrayListUnmanaged` は deprecated エイリアス。
  - `var list: std.ArrayList(T) = .empty;`（L591）
  - `try list.append(gpa, x);`（L903）／`try list.appendSlice(gpa, items);`（L983）
  - `const p = try list.addOne(gpa);`（L1262）
  - `list.deinit(gpa);`（L623）／`try list.toOwnedSlice(gpa);`（L654）
  → 計画（model.zig / status.zig / commands.zig）の unmanaged 使用は**正しい**。
- 旧 managed は **`std.ArrayList.Managed(T)`**（`.init(allocator)` / `append(x)` / `deinit()`）として残存。
  zigzag の `TextArea` は内部でこの Managed を使っている（下記）。アプリ側は unmanaged を使う。

---

## zigzag（v0.1.5 / 実体 0.1.2）

トップレベル re-export は `src/root.zig`。主要シンボルは `zz.<Name>` で参照可能。

### Program 起動（`src/core/program.zig`）— Elm 構成
```zig
pub fn Program(comptime Model: type) type { ... }
```
`Model` は次の宣言が**必須**（無いと `@compileError`）:
- `pub const Msg = union(enum) { ... }`
- `pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg)`
- `pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg)`
- `pub fn view(self: *const Model, ctx: *const zz.Context) []const u8`  ← **`!` ではなく非エラーの `[]const u8`**
- 任意: `pub fn deinit(self: *Model) void`（あれば `Program.deinit` が呼ぶ）

起動 API:
```zig
var program = try zz.Program(Model).init(gpa, io, environ_map);           // L92
// もしくは
var program = try zz.Program(Model).initWithOptions(gpa, io, environ_map, options); // L101
defer program.deinit();   // L137: terminal/logger/arena を解放し、Model.deinit があれば呼ぶ
try program.run();         // L159: start() + while(running) tick()
```
- `init` 引数の `environ_map` は **`*const std.process.Environ.Map`**。`init.environ_map`（`*Environ.Map`）は
  そのまま渡せる（const に縮退）。
- `Program.init` は `Model` を `undefined` で持ち、`start()` 内で `self.model.init(&ctx)` を呼ぶ
  （L228）。つまり **Model のフィールド初期化はユーザの `init` コールバックで行う**（`self.* = .{...}`）。

#### 外部からの Msg / イベント注入（★ Task 11 で重要）
- **`pub fn send(self: *Self, m: UserMsg) !void`**（L839）— 外から Model にメッセージを送れる。
- **`pub fn start(self) !void` + `pub fn tick(self) !void` + `pub fn isRunning(self) bool`**（L180/240/235）
  — `run()` の代わりに自前イベントループを回せる。`start(); while(isRunning()){ tick(); /* 他の仕事 */ }`。
- `Cmd(Msg)` 経由の注入: `.msg = Msg`（即 update に再投入）、`.perform = *const fn() ?Msg`
  （**引数なし関数ポインタのみ**。クロージャ/ワーカースレッド結果を直接は運べない）。
- メッセージフィルタ: `pub fn setFilter(self, ?*const fn(UserMsg) ?UserMsg)`（L153）。

> ⚠️ **Task 11 への申し送り（設計判断が要る点）**: zigzag に汎用の「非同期結果を Msg として注入する
> チャネル」は**組み込みでは無い**（`AsyncRunner` は `src/core/async_task.zig` に存在するが別物。要確認）。
> git をワーカースレッドで実行して結果を Model に返す計画は、**`start()`+`tick()` の自前ループにして、
> ワーカーが書いた共有キューを毎 tick ポーリングし `program.send(msg)` で注入**するのが素直。
> `.perform`（引数なし fn ポインタ）はスレッド結果の運搬には使いにくい。
> なお `tick()` は入力読み取りで最大 16ms ブロックし得る（`readInput(buf, 16)`、L282）。

#### ランタイム Cmd（`processCommand`, L447-）
`.none` `.quit` `.tick:u64` `.every:u64` `.batch` `.sequence` `.msg` `.perform`
`.enable_mouse` `.disable_mouse` `.show_cursor` `.hide_cursor` `.enter_alt_screen` `.exit_alt_screen`
`.set_title` `.println` ＋画像系。
- **Ctrl+C は Program が握って quit**（L347、Model に渡らない）。**Ctrl+Z は suspend**（`suspend_enabled` 既定 true）。
  → `request_commit` に Ctrl+S を割り当てるのは衝突しない（Ctrl+C/Ctrl+Z を避ければよい）。

### `Cmd(Msg)`（`src/core/command.zig`）
`zz.Cmd(Msg)` は `union(enum)`。上記 `processCommand` のタグ集合と同じ。ヘルパ: `tickMs/tickSec/everyMs/everySec` 等。

### `Context`（`src/core/context.zig`）
init/update/view に渡る。主要フィールド:
- `allocator: std.mem.Allocator` — **フレーム毎にリセットされる arena**（view の一時文字列向き）。
- `persistent_allocator: std.mem.Allocator` — **フレームを跨いで保持するモデル状態向き**。
- `io: std.Io`、`environ_map: *const Environ.Map`。
- `width: u16` / `height: u16`（端末サイズ。`window_size` Msg フィールドがあれば resize 時に届く、L271）。
- `unicode_width_strategy`, `terminal_mode_2027`, `kitty_text_sizing`, `theme`, `color_profile` 等。
- メソッド: `setClipboard`/`getClipboard`（OSC52）、画像描画ヘルパ、`center()`/`inBounds()` 等。

> ⚠️ **重要な所有権の罠**: zigzag の `TextArea` 等の**ステートフルなコンポーネントは
> `ctx.persistent_allocator` で生成**すること。`ctx.allocator`（フレーム arena）で作ると
> 次フレームのリセットで内部バッファが解放され use-after-free になる。view が返す一時文字列だけ
> `ctx.allocator` を使う。

### `Options`（`src/core/context.zig` 末尾）
runtime 可変オプション。`fps:u32=60`, **`mouse:bool=false`**, `cursor:bool=false`, `alt_screen:bool=true`,
`bracketed_paste:bool=true`, `title:?[]const u8`, **`input:?std.Io.File=null`**, **`output:?std.Io.File=null`**,
`log_file:?[]const u8`, `kitty_keyboard:bool=false`, `osc52`, **`unicode_width_strategy:?WidthStrategy=null`**,
`suspend_enabled:bool=true`。
- **ヘッドレス/カスタム I/O テスト手段 = `Options.input` / `Options.output`（`?std.Io.File`）**。
  標準入出力の代わりに任意の File を差せる。`Program.start()` がこれを Terminal に渡す（L194-195）。
  → Task 11 の E2E をヘッドレスで回す場合の足がかり（要 File 構築）。
- マウスは `Options.mouse = true` で有効化、または runtime `.enable_mouse` Cmd（main.zig で両方検証済み）。

### 入力イベント型
#### キー（`src/input/keys.zig`）
```zig
pub const Modifiers = packed struct { shift, alt, ctrl, super: bool = false, ... };
pub const Key = union(enum) {
    char: u21,
    f1..f12, up, down, left, right, home, end, page_up, page_down,
    insert, delete, backspace, enter, tab, escape, space,
    paste: []const u8, null_key, unknown: []const u8,
    pub fn eql, toChar, name ...
};
pub const KeyEvent = struct { key: Key, modifiers: Modifiers = .{}, event_type: KeyEventType = .press };
pub const KeyEventType = enum { press, repeat, release };
```
- `zz.Key` / `zz.KeyEvent` / `zz.Modifiers` で参照。
- **Ctrl+S** = `KeyEvent{ .key = .{ .char = 's' }, .modifiers = .{ .ctrl = true } }`。
- Program が `Model.Msg` に `key` フィールドがあれば `Msg{ .key = KeyEvent }` を届ける（L379）。
  → 計画 input.zig の「zigzag イベント → Msg 正規化」は、Model.Msg を `key: zz.KeyEvent` にして
    update（または専用 normalize 関数）でマッピングする形になる。

#### マウス（`src/input/mouse.zig`）
```zig
pub const Button = enum { left, middle, right, wheel_up, wheel_down, wheel_left, wheel_right, button_8..11, none };
pub const EventType = enum { press, release, drag, move };
pub const MouseEvent = struct { x: u16, y: u16, button: Button, event_type: EventType, modifiers: Modifiers = .{} };
pub fn parseSgr(data) ?struct{ event: MouseEvent, consumed: usize };   // SGR \x1b[<...M/m
pub fn enableSequence/disableSequence(TrackingMode) []const u8;        // ?1000/1002/1003 + 1006(SGR)
```
- `zz.MouseEvent` / `zz.MouseButton`(=Button) / `zz.MouseEventType`(=EventType) で参照。
- SGR マウス（1006）対応済み。ホイールは `Button.wheel_up`/`wheel_down`（diff スクロールに使える）。
- Program が `Model.Msg` に `mouse` フィールドがあれば `Msg{ .mouse = MouseEvent }` を届ける（L406）。
- `zz.HitBox` / `zz.MouseState` / `zz.MouseInteraction`（`src/input/hitbox.zig`）でクリック領域判定が可能。

### `TextArea`（`src/components/text_area.zig`）
```zig
pub const TextArea = struct {
    pub fn init(allocator: std.mem.Allocator) TextArea;   // 非失敗（内部 catch{}）。persistent_allocator を渡すこと
    pub fn deinit(self: *TextArea) void;
    pub fn setValue(self: *TextArea, text: []const u8) !void;        // 全置換
    pub fn getValue(self: *const TextArea, allocator) ![]const u8;   // 現在テキスト取得（呼び出し側 free）
    pub fn charCount(self) usize;
    pub fn lineCount(self) usize;
    pub fn setSize(self: *TextArea, width: u16, height: u16) void;
    pub fn focus(self) void;  pub fn blur(self) void;
    pub fn handleKey(self: *TextArea, key: keys.KeyEvent) void;       // 編集処理
    pub fn cursorDisplayColumn(self) usize;
    pub fn view(self: *const TextArea, allocator) ![]const u8;        // 描画文字列（呼び出し側=フレーム arena 想定）
    // フィールド: placeholder, line_numbers, word_wrap, *_style, max_lines, max_cols, char_limit
};
```
- 生成は `zz.TextArea.init(ctx.persistent_allocator)`、毎フレーム描画は `self.ta.view(ctx.allocator)`。
- 多バイト/全角入力 OK（`insertChar` は `utf8Encode`、`insertText` は UTF-8 デコードして1コードポイントずつ）。
- カーソル: `cursor_row`/`cursor_col`（バイト基準）、`cursorDisplayColumn()` で表示桁。

> ⚠️ **計画との差異（commit 提出フローが要設計）**: **`TextArea` に「Ctrl+S サブミット」コールバックや
> submit シグナルは無い**。`handleKey` は Ctrl 修飾時 `a/e/k/u/d` のみ処理し、それ以外の Ctrl は無視
> （`else => {}`、L193-205）。したがって:
> - **アプリ側 update が Ctrl+S を先に横取りして `request_commit` に変換し、TextArea には渡さない**。
> - コミットメッセージ本文は `textarea.getValue(alloc)` で都度取得する（計画の
>   `commit_text_changed` 同期方式でも、`getValue` 直接取得方式でもよい。TextArea が正本）。
> - その他の通常キー（文字/Enter/矢印/Backspace 等）はフォーカスが commit ペインのとき
>   `textarea.handleKey(k)` に委譲する。

### `TextInput`（`src/components/text_input.zig` L10-462）
単一行入力（phase3a フィルタモーダルで使用）。内部は `std.array_list.Managed(u8)`。
- フィールド: `value`/`cursor`/`placeholder`/`prompt`/`width: ?u16`/`char_limit: ?usize`/`echo_mode`/`focused`/`suggestions`。`EchoMode = enum { normal, password, none }`。
- API: `init(allocator) TextInput`（非失敗・L48）/ `deinit()`（L94）/ `setValue(text) !void`（全置換）/ **`getValue() []const u8`**（★TextArea と異なり **borrowed**・allocator 不要・内部 `value.items` への借用）/ `setPlaceholder(text)` / `setPrompt(text)` / `setWidth(w)` / `setCharLimit(n)` / `setEchoMode(mode)` / `focus()` / `blur()` / `handleKey(key) void`（L181）/ `view(allocator) ![]const u8`（L380・フレーム arena 想定・cursor 位置に reverse ハイライト）。
- `handleKey` の処理範囲（L181-237）: Ctrl+a/e/k/u/w、Alt+left/right（単語移動）、文字/paste/backspace/delete/left/right/home/end/tab（suggestion 確定）。**★`enter`/`escape` は処理しない**（`else => {}`）→ アプリ側で Enter/Esc を先に横取りして Msg 化し、それ以外を `TextInput.handleKey` へ委譲する設計（phase3a 仕様）。
- 生成は `persistent_allocator`、毎フレーム描画は `ctx.allocator`。多バイト入力 OK。**submit シグナルは無い**（TextArea と同じくアプリ側で Enter を横取り）。

### `Modal`（`src/components/modal.zig` L52-761）
中央ポップアップ（phase3a フィルタ UI で使用）。
- フィールド: `visible`/`focused`/`result: ?Result`/`title`/`body`/`footer`/`buttons[max_buttons]?Button`/`button_count`/`selected_button`/`width: Size`/`height: Size`/`h_position: f32=0.5`/`v_position: f32=0.5`/`padding`/`close_on_escape: bool=true`/`border_chars`/`border_fg`/`backdrop: ?Backdrop`。
- `Result = union(enum) { button_pressed: usize, dismissed: void }`。`Button = struct { label, shortcut: ?keys.Key }`。`Size = union(enum) { fixed: u16, percent: f32, auto: void }`。`Backdrop = struct { char: []const u8 = " ", style, ... }`。
- Presets: `info(title, body)` / `confirm(...)` / `warning(...)` / `err(...)`（L190-227）。phase3a は **`init()`**（L239・blank）を使用。
- API: `init()` / `addButton(label, shortcut)`（L246）/ `show()`（L265）/ `hide()`（L273）/ `isVisible()`（L278）/ `getResult()` / `reset()` / `focus()` / `blur()` / `handleKey(key) void`（L308）/ `view(allocator, term_w, term_h) ![]const u8`（L370・中央 box のみ・透明 canvas）/ **`viewWithBackdrop(allocator, term_w, term_h) ![]const u8`**（L379・★全面 canvas・**solid backdrop・透過しない**）/ `renderBox(...)`（L435）。
- `handleKey`（L308-364）: button shortcut 一致→`result.button_pressed`+`visible=false` / escape→`result.dismissed`+`visible=false`（`close_on_escape` 時）/ enter→`result.button_pressed=selected_button`+`visible=false` / tab,left,right→button 選択移動。**★`button_count==0` なら enter は no-op**（L332）。
- **★overlay 描画の罠**: `view`/`viewWithBackdrop` は全面 canvas を返す。既存 render 文字列との単純 join（`zz.joinVertical` 等）は **overlay にならない**（backdrop が base を隠す）。modal 表示中は base view を返さず `viewWithBackdrop` を返す設計（phase3a 仕様）。
- **button と TextInput の混在**: Modal は button を前提とした `handleKey`（Enter→button_pressed）。body に TextInput を置き Enter/Esc をアプリで制御したい場合は、**`Modal.handleKey` に渡す前にアプリ側で横取り**（button を追加しない・phase3a では Modal へキーを渡さず TextInput のみへ委譲）。

### レイアウト / 描画 API（`src/root.zig` のユーティリティ + `src/layout/*`）
zigzag の view は「**スタイル付き文字列を組み立てて返す**」モデル（セルバッファ直書きではない）。
- 文字列結合: `zz.joinHorizontal(alloc, parts)` / `zz.joinVertical(alloc, parts)`（`src/layout/join.zig`）。
- 配置: `zz.placeHorizontal(alloc, w, hpos, content)` / `placeVertical` / `placeFloat`。
- 計測: **`zz.width(str) usize`** / **`zz.height(str) usize`**（`src/layout/measure.zig` L9/L90。
  全角を考慮した表示幅）。→ view.zig のレイアウト計算（パネル幅・diff 折返し）に使える。
- スタイル: `zz.Style`（`src/style/style.zig`、`.render(alloc, text)` で ANSI 付き文字列化）、
  `zz.Color`、`zz.Border`（`BorderChars`）、`zz.Theme`/`zz.Palette`。
- Flex レイアウト: `zz.Flex` / `zz.FlexConstraint` / `zz.FlexItem` / `zz.FlexRect`（`src/layout/flex.zig`）。
- 既製コンポーネント多数（`List`, `Viewport`, `SplitPane`, `DiffView`, `StatusBar`, `Modal` 等）。
  MVP の3ペイン構成は `SplitPane` か手組み join で実装可能（Task 10 で選択）。
- `zz.Viewport`（`src/components/viewport.zig`）は diff のスクロール表示に使える候補。

### Unicode 幅戦略（`src/core/program.zig` L387-403, `src/unicode.zig`）
- 環境変数 **`ZZ_UNICODE_WIDTH`** を尊重: `unicode` / `legacy`(=legacy_wcwidth) / `auto`。
- 端末の **DEC mode 2027** ネゴシエーション結果を `ctx.terminal_mode_2027` に反映。
- `Options.unicode_width_strategy` で強制可能（null=自動）。
- `unicode.setWidthStrategy()` が起動時に決定。`zz.width()` はこの戦略で全角幅を返す。
- → 全角ずれ対策は zigzag 任せでよいが、テスト/CI で揺れる場合は `ZZ_UNICODE_WIDTH=unicode` を明示。

### 非同期 / その他
- `zz.AsyncRunner`（`src/core/async_task.zig`）= 非同期タスク機構。git ワーカーに使えるか Task 11 で要評価
  （ただし上記のとおり `start()`+`tick()`+`send()` 方式が確実）。
- `zz.SubProgram`（`src/core/sub_program.zig`）、`zz.ScreenStack`、`zz.testing.expectSnapshot`
  （`src/testing/snapshot.zig`）= スナップショットテスト手段あり（view 出力の golden テストに使える）。

---

## 後続タスクへの申し送り（要修正・要判断の総括）

1. **Task 2 `process.zig`**: `stdout_limit`/`stderr_limit` は `Io.Limit`。
   `.stdout_limit = .limited(16*1024*1024)`（または `.unlimited`）に直す。整数リテラルは不可。
   それ以外（`Cwd`, `Term.exited:u8`, `RunResult`）は計画どおりで OK。
2. **Task 11 `main.zig`**: `pub fn main(init: std.process.Init) !void` で `init.gpa/io/environ_map` を
   `Program.init(initWithOptions)` に渡す。`std.Io.Threaded` の手組みは不要。mouse は `Options.mouse=true`。
3. **Task 11 ワーカー連携**: 非同期結果の注入は `start()`+`tick()` 自前ループ＋共有キュー＋`program.send(msg)`
   が素直。`.perform` は引数なし fn ポインタで不向き。`tick()` は入力待ちで最大 ~16ms ブロックし得る。
4. **コミット提出**: TextArea に submit コールバックは無い。アプリ update が Ctrl+S を横取りして
   `request_commit` 化し、TextArea には渡さない。本文は `textarea.getValue()`（TextArea が正本）。
5. **所有権**: ステートフルなコンポーネント（TextArea 等）は `ctx.persistent_allocator` で生成。
   view の一時文字列のみ `ctx.allocator`（フレーム arena）。
6. **view の戻り値**: `[]const u8`（`!` 無し）。内部の `!` 呼び出しは `catch` でフォールバック文字列にする。
7. **Model.Msg**: 入力を受けるには `Model.Msg` に `key: zz.KeyEvent`（必要なら `mouse: zz.MouseEvent`）の
   フィールド名が必須（Program は `@hasField` で判定して届ける）。`window_size`/`tick`/`paste`/`resumed` も同様。
8. **`std.ArrayList(T)` は 0.16 で unmanaged が既定**（計画どおり）。managed は `std.ArrayList.Managed(T)`。
9. **build.zig**: 計画のインライン形（`addExecutable(.{ .root_source_file=..., .target=... })`）ではなく、
   zigzag 実体に合わせて **`root_module = b.createModule(.{...})`** 形を採用した（こちらが 0.16 で確実にビルド）。
