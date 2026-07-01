# git-tui TODO（MVP 以降の機能）

MVP（ファイル単位 stage/unstage + diff 閲覧 + コミット + マウス + 日本語対応）の
完成後に着手する機能。設計の詳細は
`docs/superpowers/specs/2026-06-14-git-tui-design.md` を参照。

各項目は将来それぞれ独立した spec → 実装計画に展開する想定。

---

## TODO 1. 部分ステージング（ハンク / 行単位）

### Goal
JetBrains / lazygit と同様に、ファイル内の変更を**ハンク単位・行単位**で
stage / unstage できるようにする。

### Description
MVP ではファイル単位でしか stage できないが、実用上は「同じファイル内の一部の変更だけ
コミットしたい」場面が頻出する。diff ペインでハンクや行を選択し、その範囲だけを
stage / unstage する。

### Sub Tasks
- [x] diff のハンク（`@@ ... @@` 単位）を構造化してモデルに保持
- [x] diff ペインでハンク選択 UI（ハイライト・カーソル）を追加
- [x] 選択ハンクから `git apply --cached`（or `--cached --reverse`）用のパッチを生成
- [x] `git apply --cached <tmpfile>` でパッチを適用して stage / unstage（stdin 不可のため一時ファイル方式）
- [x] 行単位選択（複数行レンジ）→ 部分パッチ生成（phase 2）
- [x] untracked ファイルのハンク stage（phase 2）
  - **方式**: `git add -N`（intent-to-add）ではなく `git apply --cached` 単体で新規作成ハンクを
    直接 apply する（実証実験で受理を確認）。`buildLinePatch(reverse=false)` が `--no-index`
    形式の全行挿入 diff を自然に処理するため、`update.stage_lines` の untracked ガードを削除する
    だけ（`hunk.zig`/`appcmd.zig`/`messages.zig` は一切変更不要）。部分 stage 後は status が `1 AM`
    となり `replaceFiles` が staged+unstaged 2 エントリへ展開する（既存挙動で吸収）。
- [x] パッチ生成のユニットテスト（コンテキスト行・改行末尾・日本語を含む差分）
- [x] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）
- [x] **★範囲 stage が auto-refresh で破壊されるバグの修正（2026-06-18 QA で発見・ブロッカー・同日解消）**
  - **症状**: `v` で選択開始 → `j` で選択拡張 → `s` で stage の標準フローで、選択範囲ではなく
    最終カーソル位置の**単一行**しか stage されない。これにより TODO 1 の目玉「複数行レンジの部分 stage」
    が実環境で実質使用不能。単一行 stage（`v` 押さずに `s`）は正常に動作する。
  - **根拠**: `update.zig` の `clampCursor` が `diff_loaded`/`status_loaded` 経由で無条件に
    `model.diff_anchor = null` を実行する。`main.zig` の auto-refresh（1500ms ポーリング）や
    ファイル切替時の `loadDiffCmd` がこのパスを起動するため、`v` 押下から `s` 押下までの間に
    高確率で anchor が null 化される（stderr デバッグで実証）。
  - **解消**（2026-06-18）: 2 層構成。(1) **層 1（ファイル同一性ゲート）**: `model.diff_owner` フィールド +
    `isDiffOwnerCurrent` ヘルパを新設し、`diff_loaded` arm の先頭で `load_diff` 発行時の selected と
    現在の selected が同じ `(section, path)` か検証（不一致なら stale anchor を clear）。外部プロセスで
    selected が別ファイルへ切り替わった後の回帰を防止（codex レビュー B1）。(2) **層 2（validateAnchor）**:
    `clampCursor` の無条件 anchor clear を `validateAnchor`（anchor が (a) 本文行、(b) cursor と同ハンク、
    の AND を満たすなら保持）へ置換。`select_line_at` arm に明示的 clear を追加しマウスクリック＝選択解除
    セマンティクスを回復。spec: `docs/superpowers/specs/2026-06-18-range-stage-autorefresh-fix-design.md`。
