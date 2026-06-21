//! Task 11: ランタイム配線。コア層（model/messages/update/appcmd/git）と UI 層
//! （input/view）を zigzag ランタイムへ接続する統合点。
//!
//! 設計（docs/.../zigzag-api-notes.md + advisor レビュー反映）:
//! - zigzag の `Program(RuntimeModel)` を駆動する。`RuntimeModel.Msg` は zigzag が届ける
//!   `key`/`mouse` と、ワーカースレッドからの結果 `app_result: messages.Msg` を持つ。
//! - **副作用 git はワーカースレッド**で `appcmd.run` を実行し、結果 `Msg` を **mutex 付き
//!   キュー**へ push。メインループ（`start()`+`tick()`）が毎フレーム drain して
//!   `program.send(.{ .app_result = msg })` で再投入する。`send` は同期的に
//!   `update`/`render` を呼ぶため**メインスレッドからのみ**呼ぶ（ワーカーからは呼ばない）。
//! - 共有状態は file-scope `var g_app` で橋渡しする。zigzag は `Model.init(ctx)` を
//!   `ctx` だけで呼び `self.*` を上書きするため、main() が解決した起動状態
//!   （repo_root/has_head/branch/io/gpa/mouse 等）をここに置く。
//! - **`init()` からは中断できない**（`start()` が戻り値 `.quit` を握りつぶし `running=true`
//!   にする）。よって repoRoot 解決と初回 status は **`start()` 前に main() で同期実行**する。

const std = @import("std");
const zz = @import("zigzag");

const model_mod = @import("model.zig");
const Model = model_mod.Model;
const messages = @import("messages.zig");
const Msg = messages.Msg;
const AppCmd = messages.AppCmd;
const update = @import("update.zig");
const appcmd = @import("appcmd.zig");
const input = @import("input.zig");
const viewmod = @import("view.zig");
const cmds = @import("git/commands.zig");
const process = @import("git/process.zig");
const autorefresh = @import("autorefresh.zig");

const Cwd = process.Cwd;

/// 自動 status リフレッシュの最短間隔（ms）。worker 非稼働かつ pending 無しのときのみ発火。
const auto_refresh_interval_ms: i64 = 1500;

/// ワーカー → メイン の結果キュー（mutex 保護）。ワーカーは push、メインは drain。
/// Zig 0.16 では同期プリミティブが `std.Io.Mutex` に移り lock/unlock が `io` を要する
/// （`init.io` は threadsafe）。OS スレッドは `std.Thread.spawn`/`join` のまま。
const ResultQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Msg) = .empty,
    /// ワーカー完了フラグ。キュー drain とは独立にワーカーの終端到達を通知する。
    /// workerThread が結果 push 後に markWorkerDone で true にし、reapWorker が takeWorkerDone
    /// で取得即 false に戻す（join 後）。キュー長で完了検出すると drain との競合で取りこぼし、
    /// worker が恒久 non-null になり全副作用が固まる事故が起きる（review Issue 2）ため独立化。
    worker_done: bool = false,

    fn push(self: *ResultQueue, io: std.Io, a: std.mem.Allocator, msg: Msg) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // push 失敗（OOM）は致命ではない。結果 Msg を捨てて leak も二重 free も避ける。
        self.items.append(a, msg) catch {
            var m = msg;
            m.deinit(a);
        };
    }

    /// ワーカーが終端に到達したことを通知する（push と同一 mutex 区間で呼ぶ）。
    fn markWorkerDone(self: *ResultQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.worker_done = true;
    }

    /// ワーカー完了フラグを取得しつつ false へ戻す（取りこぼし防止のため取得即クリア）。
    fn takeWorkerDone(self: *ResultQueue, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const done = self.worker_done;
        self.worker_done = false;
        return done;
    }

    /// drain した Msg を out に移し替える（呼び出し側が所有・各 deinit する）。
    fn drain(self: *ResultQueue, io: std.Io, a: std.mem.Allocator, out: *std.ArrayList(Msg)) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.items.items.len == 0) return;
        out.appendSlice(a, self.items.items) catch {
            // out への移送が OOM のときは元キューに残し、次フレームで再試行（leak 回避）。
            return;
        };
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *ResultQueue, a: std.mem.Allocator) void {
        for (self.items.items) |*m| m.deinit(a);
        self.items.deinit(a);
    }
};

