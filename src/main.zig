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
        .none, .quit, .refresh_status, .load_diff => false,
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
        .refresh_status, .stage, .unstage, .load_diff, .commit, .apply_patch => dispatchSideEffect(app, cmd),
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
    if (!autorefresh.shouldAutoRefresh(now, app.last_auto_refresh_ms, auto_refresh_interval_ms, app.worker != null, app.pending != null)) return;
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
        return viewmod.render(&g_app.model, ctx);
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

var g_click_state: input.ClickState = .{};

fn handleKey(app: *App, program: *ProgramT, k: zz.KeyEvent) void {
    // commit フォーカス時: 編集キー（文字/Enter/Backspace/矢印）は TextArea が正本。
    // keyToMsg はそれらに null を返すので、null かつ commit フォーカスなら TextArea へ委譲。
    const abstract = input.fromZigzagKey(k);
    if (abstract) |key| {
        if (input.keyToMsg(app.model.focus, key)) |m| {
            step(app, program, m);
            return;
        }
    }
    // グローバル命令にならなかったキー。commit フォーカスなら TextArea で編集する。
    if (app.model.focus == .commit) {
        app.textarea.handleKey(k);
        syncCommitText(app);
    }
}

fn handleMouse(app: *App, program: *ProgramT, m: zz.MouseEvent) void {
    if (!app.model.mouse_enabled) return;
    const layout = viewmod.computeLayout(g_program.context.width, g_program.context.height, 5);
    // changesRowLayout 用の scratch（見出し3 + ファイル数）。arena ではなく一時スタック確保。
    var scratch_buf: [256]viewmod.ChangesRow = undefined;
    const need = app.model.files.items.len + 3;
    const scratch: []viewmod.ChangesRow = if (need <= scratch_buf.len)
        scratch_buf[0..need]
    else
        scratch_buf[0..];
    const ev = input.fromZigzagMouse(m, &app.model, layout, &g_click_state, nowMs(app), scratch);
    if (input.mouseToMsg(ev)) |msg| step(app, program, msg);
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
        .load_diff, .stage, .unstage, .commit, .refresh_status => {
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