- [x] **★部分 stage 後の選択ファイル追従バグの修正（2026-06-18 QA で発見・UX ノイズ・同日解消）**
  - **症状**: `untracked.txt` を部分 stage すると porcelain が `? untracked.txt` → `1 AM untracked.txt` へ
    変わり、`replaceFiles` が staged と untracked の 2 エントリへ展開する。`replaceFiles` の選択復元は
    `(section, path)` 一致で行うため、section が `.untracked` → `.staged`（または `.untracked` 残存側）へ
    変わると追従できず、diff ペインが別ファイル（先頭マッチ or index クランプ）へ切り替わることがある。
  - **影響**: 機能破壊ではない（stage 自体は成功）が、連続して部分 stage を繰り返す際の UX ノイズ。
  - **解消**（2026-06-18）: `replaceFiles` の選択復元を 2 段階へ拡張。(1) `(section, path)` 完全一致
    （従来どおり）。(2) 見つからなければ `selectByPathPriority`（優先順位 unstaged > staged > untracked）
    で path のみ一致するエントリへフォールバック。unstaged 優先は「まだ作業が残っている」側へ誘導し
    連続 stage を継続しやすくする。完全 stage 時は unstaged 側が消え staged のみ残るため staged へ追従。
    spec: `docs/superpowers/specs/2026-06-18-range-stage-autorefresh-fix-design.md` §3。

### 留意点
- **untracked の部分 stage は `--no-index` 形式の diff が前提**。`git apply --cached` は index 未登録
  パスでも `--- /dev/null` / `+++ b/<file>` 形式の新規作成ハンクを受理する（実証実験 2026-06-17）。
  `git add -N`（intent-to-add）は不要。`buildLinePatch` の変換ルールが全行挿入 diff でそのまま成立つ。
- パッチのコンテキスト行・`\ No newline at end of file`・CRLF の扱いに注意。
- 日本語を含む行でもバイトオフセットではなく行単位でパッチを組む。
- **phase 1 の既知の制約（phase 2 で対応）**:
  - [x] ~~一時パッチを `<repo_root>/.git/` に書くため、linked worktree / submodule ではハンク stage が失敗する。~~
    **解消**（2026-06-17）: `git rev-parse --absolute-git-dir` で絶対 git-dir を解決し `<git-dir>/git-tui-stage.patch` へ書込（`ApplyPatch.git_dir`・フォールバック付き）。
  - [x] ~~`focus!=.diff` で `Ctrl+d/u` を多用すると `diff_scroll` が diff 行数を超え得る。~~
    **解消**（2026-06-17）: `update.scroll_diff_down` で `diffLineCount(text)` 上限クランプ。
  - [x] ~~`input.fromZigzagMouse` の戻り値 MouseEvent リテラルが分岐ごとに重複。~~
    **解消**（2026-06-17）: `base` 構築の factoring（`MouseEvent.kind` にデフォルト `.ignore` 追加）。
  - **行単位 stage の phase 2 で未対応（さらに将来）**:
    - 飛び飛び（discontiguous）のマーク集合選択（チェックボックス型）。現状は連続レンジのみ。
    - マウスのドラッグ範囲拡張 / Shift クリック範囲拡張（`MouseEvent` に修飾キーフィールド追加が前提。現状クリックはカーソル移動のみ）。
    - **tracked diff** で文脈化が必要な No-newline 境界の選択は矛盾パッチ回避のため no-op（ガイダンス表示）。
      ※untracked の全挿入ハンクでは文脈化が発生しないため、最終 `+` 行を選択すればマーカー保持の
      有効パッチになる（2026-06-17 対応済み・spec 受け入れ基準 8）。
- **★解消済みバグ（2026-06-18 QA で発見・同日解消）**: Sub Tasks の「範囲 stage が auto-refresh で破壊されるバグの修正」
  および「部分 stage 後の選択ファイル追従バグの修正」を参照。両者とも 2 層構成（層 1: ファイル同一性ゲート `isDiffOwnerCurrent` +
  `model.diff_owner`、層 2: `validateAnchor`）+ path-only フォールバック（`selectByPathPriority`）で解消。
  spec: `docs/superpowers/specs/2026-06-18-range-stage-autorefresh-fix-design.md`。