/// 起動時に main() が確定し、以後 zigzag コールバックが参照する共有アプリ状態。
const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: Cwd, // 常に .{ .path = model.repo_root }（サブディレクトリ起動でも root 相対で一貫）
    model: Model,
    textarea: zz.TextArea,
    filter_textinput: zz.TextInput, // phase 3a: 作者フィルタモーダルの単行入力（persistent_allocator 所有）
    filter_modal: zz.Modal, // phase 3a: フィルタ編集モーダル（button 無し・Enter/Esc はアプリで横取り）
    queue: ResultQueue = .{},

    // ワーカー直列実行（1 度に 1 コマンド）。busy 中の新規副作用は pending に latest-wins で退避。
    worker: ?std.Thread = null,
    pending: ?AppCmd = null,

    /// 自動リフレッシュの前回 dispatch 時刻（ms）。tick で間引くために使う。
    last_auto_refresh_ms: i64 = 0,
};

var g_app: App = undefined;
var g_app_ready: bool = false;

/// ワーカースレッドのエントリ。AppCmd を実行し結果 Msg をキューへ push して終了する。
/// `cmd` の所有権はワーカーが受け取り、ここで deinit する（メインは手放し済み）。
/// スレッド本体。workerRun を実行し、**スレッド経路でのみ** 完了を通知する。
/// markWorkerDone はここでだけ呼ぶ: 同期フォールバック（spawn 失敗時）は worker==null の
/// まま workerRun を直接呼ぶため、そこで done を立てると次回の正規ワーカーを stale done で
/// 即 join してしまい async 性が壊れる（review Issue 2 のリグレッション）。
fn workerThread(app: *App, cmd: AppCmd) void {
    workerRun(app, cmd);
    app.queue.markWorkerDone(app.io);
}

fn workerRun(app: *App, cmd_in: AppCmd) void {
    var cmd = cmd_in;
    defer cmd.deinit(app.gpa);
    const result: Msg = appcmd.run(app.gpa, app.io, app.cwd, cmd) catch |err| {
        // appcmd.run 自体が失敗（OOM/spawn 不能等）。エラー文を git_error として返す。
        const text = std.fmt.allocPrint(app.gpa, "git 実行エラー: {s}", .{@errorName(err)}) catch {
            // 文言確保すら失敗。固定文言（複製）で代替。これも失敗なら結果 push を諦める。
            // 完了通知は呼び出し元 workerThread の markWorkerDone が担うのでハングしない。
            const fallback = app.gpa.dupe(u8, "git 実行エラー") catch return;
            app.queue.push(app.io, app.gpa, .{ .git_error = fallback });
            return;
        };
        app.queue.push(app.io, app.gpa, .{ .git_error = text });
        return;
    };
    app.queue.push(app.io, app.gpa, result);
}

/// 変更系（mutating）副作用か。スピナ表示（model.working）を出すのはこれらの**ユーザ起動**操作の
/// 実行中だけにする。読み取り系（refresh_status/load_diff）は出さない＝自動リフレッシュやナビゲーション
/// でステータスバーが点滅しない。`model.busy`（reducer の二重実行ゲート）は全 in-flight で立てる別物。
fn isMutating(cmd: AppCmd) bool {
    return switch (cmd) {
        .stage, .unstage, .commit, .apply_patch => true,
        .none, .quit, .refresh_status, .load_diff, .load_log, .load_log_page, .load_commit_detail, .load_detail_diff => false,
    };
}

