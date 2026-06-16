---
name: qa-tui
description: >
  Interactive TUI QA tests for git-tui (Zig 0.16 + zigzag). Builds the binary,
  launches it against a temp scratch git repo via tuistory, sends real keystrokes,
  and verifies terminal output. Covers launch, navigation, stage/unstage, diff
  pane, line-level staging, commit, and error handling.
---

# qa-tui -- git-tui Interactive TUI Tests

git-tui is a terminal UI for git staging and committing. It shows three panes: Changes (file list), Diff, and Commit message. It must be launched inside a git repository or it exits with code 1 and a Japanese error.

**Use the `droid-control` skill for all tuistory interactions.** Do NOT write raw tuistory commands -- the droid-control skill contains the complete, correct tuistory API reference. The instructions below describe WHAT to test; droid-control handles HOW.

## Build & Binary

- Build command (run once at the start of the run, not per-test):
  ```
  zig build -Doptimize=ReleaseFast
  ```
  This produces the binary at `zig-out/bin/git-tui`. Use this path as `$CLI_BINARY` in all tuistory launch commands. The orchestrator's pre-flight checks already verified Zig 0.16.0 and tuistory are available.

## Test Repo Setup (MANDATORY before any test)

git-tui shells out to the local `git` binary and refuses to run outside a repo. Every test run MUST first create a temp scratch repo with a known state. NEVER launch git-tui against a real working repo.

Create the temp repo and capture its absolute path as `$REPO`:

```bash
REPO=$(mktemp -d)
git init -q "$REPO"
git -C "$REPO" config user.email "qa@test.local"
git -C "$REPO" config user.name "QA"
# One committed file (gives HEAD so has_head=true and diff has a base)
echo "line1" > "$REPO/committed.txt"
git -C "$REPO" add committed.txt
git -C "$REPO" commit -q -m "initial"
# Unstaged modification to committed.txt
printf 'line1\nline2\nline3\n' > "$REPO/committed.txt"
# Staged modification (a new file, fully staged)
printf 'staged-content\n' > "$REPO/staged.txt"
git -C "$REPO" add staged.txt
# Untracked file
printf 'untracked\n' > "$REPO/untracked.txt"
# Optionally a rename for rename-aware tests:
git -C "$REPO" mv committed.txt renamed.txt 2>/dev/null || true
```

Record `$REPO` so cleanup can `rm -rf` it at the end (success or failure).

In CI, prefix launch with `env -u CI FACTORY_DISABLE_KEYRING=true` to avoid any CI-detection issues. Use session name `-s qa-test` with `--cols 110 --rows 36`.

All launch commands look like (via droid-control / tuistory):
```
tuistory launch "$CLI_BINARY" -s qa-test --cols 110 --rows 36
```
**IMPORTANT:** The binary uses its own process cwd, so launch tuistory with cwd set to `$REPO` (droid-control supports specifying cwd). Without this, git-tui will not find the repo.

## Authentication in CI

None. git-tui has no auth. The temp repo's `user.email`/`user.name` config (set above) is all that is needed for commits to succeed in CI. No GitHub secrets are required for the TUI tests themselves.

## Test Flow Menu

The orchestrator picks flows relevant to the diff. Each flow below lists: what it tests, setup needs, key keystrokes, and success criteria. Run them via droid-control (launch, send keys, snapshot, assert).

### Flow 1: Launch and initial render
**Tests:** main.zig, view.zig, model.zig -- the app starts and shows the 3-pane layout.
**Relevant when:** any of `main.zig`, `view.zig`, `model.zig`, `input.zig`, `appcmd.zig`, `git/status.zig`, `git/process.zig` changed.
**Steps:**
1. Launch in `$REPO`.
2. Wait for first render.
3. Snapshot (`snapshot --trim`).
**Pass:** Snapshot shows the three pane sections. The Changes pane lists files (staged/unstaged/untracked). The branch name is visible in the status bar. No crash, no blank screen.
**Fail:** Blank screen, panic stack trace, or immediate exit.

### Flow 2: File navigation (j/k)
**Tests:** input.zig (`keyToMsg`), update.zig (`key_down`/`key_up`), model selection.
**Relevant when:** `input.zig`, `update.zig`, `model.zig`, or `view.zig` (highlight rendering) changed.
**Steps:**
1. Launch, snapshot initial state.
2. Send `j`, snapshot.
3. Send `j` again, snapshot.
4. Send `k`, snapshot.
**Pass:** The highlighted/selected file moves down with `j`, down again with `j`, then back up with `k`. Each snapshot shows a DIFFERENT file highlighted. The selection wraps or clamps at the boundaries (does not crash).
**Negative:** Send `k` from the first file -- selection must not go negative (clamp at 0, no crash).