- **rename + modify の部分 stage（2026-06-17 完了）**:
  - **方式**: `2 RM`（rename staged + 内容変更 unstaged）は `git mv` 時点で rename が index 済みのため、
    unstaged 側 diff は `new.txt` 単体の content-only diff になる。`status.parse` が `2 RM` を展開した
    unstaged エントリは `Y='M'` なので `orig_path == null` になり、`update.stage_lines` の現行ガード
    （`f.orig_path != null`）を通過する。既存の `buildLinePatch`/`buildPatch` が tracked と同形で処理する。
    **コード変更不要**・回帰テスト追加のみで完了（`docs/superpowers/specs/2026-06-17-rename-hunk-stage-design.md`）。
  - **既知の制約1（`2 .R` / `2 .C` worktree rename の部分 stage）**: porcelain `Y='R'/'C'` に対応する
    unstaged エントリは `orig_path != null` でガードブロック。diff が rename ヘッダを含むため未検証。
    将来 spec で実証してから対応。ファイル単位 stage で回避可能。
  - **既知の制約2（staged rename+modify の部分行 unstage）**: `2 R.`（rename + 内容変更が両方 staged）
    からの行/ハンク単位 unstage は、git 自体の `apply --cached --reverse` が index の old 側パス解決で
    破綻するため本ツールでもサポートしない（ガードでファイル単位 unstage を案内）。
    ファイル単位 unstage 後に再 stage で回避すること。

### QA 2026-06-18 観察による UX 改善提案（機能ブロッカーではない・任意対応）
QA（`qa` スキル + `qa-tui` サブスキル + tuistory 実機検証）で TODO 1 全 Sub Tasks が**期待どおり動作**することを確認済み。
以下は機能ブロッカーではなく、使い勝手・テスト容易性の改善案。優先度は低い。

- [x] **`v` トグル状態の視覚的明示**（低優先・UX）
  - **観察**: `v` で範囲選択開始 → もう一度 `v` で解除（単一カーソルへ復帰）した際、
    テキストダンプ snapshot では anchor 有無の区別がほぼ見えない（色違いのみ）。
    実機の色付き端末では判別可能だが、テスト自動化やスクリーンショット共有で分かりにくい。
  - **提案**: anchor 設定時に範囲全体を反転/網掛け等、形状レベルで差を出す。
    またはステータスバーに `SELECT` インジケータを表示。
  - **対応済み**（2026-06-18）: ステータスバーに `[SELECT]` インジケータ、範囲行頭に `>` prefix を実装。
    spec: `docs/superpowers/specs/2026-06-18-qa-ux-improvements-design.md` §2。
- [x] **rename+modify の staged diff 表示の補足**（低優先・UX）
  - **観察**: `2 RM`（rename staged + content modify unstaged）で部分 stage すると、
    HEAD に新パスが存在しないため `git diff --cached` が `new file mode` になる。
    これは git の仕様だが、diff ペインで見たユーザが「ファイル全体が stage された」と誤認しやすい。
    実際の index 内容は部分 stage 結果（例: `gamma` のまま `epsilon` 追加）で正しい。
  - **提案**: diff ペイン上部に rename context（`oldname.txt → newname.txt` 等）を表示するか、
    メタ情報行で「部分 stage 済み・rename 別途 staged」を明示。
  - **対応済み**（2026-06-18）: `model.isRenamePartialState` 純粋判定 + `view.renderDiff` のメタ行挿入を実装。
    `2 RM`（rename staged + content modify unstaged）で `git diff --cached` が `new file mode` になる誤認を防止。
    spec: `docs/superpowers/specs/2026-06-18-qa-ux-improvements-design.md` §3。
- [x] **commit の `Ctrl+S` キーバインドの代替検証**（低優先・互換性）
  - **観察**: tuistory 経由で `ctrl+s`（プラス区切り）が受理されず `ctrl s`（スペース区切り）で成功。
    実端末でも `Ctrl+S` がフロー制御（XOFF）に捕捉される環境があり得る。
  - **提案**: README のキーマップ表に注意書きを追加するか、代替（`Enter` や `Ctrl+Enter`）の検討。
    ※現状の `Ctrl+S` は TextArea 標準に合わせたもので妥当。ドキュメント整備で十分。
  - **対応済み**（2026-06-18）: README のキーマップ表へ `stty -ixon` の注意書きを追記。
    代替キー（Ctrl+Enter 等）は zigzag の KeyEvent サポート次第で将来検討。
    spec: `docs/superpowers/specs/2026-06-18-qa-ux-improvements-design.md` §4。