/// 副作用 AppCmd をワーカーへ委譲する。busy 中なら pending に退避（latest-wins）。
/// `cmd` の所有権を受け取る（委譲できなければここで deinit する）。
fn dispatchSideEffect(app: *App, cmd: AppCmd) void {
    if (app.worker != null) {
        // 既存ワーカー稼働中。前の pending は捨てて最新で上書き（rapid j/k の load_diff を間引く）。
        if (app.pending) |*p| p.deinit(app.gpa);
        app.pending = cmd;
        return;
    }
    app.model.busy = true; // reducer の二重実行ゲート。全 in-flight で立てる（表示はしない）。
    app.model.working = isMutating(cmd); // スピナ表示用。変更系のときだけ true（読み取りでは点滅させない）。
    app.worker = std.Thread.spawn(.{}, workerThread, .{ app, cmd }) catch {
        // spawn 失敗時はメインスレッドで同期実行（degraded だがクラッシュしない）。
        // worker は null のままなので reapWorker は join せず、worker_done も触らない（＝
        // 次回の正規ワーカーが stale done で誤 join される事故を避ける）。busy は結果 Msg を
        // reducer が処理する際に下りる（status_loaded/diff_loaded/committed/git_error 全てが
        // busy=false にする）ので、ここでは触らない。
        app.worker = null;
        app.model.working = false; // 同期実行に落ちたのでスピナは即解除（busy は reducer 結果で下りる）。
        workerRun(app, cmd);
        return;
    };
}

/// AppCmd を解釈してランタイムへ適用する。
/// - `.none`: 何もしない（所有なし）。
/// - `.quit`: プログラム停止。
/// - 副作用: ワーカーへ委譲（所有権を渡す）。
fn applyAppCmd(app: *App, program: anytype, cmd: AppCmd) void {
    switch (cmd) {
        .none => {},
        .quit => program.quit(),
        .refresh_status, .stage, .unstage, .load_diff, .commit, .apply_patch, .load_log, .load_log_page, .load_commit_detail, .load_detail_diff => dispatchSideEffect(app, cmd),
    }
}

/// reducer を 1 回回し、得た AppCmd をランタイムへ適用する。`msg` は消費後に deinit する
/// （所有権規約: Msg の消費者＝ここ）。
fn step(app: *App, program: anytype, msg_in: Msg) void {
    var msg = msg_in;
    var cmd = update.update(&app.model, msg) catch |err| {
        msg.deinit(app.gpa);
        // reducer 内 OOM 等。エラー文を Model に載せて継続。
        app.model.setStr(&app.model.error_text, @errorName(err)) catch {};
        return;
    };
    msg.deinit(app.gpa);
    applyAppCmd(app, program, cmd);
    // applyAppCmd は副作用 cmd の所有権をワーカー/pending へ渡す。
    // 渡らなかった（.none/.quit）場合のみここで deinit する。
    switch (cmd) {
        .none, .quit => cmd.deinit(app.gpa),
        else => {}, // 所有権は dispatchSideEffect 側へ移譲済み
    }
}

/// 現在の TextArea の内容を model.commit_message へ同期する（commit フォーカス時のみ）。
fn syncCommitText(app: *App) void {
    const text = app.textarea.getValue(app.gpa) catch return;
    defer app.gpa.free(text);
    app.model.setStr(&app.model.commit_message, text) catch {};
}

/// ワーカー完了を回収する。完了していれば join し、pending があれば次を起動する。
fn reapWorker(app: *App) void {
    if (app.worker) |w| {
        // join はブロックするので、ワーカーが終端に到達した（markWorkerDone 済み）ことを
        // 確認してから join する。完了検出はキュー長ではなく独立フラグで行う: キュー drain
        // とのインターリーブで完了を取りこぼし、worker が恒久的に non-null になる事故を防ぐ
        //（review Issue 2）。worker は markWorkerDone 直後に return するため join は即時返る。
        // takeWorkerDone は取得即クリアなので、結果が既に drain 済みでも完了を取りこぼさない。
        if (app.queue.takeWorkerDone(app.io)) {
            w.join();
            app.worker = null;
            app.model.busy = false;
            app.model.working = false; // スピナ解除（pending があれば下の dispatch が再設定する）。
            if (app.pending) |next| {
                app.pending = null;
                dispatchSideEffect(app, next);
            }
        }
    }
}

