---
name: qa
description: >
  Run QA tests for git-tui (a Zig 0.16 + zigzag terminal UI for git staging/commit).
  Analyzes git diff to determine if TUI source changed, builds the binary, launches it
  via tuistory against a temp scratch git repo, and verifies interactive behavior.
  Use when testing PRs, releases, or smoke testing the TUI.
---

# QA Orchestrator

**SCOPE: This skill performs manual/functional QA only -- verifying that the TUI actually works by interacting with it as a real user would (launching the binary, sending keystrokes, reading terminal output). Do NOT run or report on `zig build test`, linting, typecheck, or unit tests. Those are handled separately.**

git-tui is a single-app TUI with no web, auth, or integrations. All QA is interactive terminal testing via tuistory.

## Step 1: Load Configuration

Read `.factory/skills/qa/config.yaml`. Key facts:
- Project: git-tui (Zig 0.16 + zigzag v0.1.5, fixed in `build.zig.zon`)
- Single app: `tui` (path patterns: `src/**/*.zig`, `build.zig`, `build.zig.zon`)
- Build: `zig build -Doptimize=ReleaseFast` -> binary at `zig-out/bin/git-tui`
- Test tool: tuistory (interactive TUI testing)
- Default target: `local` (no remote environments exist)
- ImageMagick: true (animated GIF diffs of before/after terminal states are available)

## Step 2: Determine Target Environment

Always use `local`. git-tui runs in a terminal and shells out to the local `git` binary; there are no dev/staging/prod environments. The app must be launched inside a git repository (launching outside one prints a Japanese error and exits 1).

**Restriction:** Only run against the per-run temp scratch repo created by the qa-tui sub-skill. Never target the user's real working repositories.

## Step 3: Analyze Git Diff

Run `git diff` (and `git diff --cached` / `git log` for context) to determine what changed. Map changed files to apps using the `path_patterns` in config.yaml.

- Files matching `src/**/*.zig`, `build.zig`, `build.zig.zon` -> app `tui` -> load qa-tui sub-skill.
- Files NOT matching any app's path_patterns (e.g., `.factory/skills/**`, `docs/**`, `.github/**`, `TODO.md`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `mise.toml`) are NOT app code. Do NOT run TUI test flows for them.

If NO app code changed (docs-only, config-only, CI-only changes): report as INCONCLUSIVE: "No app code changed -- QA not applicable for this diff." Do NOT build, do NOT launch, do NOT run any flows.

## Step 4: Pre-flight Checks (only if app `tui` is affected)

1. **Verify Zig 0.16.0 toolchain is available.** Run `zig version`. If missing or != 0.16.x, report BLOCKED with: "Zig 0.16.0 required (pinned in mise.toml). Install via `mise install` or https://ziglang.org/download/." Do not proceed.
2. **Verify tuistory is available.** Run `tuistory --version`. If missing, report BLOCKED with: "tuistory not installed. Run `npm install -g tuistory`." (In CI the workflow installs it; locally the user must have it.)
3. **Verify git is available.** Run `git --version`. If missing, report BLOCKED.

If a pre-flight check fails, report it as BLOCKED with the specific error and remediation, but still proceed with any checks that can run.

## Step 5: Execute Diff-Relevant Flows

Read `.factory/skills/qa-tui/SKILL.md`. That sub-skill contains a MENU of available test flows. You must:

1. Read the diff carefully and identify which flows are relevant to the change.
2. Run those flows PLUS adjacent flows that verify the change integrates correctly (e.g., if line-staging code changed, test that the binary still launches and basic j/k navigation works).
3. Do NOT run completely unrelated flows (e.g., if only `diff/hunk.zig` changed, do NOT test commit-message editing exhaustively).
4. If no existing flow covers the change, write a NEW ad-hoc test that directly verifies the changed behavior (launch binary, send the relevant keystrokes, capture terminal output, assert on the visible state).
5. Do NOT run `zig build test`, unit tests, or any automated test suite. This is manual/functional QA -- interact with the TUI as a real user would.

The qa-tui sub-skill describes WHAT to test (launch, press j, verify selection moved); the `droid-control` skill (which the sub-skill instructs you to use) handles HOW to drive tuistory.

## Step 6: Evidence Capture

After each significant test step, capture evidence as **text snapshots** (primary evidence -- renders inline in the PR comment).

Use `tuistory -s <session> snapshot --trim` (via the droid-control skill) to capture terminal state as text. Embed each snapshot directly in the report as a fenced code block with a descriptive label.