- [x] **`#` 等でハンク全体を選択するショートカット**（新規・任意）
  - **観察**: 行レンジ選択は `v` + `j` 繰り返しだが、ハンク全体を一度に stage する操作があると
    lazygit 等からの移行ユーザに馴染む。
  - **提案**: `H`（ハンク単位 stage）や `#`（ハンク全体を選択範囲に設定→`s`）等の追加検討。
    既存の `]`/`[` ジャンプと組み合わせて設計。
  - **対応済み**（2026-06-18）: `#`（select_hunk・現在ハンク本文全体を選択、`s` で stage）と
    `H`（stage_hunk・ハンクを即 stage）の両方を実装。共通ヘルパ `buildStagePatchFromSelection` で
    `stage_lines` と適用ロジックを共有。spec: `docs/superpowers/specs/2026-06-18-qa-ux-improvements-design.md` §5。

---

## TODO 2. ログ / コミットグラフ表示

### Goal
コミット履歴をグラフ（ブランチの分岐・マージ）付きで表示し、コミットを選択すると
その diff を閲覧できるようにする。

### Description
JetBrains の Git Log 相当。コミット列・作者・日時・メッセージ・参照（ブランチ/タグ）を
表示し、選択コミットの変更ファイルと diff を見られる。

### Sub Tasks

#### phase 1（線形コミット一覧 + detail diff）— 完了 (2026-06-19)
- [x] コミット取得: `git log --pretty=format:%H%x00%P%x00%an%x00%at%x00%s%x00%d -z --decorate=short --no-color` で
      (hash, 親hash列, author, 日時, subject, refs) を NUL 区切りで取得・パース
- [x] コミット選択 → 変更ファイル一覧（`git show --diff-merges=first-parent --name-status -z`）→ diff 表示
- [x] 参照（HEAD / ブランチ / タグ）のラベル表示（`git log --decorate` 相当）
- [x] **ページング / 遅延読み込み**: `--max-count` と `--skip` で末尾到達時に追加取得
- [x] マウスでコミット選択・スクロール

  **実装詳細**: spec `docs/superpowers/specs/2026-06-18-todo2-log-view-phase1-design.md`（rev.9・codex 9 段階レビュー済み）。
  Elm アーキテクチャ踏襲: 純粋層（log.zig/show.zig パーサ、Model 所有権関数、reducer stale-reject/paging/empty-guard、appcmd headState tri-state）→ UI 層（input *ForMode wrapper、view computeLogLayout/renderLog/renderDetail、main 配線）。
  H1 stale-result reject（request_hash/generation）、H4 --diff-merges=first-parent 統一、R18 paging pending gate、R22 OOM safety、R2 empty guard 等を実装。

#### phase 2（グラフ罫線 + author/日時表示）— 完了 (2026-06-20)
- [x] **グラフレーン割当アルゴリズム**: frontier-based 自前実装（spec §A algorithm B を採用）
      - `src/git/graph.zig`: `computeAll` / `computeIncremental` / `processCommit`
      - H-01 共通親集約、M-01 dense compaction、H-08 O(N²) 回避（row move・deep-copy 無し）
- [x] グラフ描画（`│ ● ╵ ╷ ─ ╴ ╶` 等の box-drawing 文字 + 6 色ローテーション）
      - `--topo-order` 追加（H-03）、tip hash 固定 paging（H-06/H-07）、bad revision 回復（M-12）
      - レスポンシブカラム省略（M-13: pane_w < 30 でグラフ非表示、< 45 で author 非表示、< 60 で date 非表示）
- [x] 日本語の author/subject/refs の桁計算（East Asian Width: zigzag 既存機能に委譲）
- [x] author / コミット日時の表示（UTC `YYYY-MM-DD`・`std.time.epoch` 使用）
  **実装詳細**: spec `docs/superpowers/specs/2026-06-19-todo2-log-view-phase2-display-design.md`（rev.2・codex 2 段階レビュー済み）。
  純粋層（graph.zig frontier-based lane assignment、Model GraphState + paging tip、LoadLogPage 独立所有型、
  appcmd logPageArgv(tip) + bad revision 検出、update computeAll/computeIncremental + OOM フォールバック + M-11 .invalid→computeAll 回復）→
  UI 層（view renderGraphCells + formatAuthorDateUTC + レスポンシブカラム省略）。