/// tick ごとに呼ぶ: worker 非稼働かつ pending 無しで前回から間隔経過していれば status を再読込する。
/// 外部のファイル変更を再起動なしで反映する定期ポーリング（WSL2 では inotify 不安定のため採用）。
/// 通常の dispatchSideEffect 経由なので busy=true となり、ポーリング中の Ctrl+S/stage は他の
/// in-flight 操作と同様 reducer の busy ゲートで弾かれる（pending 上書きによる無音消失を防ぐ）。
fn maybeAutoRefresh(app: *App) void {
    const now = nowMs(app);
    if (!autorefresh.shouldAutoRefresh(now, app.last_auto_refresh_ms, auto_refresh_interval_ms, app.worker != null, app.pending != null, app.model.view_mode)) return;
    app.last_auto_refresh_ms = now;
    dispatchSideEffect(app, .refresh_status);
}

pub const RuntimeModel = struct {
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        app_result: messages.Msg, // ワーカー結果（program.send 経由でメインから注入）
        tick: TickPayload, // ワーカー完了ポーリング用（every で駆動）
    };

    pub const TickPayload = struct { timestamp: i64, delta: u64 };

    pub fn init(self: *RuntimeModel, ctx: *zz.Context) zz.Cmd(RuntimeModel.Msg) {
        _ = self;
        // TextArea は frame arena ではなく persistent_allocator で生成（api-notes の所有権規約）。
        g_app.textarea = zz.TextArea.init(ctx.persistent_allocator);
        g_app.textarea.setSize(@max(ctx.width, 1), 4);
        g_app.textarea.placeholder = "コミットメッセージ";
        // phase 3a §9.1/M7: filter TextInput と Modal を persistent_allocator で生成。
        // TextInput.getValue は borrowed（内部 value.items への借用）・Enter 押下時に main が dupe。
        // Modal は button 無し（Enter/Esc をアプリ側で横取り・button_count==0 で Modal.handleKey の enter は no-op）。
        g_app.filter_textinput = zz.TextInput.init(ctx.persistent_allocator);
        g_app.filter_textinput.setCharLimit(256); // m-N2: max_author_runes と整合
        g_app.filter_textinput.setPlaceholder("Filter by author...");
        g_app.filter_textinput.setPrompt("author: ");
        g_app.filter_modal = zz.Modal.init();
        g_app.filter_modal.title = "Filter by author";
        g_app.filter_modal.border_fg = .cyan;
        g_app.filter_modal.width = .{ .percent = 0.6 };
        // ~30fps でワーカー完了をポーリングする（tick が無いと drain が回らない）。
        return zz.Cmd(RuntimeModel.Msg).everyMs(33);
    }

    pub fn update(self: *RuntimeModel, msg: RuntimeModel.Msg, program_ctx: *zz.Context) zz.Cmd(RuntimeModel.Msg) {
        _ = self;
        _ = program_ctx;
        const app = &g_app;
        const program = g_program;
        switch (msg) {
            .tick => {
                // ワーカー完了を回収し、キューを drain して reducer に流す。
                reapWorker(app);
                drainQueue(app, program);
                // 外部のファイル変更を再起動なしで反映する定期ポーリング（間引き済み・busy 非点灯）。
                maybeAutoRefresh(app);
            },
            .key => |k| handleKey(app, program, k),
            .mouse => |m| handleMouse(app, program, m),
            .app_result => |am| step(app, program, am),
        }
        return .none;
    }

    pub fn view(_: *const RuntimeModel, ctx: *const zz.Context) []const u8 {
        const app = &g_app;
        // phase 3a §9.3/M6: model.filter_modal_open と modal visibility を同期。
        // true→false 遷移で TextInput へ現 filter をロード（編集継続）・false→true で hide。
        // committed 時の textarea.setValue("")（drainQueue）と同パターン。
        syncFilterModal(app, ctx);
        return viewmod.render(&app.model, ctx);
    }

    pub fn deinit(_: *RuntimeModel) void {
        if (!g_app_ready) return;
        const app = &g_app;
        // 稼働中ワーカーを join（メインが終わる前に必ず合流。leak/競合防止）。
        if (app.worker) |w| {
            w.join();
            app.worker = null;
        }
        if (app.pending) |*p| {
            p.deinit(app.gpa);
            app.pending = null;
        }
        app.queue.deinit(app.gpa);
        app.textarea.deinit();
        app.filter_textinput.deinit(); // phase 3a: TextInput は persistent_allocator 所有
        // filter_modal はヒープ所有しない（title/body は借用 slice）・deinit 不要。
        app.model.deinit();
        g_app_ready = false;
    }
};