### Flow 3: Stage / unstage file (space / s)
**Tests:** update.zig (`toggle_stage`), appcmd.zig, git/commands.zig (stage/unstage argv).
**Relevant when:** `update.zig`, `appcmd.zig`, `git/commands.zig`, `messages.zig` changed.
**Steps:**
1. Launch, select an unstaged file with `j`.
2. Snapshot (note which section the file is in).
3. Send `space`.
4. Wait ~500ms for the worker thread + auto-refresh.
5. Snapshot.
**Pass:** After `space`, the file moves from unstaged to staged section (or vice versa). The status bar does not show a permanent error. A subsequent `space` toggles it back.
**Negative:** If busy (worker in-flight), a second rapid `space` is gated by the `busy` flag (reducer drops it or queues as pending) -- verify no crash and the state is eventually consistent.

### Flow 4: Diff pane focus and scroll (Tab, Ctrl+D, Ctrl+U)
**Tests:** view.zig (`computeLayout`, `renderDiff`), update.zig (`focus_next`, `scroll_diff_down/up`).
**Relevant when:** `view.zig`, `update.zig`, `input.zig` changed.
**Steps:**
1. Launch, select a file with a multi-line diff.
2. Send `Tab` to move focus to the diff pane. Snapshot.
3. Send `Ctrl+D` (scroll down). Snapshot.
4. Send `Ctrl+U` (scroll up). Snapshot.
**Pass:** Focus indicator moves to the diff pane. `Ctrl+D` scrolls the diff content down (later lines become visible). `Ctrl+U` scrolls back up. Each snapshot differs. No overflow / no terminal-line-wrap corruption (the README/CLAUDE.md `fitPane` gotcha).

### Flow 5: Hunk cursor and hunk jump (j/k in diff, ] / [)
**Tests:** update.zig (`diff_cursor_down/up`, `diff_hunk_next/prev`), diff/hunk.zig parsing.
**Relevant when:** `diff/hunk.zig`, `update.zig`, `view.zig` (hunk cursor rendering) changed.
**Steps:**
1. Launch, focus the diff pane (`Tab`).
2. Send `j` several times to move the hunk cursor down through diff body lines. Snapshot after each.
3. Send `]` to jump to the next hunk header. Snapshot.
4. Send `[` to jump back. Snapshot.
**Pass:** The hunk cursor moves through diff body lines with `j`, jumps to the next/previous hunk with `]`/`[`. Each snapshot shows the cursor at a different position. The cursor never lands on a `diff --git` or `@@` header line (body lines only).

### Flow 6: Line-level staging (v anchor, s stages range)
**Tests:** model.zig (`selectionRange`, `diff_anchor`), update.zig (`toggle_line_selection`, `stage_lines`), appcmd.zig (`apply_patch`), diff/hunk.zig (patch generation).
**Relevant when:** `diff/hunk.zig`, `model.zig`, `update.zig`, `appcmd.zig`, or anything touching `apply_patch` / `diff_anchor` changed. (This is the recently-merged feat/line-staging -- high-priority regression target.)
**Steps:**
1. Launch, focus the diff pane (`Tab`).
2. Move the cursor to a `+` (added) line with `j`. Snapshot.
3. Send `v` to set the anchor. Snapshot -- the anchor line should be visually marked.
4. Move the cursor down 1-2 lines with `j` to extend the range. Snapshot.
5. Send `s` to stage the selected range.
6. Wait ~800ms for the worker + auto-refresh.
7. Snapshot. Optionally run `git -C "$REPO" status --porcelain` out-of-band to verify the partial stage took effect.
**Pass:** After `v`, a selection range is visible. After `s`, the staged state changes to reflect only the selected lines (not the whole file). The diff pane re-renders with the staged lines removed or moved to staged section.
**Negative:** Setting an anchor and pressing `s` on a single line stages exactly that one line. Pressing `v` again toggles the anchor off (single-cursor mode).
**Known limitation (from TODO.md):** untracked and rename files do NOT support hunk-level staging (only file-level via `space`). Do NOT report this as a bug -- test it as expected behavior (the operation is a no-op or file-level fallback).

### Flow 7: Commit message and commit (c, Ctrl+S)
**Tests:** main.zig (TextArea wiring, `syncCommitText`), update.zig (`focus_commit`, `request_commit`), appcmd.zig (commit).
**Relevant when:** `main.zig`, `update.zig`, `appcmd.zig`, `git/commands.zig` changed.
**Steps:**
1. Launch, stage at least one file (Flow 3).
2. Send `c` to focus the commit pane. Snapshot -- focus moves to the commit textarea.
3. Type a commit message (e.g., `test commit`). Snapshot.
4. Send `Ctrl+S`.
5. Wait ~800ms.
6. Snapshot. Out-of-band: `git -C "$REPO" log --oneline -1`.
**Pass:** `c` moves focus to the commit pane. Typed text appears in the commit area. `Ctrl+S` creates a commit; the Changes pane clears the staged file and `git log` shows the new commit. The commit textarea is cleared after a successful commit (`textarea.setValue("")` on `.committed`).
**Negative:** Press `Ctrl+S` with an empty commit message -- the app must NOT create an empty commit (either blocks the action or git rejects it). Verify `git log` is unchanged.