#### phase 3a（フィルタ UI + 作者）— 完了 (2026-06-20)
- [x] **フィルタ UI**（`f` キーでモーダル展開・JetBrains 風）: `zz.Modal` + `zz.TextInput` 実 API・`viewWithBackdrop` 全面置換・`F` で clear・モーダル中は q/r/L/tab/mouse 抑止
- [x] **作者での絞り込み**: `git log --fixed-strings --author=<literal>`（regex 誤爆回避・name/email 対象・大小文字区別・256 Unicode scalar 上限）・フィルタ中は `graph_render_policy=.suppressed` で graph 非表示 + `Filter: author="..." (graph hidden)` 理由表示
- [x] **paging 一貫性**: `log_paging_tip` 廃止 → `log_snapshot_tip` 一本化（`git rev-parse --verify HEAD` で snapshot 確定・revision を `<snapshot_tip>` へ明示限定で race 回避）

  **実装詳細**: spec `docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md`（rev.3・codex 2 ラウンドレビュー済み）。
  plan `docs/superpowers/plans/2026-06-20-todo2-log-view-phase3a-filter.md`。
  純粋層（`filter.zig` 新設・Model `log_snapshot_tip` 一本化 + `filter_state`/`filter_modal_open`/`log_load_error`/`graph_render_policy`・messages 新 Msg（`apply_filter: []u8` payload・`log_load_failed`/`_silent`）+ `LogLoaded`(request_tip/is_unborn)・commands `OwnedArgv` + `logArgv`/`logPageArgv`(filter,snapshot_tip) + `revParseHead`・update `apply_filter` payload-first トランザクショナル / `clear_filter` / modal / `buildLoadLogCmd` / `handleLogLoadFailed` / `git_error`(log) 廃止・appcmd `runLogInt`(rev-parse HEAD → LogLoaded/LogLoadFailed) + bad revision → LogPageFailed）→
  UI 層（input f/F + `keyToMsgForModeWithModal` 優先 + mouse 抑止・view `renderLogMode` の modal `viewWithBackdrop` 分岐 + graph 非表示理由 + `(no matching commits)`/`(no commits)` 切り分け・main `App` へ TextInput/Modal 所有 + `handleKey` routing + Enter で `apply_filter` payload dupe + `setValue`/show/hide 同期）。
  B1 tip snapshot race 回避・B2 graph policy・B4 LogLoadFailed・M3 typed failures・M4 payload-first・M5 buildLoadLogCmd・M6 modal 優先・M7 実 API・M8 `--fixed-strings`・M-N7 `apply_filter` payload・M-N8 `log_load_error` clear・M-N9 detail git_error 無視で安全側 等。tmux pty 検証でモーダル・graph 非表示・理由表示・解除・空一致・UTF-8・global key 抑止を確認済み（バグなし・454/454 tests passing）。

#### phase 3b（日付 + パス + ブランチ + フィルタ中 graph 維持）— 完了 (2026-06-29)
- [x] 日付範囲（`--since`/`--until`・**ローカル TZ**（環境 TZ・CI/SSH で TZ 変動リスクあり・README 注意書き）・`YYYY-MM-DD` と `YYYY-MM-DD HH:MM`・until 日付のみは +1day で当日包含・HH:MM 指定は排他）
- [x] パス（`-- <path>`・git デフォルト pathspec（wildcard `*`/`?`/`[abc]`）・複数可（空白区切り・quote/escape 対応）・`parsePaths`/`paths_to_string` 往復対称）

  **実装詳細**: spec `docs/superpowers/specs/2026-06-22-todo2-log-view-phase3b-date-path-filter-design.md`（rev.2・codex レビュー M1-M4/m1-m6/n1-n3 全面反映）。plan `docs/superpowers/plans/2026-06-22-todo2-log-view-phase3b-date-path-filter.md`（11 Task・plan レビュー B1/B2/M1-M3/m1-m5/n1 全面反映）。
  `FilterSpec` を `FilterCondition` union リスト（author/since/until/paths・アプローチ B・将来拡張用）へ再構築。純粋層（filter.zig の parseDate/formatGitDate/daysInMonth/addOneDay/DateSpec + parsePaths/paths_to_string・Model `filter_modal_focus: u2`・Msg `ApplyFilter` 構造体 + `filter_focus_next`/`prev`・update handleApplyFilter ApplyFilter payload-first + バリデーション・git/commands appendFilterOptions/appendPaths 2関数分割・appcmd テスト）→ UI 層（input `shift_tab` variant・view `filterReasonText`・main 4欄 TextInput + syncFilterModal プレフィル/フォーカス同期 + handleModalKey ApplyFilter 構築）。codex M1（shift_tab 抽象化）/M2（argv 2挿入点分割）/M3（addCondition OOM 時 payload 自動 deinit）/M4（paths_to_string 往復テスト）対応。504/504 tests passing。