// Program は型に依存するため、send/quit を呼ぶための弱い参照を file-scope に持つ。
// initWithOptions の返り値型に合わせる。
const ProgramT = zz.Program(RuntimeModel);
var g_program: *ProgramT = undefined;

fn drainQueue(app: *App, program: *ProgramT) void {
    var local: std.ArrayList(Msg) = .empty;
    defer local.deinit(app.gpa);
    app.queue.drain(app.io, app.gpa, &local);
    for (local.items) |m| {
        // コミット成功時は TextArea も空にする。reducer（純粋）は model.commit_message を
        // 空にするが TextArea は触れない。syncCommitText が TextArea を正本にしているため、
        // ここでクリアしないと次のキー入力で旧メッセージが復活し二重コミットの種になる。
        if (m == .committed) app.textarea.setValue("") catch {};
        // send は同期で update→reducer を回す。app_result 経由で step() に届く。
        program.send(.{ .app_result = m }) catch {
            var mm = m;
            mm.deinit(app.gpa);
        };
    }
}

fn nowMs(app: *App) i64 {
    return std.Io.Timestamp.now(app.io, .awake).toMilliseconds();
}

/// phase 3a §9.3: model.filter_modal_open と filter_modal visibility を同期。
/// `open_filter_modal` reducer が flag を立てたら、次フレームの view で TextInput へ現 filter をロード
/// （編集継続・§19 デフォルト 6）し modal.show()。逆に flag が下りたら modal.hide()。
/// 毎フレーム modal.body へ TextInput の描画結果を設定（viewWithBackdrop が body を描画）。
fn syncFilterModal(app: *App, ctx: *const zz.Context) void {
    if (app.model.filter_modal_open and !app.filter_modal.isVisible()) {
        // false→true 遷移: 現 filter_state.author を TextInput へロード（編集継続）。
        const cur = app.model.filter_state.author orelse "";
        app.filter_textinput.setValue(cur) catch {};
        app.filter_modal.show();
    } else if (!app.model.filter_modal_open and app.filter_modal.isVisible()) {
        // true→false 遷移: modal を隠す（close_filter_modal / apply_filter / clear_filter で reducer が flag を下ろす）。
        app.filter_modal.hide();
    }
    // 毎フレーム modal.body へ TextInput の描画を反映（ctx.allocator = フレーム arena・free 不要）。
    // body は viewWithBackdrop が render する。失敗時は空 body（描画が空になるだけでクラッシュしない）。
    if (app.model.filter_modal_open) {
        app.filter_modal.body = app.filter_textinput.view(ctx.allocator) catch "";
        viewmod.g_view_modal = &app.filter_modal;
    } else {
        viewmod.g_view_modal = null;
    }
}

var g_click_state: input.ClickState = .{};