Evidence quality rules:
- Each snapshot MUST show something DIFFERENT. Wait for the UI to change before capturing again.
- Label each snapshot clearly: what it shows and why it matters for the test.
- Focus on the RELEVANT content. Trim to the meaningful part.
- If ImageMagick is available (config says true), you MAY also generate an animated GIF of the interaction and save it under `./qa-results/$RUN_ID/` for the downloadable artifact. Do NOT embed `![image](url)` in the report -- reference the filename instead.

## Step 7: Test Quality Gate

1. **CHANGE-SPECIFIC FIRST.** At least half your tests should directly verify the behavioral change in the diff.
2. **INTEGRATION TESTS ARE VALID.** Tests verifying the change integrates with existing features (binary launches, j/k still works, /help equivalent) are good. These are NOT smoke tests.
3. **NO UNRELATED FLOWS.** Do not test features completely unrelated to the diff.
4. **NO AUTOMATED TEST SUITES.** Do NOT run `zig build test`. This is manual/functional QA only.
5. **NEGATIVE TESTS.** Include at least 1 test verifying error handling or boundary conditions (e.g., launching outside a git repo, pressing j past the last file, committing with an empty message).
6. **INTERACTIVE TESTING.** Test by actually interacting with the TUI as a real user would -- real keystrokes, real terminal output.
7. **INCONCLUSIVE IF UNSURE.** If you cannot articulate what the PR changes, mark INCONCLUSIVE rather than PASS.

## Step 8: Handle Failures

**Never silently skip a flow.** If a flow cannot complete, report it as BLOCKED with what was tried and how the user can fix it. Then continue to the next flow -- never abort the entire run for a single failure.

## Step 9: Generate Report

Generate the report at `./qa-results/report.md` using `.factory/skills/qa/REPORT-TEMPLATE.md`.

Key rules:
- Start with `## QA Report` heading followed by the test results table.
- Result column MUST use emojis: :white_check_mark: PASS, :x: FAIL, :no_entry: BLOCKED, :warning: FLAKY, :grey_question: INCONCLUSIVE.
- Keep it CONCISE. Table + short "Action Required" section (if any) + collapsed evidence = the entire report.
- Do NOT include "Behavioral Change Summary", verbose prose about what the diff does, or setup steps as test rows.
- Put ALL evidence (snapshots) in a single collapsed `<details>` block.
- Embed terminal text snapshots as labeled fenced code blocks.

## Step 10: Suggest Skill Updates (Failure Learning)

`failure_learning` in config.yaml is `suggest_in_report`.

After generating the report, check if any BLOCKED or FAIL results revealed a **testing environment insight** that would help future QA runs succeed. This is about how the testing environment works, NOT about fixing bad selectors or typos in the skill.

**Good suggestions** (environment/TUI knowledge):
- "git-tui's auto-refresh (1500ms) races with rapid keystrokes in tuistory -- add a 2s settle before diff assertions"
- "ReleaseFast build takes ~45s cold -- note in pre-flight so the timeout isn't mistaken for a hang"
- "tmux under WSL2 needs `set -g default-terminal xterm-256color` or zigzag renders blank"

**Bad suggestions** (skill bugs, not environment insights -- do NOT suggest these):
- "Pressed j but nothing happened" -- that's a skill bug, fix it directly
- "The commit pane text changed" -- that's expected from the PR diff

Format as a table with severity, collapsible fix prompts, and a count in the heading:

## Suggested Skill Updates (N issues found)

| #   | Severity        | File     | Issue               | Fix Prompt                                                                           |
| --- | --------------- | -------- | ------------------- | ------------------------------------------------------------------------------------ |
| 1   | <emoji> <level> | `<file>` | <short description> | <details><summary>Copy</summary><br>`<full droid prompt to fix the issue>`</details> |

**Severity levels:**
- `:red_circle: Breaking` -- Causes test failures every run (wrong binary path, missing Zig version, wrong tuistory cols)
- `:yellow_circle: Degraded` -- Intermittent failures (timing issues, auto-refresh races, WSL2 terminal quirks)
- `:large_blue_circle: Info` -- New knowledge that improves future runs but doesn't cause failures

Do NOT suggest updates for failures already covered in qa-tui's Known Failure Modes, skill bugs, or expected behavior changes from the PR. If no genuinely new insights were discovered, omit this section entirely. Do NOT write `qa-results/skill-updates.json` (config is `suggest_in_report`, so report-only).