- [x] ブランチ（`--branches`・`<snapshot_tip>` との和集合問題の解決が前提・単一 branch は hash 解決して snapshot_tip へ・複数 branch は所有集合・spec §16/B3）

  **実装詳細**: spec `docs/superpowers/specs/2026-06-29-todo2-log-view-phase3b-branch-filter-design.md`（rev.1・codex レビュー MAJOR1/MINOR1/advisory2 全面反映）。plan `docs/superpowers/plans/2026-06-29-todo2-log-view-phase3b-branch-filter.md`（codex plan レビュー BLOCKER3/MAJOR3/MINOR1 反映）。核心: branch 条件を argv 付加ではなく **revision（snapshot_tip）選択**として扱い、`git rev-parse --verify --end-of-options <rev>^{commit}` で単一 commit hash へ解決 → #2 の substrate/投影/paging tip 照合が全て不変（B3 和集合回避・`--branches=<glob>` 不使用）。任意 revspec 受理（branch/tag/remote/hash/`HEAD~N`）・先頭 `-` は reject。純粋層（filter.zig branch variant + max_branch_runes/getBranch・commands revParseVerifyArgv/revParseVerify・messages ApplyFilter.branch default null・model filter_modal_focus u2→u3 + update 明示的 5 欄 wrap・update handleApplyFilter branch 検証 defense in depth・appcmd runLogInt branch 解決分岐 + branchLoadFailed）→ UI 層（view filterReasonText branch 先頭セグメント・main 5 欄 TextInput with filter_branch_input + g_app リテラル更新）。codex MAJOR（argv builder `--end-of-options` を真の安全境界 + reducer 先頭 `-` reject の defense in depth）/advisory（`^{commit}` peel で blob/tree を解決時点で弾く）/plan BLOCKER（u3 switch `else => unreachable` 網羅・g_app リテラル 2 箇所更新・blob テスト二重 free 解消）。560/560 tests passing・tmux pty で dev 適用/clear 復帰/不明 branch エラー/5 欄 Tab cycle を確認。
- [x] フィルタ中の graph 維持（`graph.zig` の nearest-visible-parent 投影・別 spec・M1/M2/B2・phase3b も `graph_render_policy=.suppressed` で非表示で回避）: topology substrate（`git rev-list --topo-order --parents <snapshot_tip>`）取得 + `graph_project.project`（第一親チェーン・反復・メモ化）で visible commit 間の最近親可視祖先へ parent 投影 → derived を既存 `graph.computeAll`/`computeIncremental` へ入力（graph.zig 不変）。substrate 取得失敗時は suppress へ安全劣化。paging は全 loaded commits 再投影+computeAll で cross-page 自己補正（C1）。spec: `docs/superpowers/specs/2026-06-26-todo2-filter-graph-projection-design.md`・plan: `docs/superpowers/plans/2026-06-26-todo2-filter-graph-projection.md`（2026-06-28 完了・542/542 tests・tmux pty で投影 gap-collapse/clear_filter 復帰を確認）。
- [x] **StreamTooLong の limit 注入 seam**（テスト容易化・`git/process.zig`・spec §6.3）: `process.runWithLimit` + `default_stream_limit` 新設・`runLogInt`/`runLogPageInt` へ `log_limit` 注入・小 limit で StreamTooLong→`LogLoadFailed`/`LogPageFailed` 正規化を実証（2026-06-23 完了）。spec: `docs/superpowers/specs/2026-06-23-todo2-streamtoolong-limit-seam-design.md`。
- [x] busy lifecycle 完全修正（runtime lifecycle（main の `reapWorker`/`dispatchSideEffect`）のみで busy を管理・reducer で busy を触らない・M-N9・phase3a は log 中 git_error 無視で最小対処）: `App.spawn_fn`/`WorkerHandle` seam で spawn 注入可能化・sync フォールバックで busy 自前下ろし・reducer busy 書き込み 4 箇所削除・M-N9 競合回帰テスト追加（決定的）。spec: `docs/superpowers/specs/2026-06-24-todo2-busy-lifecycle-design.md`。