fn handleKey(app: *App, program: *ProgramT, k: zz.KeyEvent) void {
    // phase 3a §9.2/M6/M-N7: filter_modal_open 時は入力を TextInput へ委譲
    // （Enter/Esc はアプリ側で横取りし payload 付き Msg を構築・input は null で返す）。
    if (app.model.filter_modal_open) {
        handleModalKey(app, program, k);
        return;
    }
    // commit フォーカス時: 編集キー（文字/Enter/Backspace/矢印）は TextArea が正本。
    // keyToMsgForMode はそれらに null を返すので、null かつ changes モード + commit フォーカスなら
    // TextArea へ委譲する（log モードに commit フォーカスは無い・M5 正規化で .changes へ戻る）。
    const abstract = input.fromZigzagKey(k);
    if (abstract) |key| {
        if (input.keyToMsgForMode(app.model.view_mode, app.model.focus, app.model.detail_kind, key)) |m| {
            step(app, program, m);
            return;
        }
    }
    // グローバル命令にならなかったキー。changes モード + commit フォーカスなら TextArea で編集する。
    // log モードでは commit フォーカスに遷移しない（M5・keyToMsgForLog が 'c' に null を返す）。
    if (app.model.view_mode == .changes and app.model.focus == .commit) {
        app.textarea.handleKey(k);
        syncCommitText(app);
    }
}

/// phase 3a §7.1/§9.2/M6/M-N7: modal open 時のキー routing。
/// Escape → `.close_filter_modal`・Enter → main が `TextInput.getValue()` を dupe して
/// `Msg.apply_filter` payload を構築（input 関数は tag のみ返せないため Zig の tagged union 制約）。
/// それ以外（文字/BS/矢印/Ctrl+a/e/k/u/w 等）は TextInput.handleKey へ委譲。
/// q/r/L/tab 等 global mapping は input.keyToMsgForModeWithModal が null を返すのでここで TextInput へ回る。
fn handleModalKey(app: *App, program: *ProgramT, k: zz.KeyEvent) void {
    const abstract = input.fromZigzagKey(k);
    if (abstract) |key| {
        switch (key) {
            .escape => {
                step(app, program, .close_filter_modal);
                return;
            },
            .enter => {
                // M-N7: payload は main が TextInput.getValue() を dupe して構築。
                // consumer（reducer → main step）が free する（Msg.deinit で a.free(text)）。
                const v = app.filter_textinput.getValue();
                const dup = app.gpa.dupe(u8, v) catch {
                    // OOM: モーダルを維持して log_load_error で通知。
                    app.model.setLogLoadError("フィルタ適用に失敗（メモリ不足）") catch {};
                    return;
                };
                step(app, program, .{ .apply_filter = dup });
                return;
            },
            else => {},
        }
    }
    // その他のキーは TextInput.handleKey へ委譲（Ctrl+a/e/k/u/w, 文字/BS/Del/矢印 等）。
    app.filter_textinput.handleKey(k);
}

