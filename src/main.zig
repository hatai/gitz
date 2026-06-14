//! Task 1 spike: minimal zigzag program proving the real API compiles on
//! Zig 0.16 + zigzag v0.1.5. It shows a full-width (CJK) header plus one
//! TextArea, quits on `q`, and enables mouse tracking.
//!
//! NOTE: this is a throwaway scaffold; Task 11 replaces it with the real
//! runtime wiring (worker thread + AppCmd interpreter via start()/tick()).
//! The value here is confirming the API surface recorded in
//! docs/superpowers/plans/zigzag-api-notes.md actually type-checks.

const std = @import("std");
const zz = @import("zigzag");

const Model = struct {
    /// TextArea owns heap buffers across frames, so it must be backed by the
    /// persistent allocator (ctx.allocator is a per-frame arena that resets).
    textarea: zz.TextArea,
    initialized: bool = false,

    /// The Program runtime requires a `Msg` decl; it feeds key/mouse events
    /// only for the variants that exist as fields here.
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{ .textarea = zz.TextArea.init(ctx.persistent_allocator) };
        self.textarea.setSize(40, 5);
        self.textarea.setValue("コミットメッセージ 日本語ＡＢＣ") catch {};
        self.textarea.focus();
        self.initialized = true;
        // Prove the runtime mouse command compiles/typechecks.
        return .enable_mouse;
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| {
                switch (k.key) {
                    .char => |c| {
                        // App owns submit/quit detection: TextArea has no
                        // built-in Ctrl+S handler, so we intercept here and
                        // do NOT forward control keys to it.
                        if (c == 'q' and !k.modifiers.ctrl) return .quit;
                        if (c == 's' and k.modifiers.ctrl) return .quit; // stand-in for "submit"
                    },
                    .escape => return .quit,
                    else => {},
                }
                self.textarea.handleKey(k);
            },
            .mouse => {},
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const header = "git-tui スパイク  日本語ＡＢＣ  (q / Esc で終了)";
        const body = self.textarea.view(ctx.allocator) catch "render error";
        return std.fmt.allocPrint(ctx.allocator, "{s}\n\n{s}", .{ header, body }) catch "alloc error";
    }

    pub fn deinit(self: *Model) void {
        self.textarea.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    var program = try zz.Program(Model).initWithOptions(
        init.gpa,
        init.io,
        init.environ_map,
        .{ .mouse = true },
    );
    defer program.deinit();
    try program.run();
}