### 留意点
- グラフ描画は描画コストが高くなりがち。大規模リポジトリでは初期に N 件のみ取得し、
  スクロールで追加ロードする（全件をメモリに展開しない）。
- レーン割り当ては「同時に生存する分岐数」がレーン数になる。色はレーン番号でローテーション。
- マージコミット（親 2 つ以上）の罫線合流表現が描画の難所。代表的な分岐/マージ履歴で要テスト。

### パフォーマンスチューニング（予防的・Phase 0-1 完了）
大規模リポジトリ（目標 10万コミット・30fps）のための事前整備。spec: `docs/superpowers/specs/2026-06-30-perf-tuning-design.md`（rev.2）・plan: `docs/superpowers/plans/2026-06-30-perf-phase0-1.md`（rev.1）。codex spec/plan review 反映済み。
- [x] **Phase 0**（計測インフラ）: `zig build bench`（Debug/ReleaseFast 分離）・`bench/gen-history.sh`（6 プロファイル）・`computeAllTracked`（frontier max 計渵）・before レポート `bench/report-before.md`。
- [x] **Phase 1**（低リスク局所最適化・正確性不変）: `appendLogCommits` move（paging deep-copy 廃止）・`renderDiff` 1 回走査・`renderGraphCells` ANSI 有限集合キャッシュ・`mkDerived` proj consume（二重 dupe 廃止）・substrate limit env 化（`GIT_TUI_SUBSTRATE_LIMIT`・既定 64MiB）。
- [ ] **Phase 2/3**（未固定・別 plan）: `TopologySubstrate` 一体再設計（arena + move + clone 廃止・§6.2）/ `processCommit` SBO + frontier HashMap 化（§6.3/§6.4）/ projection cache（§7）。Phase 0 計測値（frontier max / peak heap）を根拠に別途設計セッションで確定。

---

## TODO 3. Drag&Drop interactive rebase

### Goal
`git rebase -i` を GUI 化し、**コミット行をマウスのドラッグ&ドロップで並べ替え**、
squash / fixup / drop / reword / edit を割り当てられるようにする。
（既存 TUI にほぼ無い差別化機能）

### Description
JetBrains の interactive rebase ダイアログ相当。rebase 対象範囲のコミットを縦に並べ、
ドラッグで順序変更、各コミットにアクション（pick/squash/fixup/drop/reword/edit）を
割り当て、確定すると rebase を実行する。

### Sub Tasks
- [ ] rebase 起点の選択 UI（`HEAD~N` / 特定コミット / upstream）
- [ ] 対象コミット列の取得と表示
- [ ] **SGR マウスのドラッグイベント取得**（press → move → release）と
      ドロップ位置計算による行の並べ替え
- [ ] キーボードでの並べ替え（`Ctrl+j` / `Ctrl+k`）も提供（マウス非対応端末向け）
- [ ] 各コミットへのアクション割り当て UI（squash/fixup/drop/reword/edit）
- [ ] reword / edit 時のメッセージ編集・一時停止フローの扱い
- [ ] `GIT_SEQUENCE_EDITOR` を本ツール自身に向けて todo リスト（pick/squash/...の並び）を
      非対話で書き換える方式の実装
- [ ] **`GIT_EDITOR` も本ツール自身に向ける**: reword のメッセージ編集や edit/squash 時に
      開かれるのは `GIT_EDITOR`。todo 本体は `GIT_SEQUENCE_EDITOR`、個別メッセージは `GIT_EDITOR`
      の**二系統を両方ハンドル**する必要がある（ファイルパスを引数で受け取り所定内容を書いて 0 終了）
- [ ] コンフリクト発生時のハンドリング（中断・継続 `--continue`・`--abort`）
- [ ] ドラッグ操作のテスト（イベント列 → 並べ替え結果の検証）