fn handleMouse(app: *App, program: *ProgramT, m: zz.MouseEvent) void {
    if (!app.model.mouse_enabled) return;
    // phase 3a §7.2/M6: modal open 時は背面 pane への routing をスキップ（モーダル外クリックは無視）。
    if (app.model.filter_modal_open) return;
    const w = g_program.context.width;
    const h = g_program.context.height;
    // changes/log 両モードの scratch をスタックに確保（使わない側は参照しない）。
    var changes_scratch: [256]viewmod.ChangesRow = undefined;
    var log_scratch: [256]viewmod.LogRow = undefined;
    var detail_scratch: [256]viewmod.DetailRow = undefined;

    // ViewMode 別にレイアウトを組み立て、対応する adapter へ委譲する（H7: 既存 fromZigzagMouse は変更しない）。
    const ev = switch (app.model.view_mode) {
        .changes => blk: {
            const layout = viewmod.computeLayout(w, h, 5);
            // changesRowLayout 用の scratch（見出し3 + ファイル数）。256 を超える場合は全体を使う。
            const need = app.model.files.items.len + 3;
            const scratch: []viewmod.ChangesRow = if (need <= changes_scratch.len)
                changes_scratch[0..need]
            else
                changes_scratch[0..];
            // log_mode 用の dummy layout/scratch（参照されないが型のために渡す）。
            break :blk input.fromZigzagMouseForMode(
                .changes,
                m,
                &app.model,
                layout,
                .{ .log = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .detail = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .status = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
                &g_click_state,
                nowMs(app),
                scratch,
                log_scratch[0..],
                detail_scratch[0..],
            );
        },
        .log => blk: {
            const layout = viewmod.computeLogLayout(w, h);
            // changes 用の dummy layout/scratch（参照されないが型のために渡す）。
            break :blk input.fromZigzagMouseForMode(
                .log,
                m,
                &app.model,
                .{ .changes = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .diff = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .commit = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .status = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
                layout,
                &g_click_state,
                nowMs(app),
                changes_scratch[0..],
                log_scratch[0..],
                detail_scratch[0..],
            );
        },
    };
    if (input.mouseToMsgForMode(app.model.view_mode, ev, app.model.detail_kind)) |msg| step(app, program, msg);
}

/// 初回 status を **start() 前に同期実行**して Model を埋める（first-frame の空表示を避ける）。
/// refresh_status → status_loaded を reducer に流し、続く load_diff も 1 回だけ追従する。
fn seedInitialStatus(app: *App) void {
    var first = appcmd.run(app.gpa, app.io, app.cwd, .refresh_status) catch return;
    // first を reducer に流す（消費後 deinit）。返り値 AppCmd（多くは load_diff）を 1 回だけ実行。
    var cmd1 = update.update(&app.model, first) catch {
        first.deinit(app.gpa);
        return;
    };
    first.deinit(app.gpa);
    defer cmd1.deinit(app.gpa);
    switch (cmd1) {
        .load_diff, .stage, .unstage, .commit, .refresh_status, .load_log, .load_log_page, .load_commit_detail, .load_detail_diff => {
            var second = appcmd.run(app.gpa, app.io, app.cwd, cmd1) catch return;
            var cmd2 = update.update(&app.model, second) catch {
                second.deinit(app.gpa);
                return;
            };
            second.deinit(app.gpa);
            cmd2.deinit(app.gpa); // 連鎖はここで打ち切り（busy=false のまま起動）
        },
        .none, .quit, .apply_patch => {},
    }
    app.model.busy = false;
}

fn parseNoMouse(init: std.process.Init) bool {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // exe 名
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-mouse")) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const no_mouse = parseNoMouse(init);

    // 1. repoRoot 解決（.inherit = プロセスの cwd）。null なら TUI を起動せずエラー終了（spec §8）。
    const root = (try cmds.repoRoot(gpa, io, .inherit)) orelse {
        std.Io.File.stderr().writeStreamingAll(io, "git-tui: ここは git リポジトリではありません (git rev-parse --show-toplevel が失敗)\n") catch {};
        // 非リポジトリは異常終了として扱う（スクリプト互換: exit 1）。ここでは未確保なので defer 不要。
        std.process.exit(1);
    };
    defer gpa.free(root);

    // 2. Model 初期化 + has_head / branch を設定。以後 cwd は常に root 相対。
    // 不変条件（重要・review Issue 1）: ここ（Model.init 成功）から g_app への浅いコピーまでの
    // 間に **エラー経路（try）を挟まないこと**。挟む間に失敗すると m を解放する errdefer が
    // 必要になる。現状の has_head/branch 設定は catch 吸収で try を使わないため、この区間に
    // errdefer は不要。所有権 errdefer はコピー直後に g_app.model を対象として張る。
    var m = try Model.init(gpa, root);
    m.mouse_enabled = !no_mouse;
    const cwd_root: Cwd = .{ .path = m.repo_root };
    m.has_head = cmds.hasHead(gpa, io, cwd_root) catch false;
    if (cmds.branchName(gpa, io, cwd_root)) |bn| {
        defer gpa.free(bn);
        m.setStr(&m.branch, bn) catch {};
    } else |_| {}

    g_app = .{
        .gpa = gpa,
        .io = io,
        .cwd = cwd_root,
        .model = m,
        .textarea = undefined, // RuntimeModel.init で生成
        .filter_textinput = undefined, // RuntimeModel.init で生成（phase 3a）
        .filter_modal = undefined, // RuntimeModel.init で生成（phase 3a）
    };
    g_app_ready = true;

    // 所有権ハンドオフ管理（review Issue 1）。浅いコピー後の**生きた所有者は g_app.model** で
    // あり、m は同一ヒープを指す stale エイリアスになる（seedInitialStatus は g_app.model を
    // 変異させ files/diff_text を確保し、setStr で再確保もする）。よって失敗時に解放すべきは
    // g_app.model であって m ではない（m を解放すると live バッファの leak / 旧ポインタの
    // 二重 free になる）。この窓では textarea は undefined・queue は空なので、解放対象は
    // model だけに限定する（より広い g_app 後始末は呼ばない）。program 構築成功後は
    // program.deinit が g_app.model を解放するので、その時点で handed_off を立て打ち切る。
    var handed_off = false;
    errdefer if (!handed_off) g_app.model.deinit();

    // git-dir 解決（worktree/submodule の .git ファイルも解決）。失敗は null へ退化し appcmd の
    // フォールバック経路（cwd 相対 .git/...）へ。起動クラッシュしない（branchName と同型）。
    // ★レビュー B1: cmds.gitDir は repoRoot/branchName と同型=caller owned の []u8 を返す。
    //   dupe 後に必ず free すること（main.zig の branchName パターンどおり）。
    //   ★配置位置（レビュー B1）: `g_app` ハンドオフ後かつ上記 errdefer インストール後。
    //   これより前（m に対する try）は main.zig の no-try 不変条件に違反し OOM で m がリークする。
    if (cmds.gitDir(gpa, io, cwd_root)) |maybe_gd| {
        if (maybe_gd) |g| {
            defer gpa.free(g); // ★ gitDir 戻り値は caller owned
            g_app.model.git_dir = try g_app.model.allocator.dupe(u8, g);
        }
        // maybe_gd == null（非リポジトリ等）は何もしない（git_dir は null のまま）
    } else |_| {} // RunError（spawn 失敗等）も握りつぶす

    // 3. 初回 status を同期ロード（start() 前なので worker も TUI も未起動）。
    seedInitialStatus(&g_app);

    // 4. zigzag Program 起動。mouse は model.mouse_enabled に従う。
    var program = try ProgramT.initWithOptions(
        gpa,
        io,
        init.environ_map,
        // fps=30 で既定 60 から半減（既存 everyMs(33)≒30fps ポーリングと整合）。アイドル CPU を下げる。
        .{ .mouse = g_app.model.mouse_enabled, .fps = 30 },
    );
    g_program = &program;
    defer program.deinit(); // RuntimeModel.deinit を呼び textarea/model/queue を後始末
    // ここで model の所有権は program へ移譲された。以後の失敗（start/tick エラー）は
    // program.deinit（上の defer）が g_app.model を 1 度だけ解放する。m への errdefer を
    // 打ち切り、同一ポインタの二重 free を防ぐ（review Issue 1）。
    handed_off = true;

    try program.start();
    while (program.isRunning()) {
        try program.tick();
    }
}

// zigzag 依存の pub 関数（RuntimeModel.view/update/init, handle*）も `zig build` で
// 型検査されるよう、main から実際の呼び出しパスで参照済み。テストでは refAllDecls しない
// （Program はテスト用 io を要し、ワーカー spawn は非決定的なため）。