### Flow 8: Manual refresh (r) and quit (q)
**Tests:** update.zig (`request_refresh`, `quit`), appcmd.zig (`refresh_status`).
**Relevant when:** `update.zig`, `appcmd.zig`, `autorefresh.zig` changed.
**Steps:**
1. Launch. Snapshot.
2. Modify `$REPO/untracked.txt` out-of-band (append a line).
3. Send `r`. Wait ~500ms. Snapshot.
**Pass:** After `r`, the Changes pane reflects the new content (file size or status updates). `q` cleanly exits the app (tuistory session ends, no panic).

### Flow 9 (negative): Launch outside a git repo
**Tests:** main.zig repo-root resolution, error path.
**Relevant when:** `main.zig`, `git/commands.zig` (`repoRoot`) changed.
**Steps:**
1. Create an empty temp dir (NOT a git repo): `NOTREPO=$(mktemp -d)`.
2. Launch git-tui with cwd `$NOTREPO`.
3. Capture stdout/stderr and exit code.
**Pass:** The app prints the Japanese error message (`git-tui: ここは git リポジトリではありません ...`) and exits with code 1. It does NOT start the TUI loop.
**Cleanup:** `rm -rf "$NOTREPO"`.

### Flow 10 (negative): Empty repo (no HEAD)
**Tests:** model.zig `has_head` handling, view.zig empty-state rendering.
**Relevant when:** `main.zig`, `model.zig`, `view.zig` changed.
**Steps:**
1. `EMPTYREPO=$(mktemp -d); git init -q "$EMPTYREPO"`.
2. Launch with cwd `$EMPTYREPO`.
3. Snapshot.
**Pass:** The app launches without crashing. `has_head=false` path is exercised (no panic when there is no HEAD to diff against). The status bar indicates the branch (initial/unborn). Untracked files still appear.
**Cleanup:** `rm -rf "$EMPTYREPO"`.

## Cleanup (after all flows)

```bash
rm -rf "$REPO"
# also any NOTREPO / EMPTYREPO from negative flows
```

## Known Failure Modes

1. **Launch hangs / blank screen.** zigzag needs a real PTY. tuistory provides one, but ensure `--cols` and `--rows` are set (110x36). If blank, check that the binary was built with `ReleaseFast` (Debug builds are slower but should still render within ~2s).
2. **Auto-refresh race.** git-tui polls `git status` every 1500ms (WSL2 inotify is unreliable). Rapid keystrokes immediately after a stage/unstage may hit the `busy` gate and be dropped or queued. Add a ~800ms-1500ms settle before asserting on post-stage state.
3. **WSL2 terminal quirks.** On WSL2, tmux/tuistory may need `set -g default-terminal xterm-256color` or zigzag renders blank. If snapshots are empty, try `tmux set -g default-terminal xterm-256color` before launch.
4. **CRLF / no-newline-at-end-of-file.** Patch generation for line-staging is sensitive to trailing newlines. If a line-stage produces a git error, the temp repo fixture may have introduced CRLF -- ensure fixtures use LF (`printf`, not `echo` on some shells).
5. **Zig version mismatch.** `build.zig.zon` requires minimum_zig_version 0.16.0 and zigzag is pinned to v0.1.5. A different Zig version will fail the build. The orchestrator pre-flight checks for this.
6. **`--no-mouse` flag.** If mouse events interfere with tuistory keystroke injection, launch with `--no-mouse` (the app accepts this flag). Mouse-on is the default; mouse-off is safe for automated testing.
7. **Linked worktree / submodule limitation (from TODO.md).** Hunk-level staging writes a temp patch to `<repo_root>/.git/`. In a linked worktree (where `.git` is a file), this fails. The temp scratch repo created above is a normal repo, so this does not apply -- but if you change the test repo setup, be aware.
8. **Commit pane focus disables global keys.** While the commit textarea is focused, `q` and other global keys are intentionally disabled (to prevent Japanese-IME misfires). To quit from the commit pane, first send `Esc` or `Tab` to leave focus, THEN `q`.
9. **untracked/rename hunk staging unsupported.** As noted in Flow 6, untracked and renamed files only support file-level staging. A `space`/`s` on a hunk of such files is a no-op or file-level fallback -- this is expected, not a bug.