### 留意点
- 実装方式は「`GIT_SEQUENCE_EDITOR` で todo を書き換え、`GIT_EDITOR` でメッセージを書く」
  二系統の helper を本バイナリのサブコマンドとして用意するのが堅実。
- rebase 中のコンフリクトは別フロー。MVP の commit フローとは分離する。
- ドラッグの当たり判定・自動スクロール・ドロップインジケータの UX を要設計。
- ドラッグは SGR マウスの press→move→release を取得する。非対応端末向けに
  キーボード並べ替え（`Ctrl+j`/`Ctrl+k`）を必ず併設する。

---

## TODO 4. ACP（Agent Client Protocol）コミットメッセージ生成

### Goal
ステージ済みの diff を LLM エージェントに渡し、コミットメッセージを自動生成して
コミット欄に挿入できるようにする。

### Description
ユーザがキー操作（例: `g`）でメッセージ生成を起動すると、staged diff を
エージェントへ渡し、生成されたメッセージをコミット欄に差し込む（編集可能）。

### Sub Tasks
- [ ] staged diff の取得（`git diff --cached`）とサイズ制限 / 要約戦略
- [ ] エージェント接続層の実装（下記「実装方式の検討」参照）
- [ ] 生成中のローディング表示・キャンセル
- [ ] 生成結果をコミット欄（`TextArea`）に挿入し、ユーザが編集できる
- [ ] コミットメッセージ規約（Conventional Commits 等）の指示をオプション化
- [ ] エラー処理（エージェント未起動・タイムアウト・権限拒否）
- [ ] 日本語 / 英語など生成言語の指定

### 実装方式の検討（重要）
- **ACP（Agent Client Protocol）**: JSON-RPC 2.0 over stdio で
  「クライアント（エディタ）」が「エージェント（サーバ）」を子プロセス起動して連携する規格。
  仕様: https://agentclientprotocol.com/ / 実装: https://github.com/zed-industries/agent-client-protocol
  - **設計上の注意**: ACP は本来「エディタがクライアント」を前提とした設計で、
    git ツールをクライアントにするのは想定外のユースケース。実装は可能だが、
    エージェント側からのファイル読み取り等の権限要求ハンドリングが必要になる。
    `session/new` → `session/prompt` でプロンプト送信、ストリーミング応答を受け取る流れ。
  - Zig に ACP の SDK は無いため、JSON-RPC over stdio を自前実装する必要がある。
- **代替案 A（より単純）**: エージェントの CLI を直接叩く
  （例: `claude -p "<prompt>"` のような one-shot 実行）。diff をプロンプトに含めて
  標準出力からメッセージを得る。ACP の複雑さを回避できる。
- **代替案 B**: LLM プロバイダの HTTP API を直接呼ぶ（API キー設定が必要）。
- ユーザ要望は ACP 対応なので ACP を第一候補としつつ、初期実装では代替案 A で
  動くものを先に出し、ACP は段階的に対応する案も検討する。

### 留意点
- diff が大きい場合のトークン超過対策（ファイル単位要約・truncate）。
- 機密情報を含む diff を外部へ送る点について、起動時の明示的な同意 / 設定を設ける。

---

## TODO 5. 変更の破棄（Rollback / discard）

### Goal
選択したファイルの未コミット変更を破棄（`git restore`）できるようにする。
JetBrains の Rollback 相当。

### Description
MVP では破壊的操作のため除外した。Unstaged の変更を破棄、または untracked ファイルを削除する。
誤操作で作業内容が失われるため**確認ダイアログを必須**とする。

### Sub Tasks
- [ ] Unstaged 変更の破棄: `git restore -- <path>`（worktree を HEAD/index へ戻す）
- [ ] Staged の取り消し + 破棄の区別（unstage は MVP 済み、破棄は別操作として明示）
- [ ] untracked ファイルの削除: `git clean -f -- <path>`（または OS のファイル削除）
- [ ] **確認ダイアログ**（破棄対象のファイル名と件数を表示。`y/N`、既定 No）
- [ ] 複数選択への対応（将来）

### 留意点
- 取り返しがつかない操作なので、確認なしでは絶対に実行しない。
- untracked の `git clean` は範囲指定を誤ると広く消すため、必ず `-- <path>` で限定する。
