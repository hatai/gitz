<task id="ses_11d12dc78ffebwpH4mHMJmq1R7" state="completed">
<task_result>
必要な文脈は揃いました。rev.3 設計ドキュメントを Markdown テキストとして返します（コード編集・ファイル作成は行っていません）。

---

# コミットログフィルタ（作者 MVP）設計 — TODO 2 / phase 3a（rev.3）

- 日付: 2026-06-20（rev.3: codex rev.2 レビュー M-N7..M-N9 / m-N1..m-N5 / n-N1..n-N3 全面反映版）
- 対象: `TODO.md`「TODO 2 phase 3（フィルタ機能）」のうち **phase 3a = 作者フィルタ + フィルタ UI 基盤（zz.Modal + zz.TextInput 実 API）+ codex rev.1/rev.2 全対策**
- 親設計:
  - `docs/superpowers/specs/2026-06-14-git-tui-design.md`
  - `docs/superpowers/specs/2026-06-18-todo2-log-view-phase1-design.md`（rev.9・phase 1 完了版）
  - `docs/superpowers/specs/2026-06-19-todo2-log-view-phase2-display-design.md`（rev.2・phase 2 完了版）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（**zigzag/std の実 API はこれが正**・本設計 §15 で TextInput/Modal 実シグネチャを追記）
- スコープ外（phase 3b）: 日付範囲 / パス / ブランチフィルタ。§16 拡張ポイントに概要のみ。

> **rev.2 との差分（本 rev.3 の方針）**: rev.2 は compile 不能な擬似コードと所有権破綻・race 残存を含んでいた。rev.3 は **(a) データ構造は field 定義のみ、(b) Msg/AppCmd はタグ+ペイロード field 定義のみ、(c) reducer arm は番号付きステップ（コード block 無し）、(d) 方針・判断根拠・注意点を dense に** 記述する。実装コード（compile 可能な Zig block）は書かない。所有権ライフサイクル・errdefer 位置等の詳細は writing-plans / 実装フェーズへ委ねる。

---

## Status

**Draft for user spec-review（プロダクト判断は §19 Open product decisions へ集約・ユーザーが覆可能）**。codex rev.1 指摘（B1〜B4 / M1〜M12 / MINOR1〜7 / NIT1〜3）および codex rev.2 指摘（M-N7〜M-N9 / m-N1〜m-N5 / n-N1〜n-N3）の対応方は **「方針反映済み・実装で検証」**（rev.2 の「全て反映済み」は過剰だったため修正）。各指摘が「どの節のどの規約で解決されるか」を対応表（§0）へ明示。本 spec を user が承認後、純粋層（filter.zig / model / messages / update / appcmd / git）の TDD → UI 配線の順で実装へ入る。

---

## 0. codex レビュー反映の対応表

### 0.1 BLOCKER（rev.1）

| ID | 内容（要約） | 反映節 | 根拠実コード |
|---|---|---|---|
| **B1** | tip 固定 paging の安全性の主張が誤り（`items[0].hash` を tip とすると、フィルタ後の先頭は HEAD とは限らない） | §1.2（`log_snapshot_tip` 一本化）, §6（`runLogInt` で `git rev-parse --verify HEAD` → `<snapshot_tip>` 明示限定）, §3.2（`LogLoaded.request_tip`）, §4.1（`handleLogLoaded` で snapshot_tip dupe） | `src/update.zig:578-590`, `src/git/commands.zig:83-112`, phase2 spec §B.5/E.6 |
| **B2** | `.invalid` は表示ポリシーではなく再計算可能なキャッシュ不正状態。`invalidateLogGraph()` で「フィルタ中 graph 非表示」は成立しない | §1.3（`graph_render_policy`）, §4.1/4.2（policy 抑制）, §8（renderLog で policy 参照） | `src/update.zig:582-590,619-637`, phase2 spec §E.1, `src/view.zig:447` |
| **B3** | `--branches=X` と `<tip_hash>` の併用は到達集合の**和集合**になる | **phase 3b**（本設計ではブランチ対象外・§17 で和集合問題の回避方針のみ） | `git-rev-list(1)`, `gitrevisions(7):524-530` |
| **B4** | 初回 `git log` のフィルタエラーが `log_page_failed{skip=0}` になり、reducer が `log_page_requested==null` の初回失敗を stale 破棄する | §3.2（`Msg.log_load_failed` / `log_load_failed_silent`）, §4.3（generation 照合で受理 → `log_load_error`）, §8（`(error) <text>` 表示） | `src/appcmd.zig:174-185,198-206`, `src/update.zig:642-668` |

### 0.2 MAJOR（rev.1）

| ID | 内容（要約） | 反映節 |
|---|---|---|
| **M1** | 「フィルタ種別を問わず graph は破綻」は断定が強すぎる | §2（「正しい topology を保証できない」へ表現修正・例示） |
| **M2** | B2/A3 コスト評価が偏向。既存 `processCommit` は visible commit 間の parent relation が与えられれば再利用可能 | §2, §18（phase 3b で nearest-visible-parent 投影を L 案として記載） |
| **M3** | `generation` stale-reject は `git_error` には効かない。log 系エラーを generation 付き typed Msg へ統一すべき | §3.2（`LogLoadFailed`/`LogPageFailed` へ generation 統一）, §6（`git_error` で log recovery しない・bad revision は `LogPageFailed` へ） |
| **M4** | `apply_filter` が OOM 時にトランザクショナルでない | §4.4（payload `[]u8` → FilterSpec 1 つ構築 → Model へ swap → AppCmd 用は swap 後から clone・強例外保証） |
| **M5** | filter の永続化範囲が未定義 | §4.5（共通 `buildLoadLogCmd` builder へ集約・伝播漏れ防止）, §19（デフォルトは全 site で保持） |
| **M6** | モーダル中の入力優先順位が不足（`q/r/L/tab` が先に処理・mouse も背面 pane へ） | §7.1（`keyToMsgForModeWithModal` を `keyToMsgForMode` の前に配置）, §7.2（mouse 抑止） |
| **M7** | `zz.TextInput`/`zz.Modal` は実シグネチャが確定可能 | §1.5（実 API で記載）, §15（api-notes 追記内容） |
| **M8** | 作者フィルタの意味が未定義 | §2（`--fixed-strings --author=<literal>`・大小文字区別あり・name/email 対象） |
| **M9** | 日付フィルタの意味論コストが高い | **phase 3b**（本設計では対象外） |
| **M10** | 「作者のみ」は TODO phase3 の完了条件（4 種）を満たさない | §Goal（phase 3a を部分マイルストーンと明記）, §16 |
| **M11** | dynamic argv の解放方針が脆い | §5.2（`OwnedArgv` 方針のみ・実装は plan/実装へ委ねる） |
| **M12** | worker/pending latest-wins と filter apply の競合テストがない | §14（M12 専用テスト群・但し sleep 依存を避け pure helper 抽出） |

### 0.3 MINOR / NIT（rev.1）

| ID | 内容（要約） | 反映節 |
|---|---|---|
| **MINOR1** | 空フィルタ結果の状態仕様不足（`log_has_more=false`/tip 保持/graph policy disabled/selection 正規化/`(no matching commits)` vs unborn `(no commits)` の区別） | §4.1, §8 |
| **MINOR2** | bad revision recovery の filter 保持。branch 消失は明示エラー・無条件 HEAD fallback しない | §6（`runLogPageInt` の bad revision → snapshot_tip クリア + 次 LoadLog で再解決・filter 保持） |
| **MINOR3** | path 入力の pathspec semantics 未定義 | **phase 3b** |
| **MINOR4** | 新規 `filter.zig` の test aggregation。`src/root_test.zig` の `@import` 追加 | §1.1, §13 |
| **MINOR5** | Modal 描画モデルが曖昧（`viewWithBackdrop` は全面 canvas・既存 render との単純 join は overlay にならない） | §8（render 最終段で modal 有無を分岐・**base view を返さず** `viewWithBackdrop` を返す） |
| **MINOR6** | テスト境界不足 | §14 |
| **MINOR7** | `StreamTooLong` 正規化（`std.process.run` の 16MiB 制限） | §6（`LogLoadFailed`/`LogPageFailed` へ正規化・limit 注入設計を推奨） |
| **NIT1** | 「graph の本来の情報（分岐/マージの拓）」→「分岐・マージのトポロジー」 | §2 で修正済 |
| **NIT2** | 「tip 不変なら機能」→「初回と追加ページが同一 revision set・同一 filter・同一 order を使う場合に機能」 | §2 で修正済 |
| **NIT3** | C1 の「TextArea 流用 fallback」は単一行作者入力には不自然。実 `TextInput` API 利用可能 | §1.5, §9 で fallback 前提削除 |

### 0.4 rev.2 新規指摘（MAJOR / MINOR / NIT）

| ID | 内容（要約） | 反映節 | rev.2 からの差分 |
|---|---|---|---|
| **M-N7** | `filter_draft` 二重正本と OOM 握り潰し（`syncFilterDraft` が `setStr catch {}`） | §3.1（`Msg.apply_filter: []u8` payload 化・`filter_draft` 廃止）, §9（main が `TextInput.getValue()` を dupe して送信・Msg consumer が free） | `filter_draft` / `syncFilterDraft` 削除 |
| **M-N8** | success 時 `log_load_error` clear 未規定 | §4.1（`handleLogLoaded` stale check 通過後、commits 更新と同一トランザクションで `setStr(&log_load_error, "")`） | — |
| **M-N9** | stale detail git_error が新 filter worker の busy を解除 | §4.8（detail git_error に owner hash を持たせ stale reject・busy の完全修正は §18 将来課題） | — |
| **m-N1** | unborn と filter 空一致の区別不可 | §3.2（`LogLoaded.is_unborn: bool` 追加・appcmd が headState tri-state で判定）, §8（view が `is_unborn` で `(no commits)` / `(no matching commits)` 切り分け） | snapshot_tip は unborn で空文字（所有・長さ 0） |
| **m-N2** | char/byte 上限不一致（`max_author_bytes`=256 バイト vs `TextInput.char_limit`=文字数） | §1.1（`FilterSpec.max_author_runes` = 256 Unicode scalar）, §2, §9（`TextInput.setCharLimit(256)` と整合） | `max_author_bytes` → `max_author_runes` へ改名 |
| **m-N3** | `checkAllAllocationFailures` 滥用（OOM を握る関数へ使うと `SwallowedOutOfMemoryError`） | §14（OOM を伝播する純粋 helper のみへ使用・OOM 回復関数は FailingAllocator の特定 fail index・subprocess 含む appcmd 全体へは非使用） | — |
| **m-N4** | worker 競合テスト harness 非決定的（private + 実 thread + 33ms tick） | §14（dispatcher/reaper の state machine を pure helper へ抽出するか fake executor 注入・sleep 依存テストにしない） | — |
| **m-N5** | Modal backdrop 説明不正確（`viewWithBackdrop` は全面 canvas を solid backdrop・透過しない） | §8（「modal 表示中は base view を返さず `viewWithBackdrop` を返す・背景は見えない」を基準へ明記） | — |
| **n-N1** | Zig 0.16 API 疑義は全て問題なし（`std.ArrayList` unmanaged, `std.process.run`, `std.Io.Limit`, `Term.exited` 確認済） | （指摘無し・本設計でもこれらを踏襲） | — |
| **n-N2** | rev.2 §0「全て反映済み」は過剰（B1/M4/M11 は擬似コードが成立していない） | §Status（「方針反映済み・実装で検証」へ修正） | — |
| **n-N3** | MINOR8 は前回レビューに存在しない（新規 UX 判断） | §8.2（「graph 非表示理由表示」を新規プロダクト判断として §19 へ移動・ID 付け替え） | — |

### 0.5 rev.2 指摘「実装開始前に最低限反映すべき5点」と rev.3 の対応

1. **snapshot tip 一本化（race 回避）** → §1.2/§1.4/§6 で `log_paging_tip`（phase2）を廃止し `log_snapshot_tip`（phase3a・rev-parse HEAD）へ一本化。revision を `<snapshot_tip>` へ明示限定することで rev-parse 後の HEAD 移動でも一貫性保持。
2. **`handleApplyFilter` 再設計（payload-first）** → §3.1/§4.4 で `Msg.apply_filter: []u8`（main が `TextInput.getValue()` を dupe）へ。`filter_draft` 廃止。reducer は payload から FilterSpec を1つ構築 → Model へ swap → AppCmd 用は swap 後の `model.filter_state` から clone。
3. **Modal `viewWithBackdrop` 全面置換** → §8 で「modal 表示中は base view を返さず `viewWithBackdrop` を返す（背景は見えない）」を採用。オーバーレイ compositor は §18 将来課題。Modal へ button を追加せず Enter/Esc をアプリ側（input.zig）で先に横取り。
4. **`LogLoadFailedSilent` と typed bad-revision recovery** → §3.2 で `log_load_failed_silent`（payload 無し）を `log_page_failed_silent` と対で追加。bad revision recovery は §6 で `LogPageFailed` arm 側で `clearLogSnapshotTip` + 次回で再試行（filter 保持）。
5. **`--fixed-strings --author=<literal>`（escape 自前廃止）** → §2/§5 で採用。`escapeRegexLiteral` は廃止。phase3a は --author のみなので --grep 等への --fixed-strings の副作用は無し。

---

## Goal

TODO 2 phase 3 の **部分マイルストーン phase 3a** として（M10 対策・phase 3 全体の完了ではない）:

1. **作者フィルタ**: `f` キーでモーダルを開き、作者名（partial）を入力 → Enter で `git log --fixed-strings --author=<literal>` 適用。一致 commit のみ線形一覧。
2. **フィルタ UI 基盤**: `zz.Modal` + `zz.TextInput` の**実 API**（§1.5）を用いたモーダルポップアップ。`viewWithBackdrop` 全面置換（§8）。
3. **codex rev.1/rev.2 全対策**: BLOCKER4 / MAJOR12 / rev.2 MAJOR3 / MINOR7+NIT3 / rev.2 MINOR5+NIT3 を全て仕様へ反映（方針レベル・実装で検証）。
4. **graph 非表示時の UX**: フィルタ中は graph 計算を `graph_render_policy` で抑制し、理由（`Filter: author="..." (graph hidden)`）を表示。

完了後、`TODO.md` phase 3 の「フィルタ UI」「作者での絞り込み」を部分チェック（phase 3b 残: 日付/パス/ブランチ）。

---

## Background

### 現状（実コードから検証済みの事実）

| 項目 | 事実 | 出典 |
|---|---|---|
| フィルタ引数の拡張ポイント | `logArgv`/`logPageArgv` は `skip/max_count`（+ `<tip_hash>`）のみ。`--author` 等は未設計 | `src/git/commands.zig:60-112` |
| パーサのフィルタ依存性 | 零。`log.parse` は NUL 区切り raw bytes を消費するだけ | `src/git/log.zig:27` |
| Commit 構造体 | `hash/parents/author/epoch_sec/subject/refs` 全て `[]u8`（persistent 所有） | `src/git/log.zig:7-22` |
| stale-reject 機構 | generation(初回 LogLoaded) / generation+skip+tip(LogPageLoaded) の多点照合 | `src/update.zig:548-640` |
| tip 固定 paging | `logPageArgv(--topo-order --skip=N --max-count=100 <tip_hash>)`。tip は初回 `items[0].hash` から設定 | `src/git/commands.zig:85-112`, `src/update.zig:578-581` |
| graph 計算 | frontier-based・phase2 §A.3。`handleLogLoaded`/`handleLogPageLoaded` で `computeAll`/`computeIncremental`。`.invalid` は OOM 回復で再計算対象 | `src/update.zig:582-590,619-637`, `src/git/graph.zig` |
| `f` キー | `keyToMsgForLog` で未割当（null） | `src/input.zig:173-200` |
| モーダル/ポップアップ描画 | 先例なし（changes/log 2モードのみ） | `src/view.zig:644-682` |
| TextArea 横取りの先例 | あり。`handleKey` で commit フォーカス時に `textarea.handleKey(k)` へ委譲 | `src/main.zig:339-355` |
| `zz.Modal` / `zz.TextInput` | **実在・実シグネチャ確定済み**（§1.5） | `zig-pkg/.../components/{text_input,modal}.zig` |
| 所有権ヘルパ | `replaceLogCommits`/`appendLogCommits`/`setLogPagingTip`/`invalidateLogGraph`/`clearLogPagingTip` 全てトランザクショナル | `src/model.zig:237-368` |
| worker/pending latest-wins | `dispatchSideEffect` で busy 中は pending 上書き・`reapWorker` で起動 | `src/main.zig:153-175,216-235` |
| log モードの auto-refresh 抑止 | 済み。`shouldAutoRefresh` が `view_mode==.log` で即 false | `src/autorefresh.zig:21` |
| Model 既存フィールド群 | `log_paging_tip` が phase2 で存在・phase3a で `log_snapshot_tip` へ一本化 | `src/model.zig:65` |

### codex M1/M2/NIT1/NIT2 の訂正

phase2 rev.0 で「フィルタ種別を問わず graph は破綻する（A1 の部分集合で前提崩壊）」としたのは**断定が強すぎる**。正確には:

> `git log --author=...`（A1 git CLI フィルタ）の出力は部分集合となり、一般の作者・日付・パスフィルタでは graph.zig の frontier-based 連続性前提（`src/git/graph.zig:191-222` で `c.hash` が frontier に無ければ新規 tip・`:239-280` で非表示親も frontier に残る）から**正しい topology を保証できない**。偽 tip・残存 frontier・偽 lane が発生し得る。ただし部分集合が親閉包を保つ場合（祖先鎖のみ一致等）や全 commit 一致の場合は破綻しない。

phase 3a は作者のみで、**graph 維持を保証しない**（policy で抑制・§1.3）。graph 維持は phase 3b 以降の別課題（nearest-visible-parent 投影 = L 案、または Git history simplification = 別案・§18）。

---

## Non-goals

- **日付 / パス / ブランチフィルタ**: phase 3b（§16 で拡張ポイントのみ）。
- **filter 中の graph 維持**: 本設計では policy で非表示（M1/M2 の訂正に従い「保証できないから抑制」）。
- **複数 branch 選択**: phase 3b（B3 の和集合問題の解決が前提）。
- **filter 条件の保存/復元（アプリ再起動跨ぎ）**: メモリ上のみ。設定ファイル永続化は別課題。
- **filter 履歴（ドロップダウン等）**: `TextInput.suggestions`（§1.5）は API 上存在するが phase 3a では未使用。
- **オーバーレイ compositor**（base view を透けて見せる）: `viewWithBackdrop` 全面置換を採用するため、modal 表示中の base は見えない（m-N5）。compositor は §18 将来課題。
- **busy lifecycle の完全修正**: detail git_error の stale reject（§4.8）は最小対処。runtime lifecycle のみで busy を管理する完全修正は §18 将来課題（M-N9）。

---

## Architecture overview

Elm 風・副作用隔離アーキテクチャ（CLAUDE.md）を踏襲。純粋層（`filter.zig` 新設 / `model.zig` / `messages.zig` / `update.zig` / `appcmd.zig` / `git/commands.zig` / `git/process.zig`）を TDD → UI 層（`input.zig` / `view.zig` / `main.zig`）を配線、の順。

```
[ユーザ `f`]
   ↓ input.keyToMsgForModeWithModal（modal visible を前判定・M6）
   ↓ Msg.open_filter_modal
   ↓ update: model.filter_modal_open = true
[ユーザ入力 `foo<Enter>`]
   ↓ main.handleKey: modal 中は TextInput.handleKey へ委譲（Enter/Esc は input 側で Msg 化）
   ↓ Enter 押下: main が TextInput.getValue() を dupe → Msg.apply_filter: []u8（payload・M-N7 解決）
   ↓ update.apply_filter（payload-first トランザクション・M4）
   │   ├─ payload から FilterSpec を1つ構築（author set・所有）
   │   ├─ Model 用へ swap（旧 filter_state を deinit）
   │   ├─ AppCmd 用は swap 後の model.filter_state から clone
   │   └─ generation bump / clear snapshot_tip / replaceLogCommits(&.{}) /
   │      graph_render_policy=.suppressed / load_log 発火（AppCmd 用 clone を move）
   ↓ AppCmd.load_log{filter, generation, ...}
   ↓ appcmd.runLogInt: headState → git rev-parse --verify HEAD（snapshot_tip・B1）→
   │                    logArgv(skip, max, snapshot_tip, filter)（--fixed-strings --author=<literal>・M8/M11）→ process.run
   ↓ Msg.log_loaded{request_tip, is_unborn, generation, entries, ...} or Msg.log_load_failed{...}（B4/M3）
   ↓ update.handleLogLoaded: snapshot_tip dupe / graph_render_policy==.suppressed で graph 計算スキップ（B2）
   │                         / log_load_error を clear（M-N8）
   ↓ view.renderLogMode: graph 非表示理由 + log_load_error 表示（MINOR1/5）+ modal 有無で viewWithBackdrop 分岐（m-N5）
```

---

## 1. Data structures

### 1.1 新モジュール `src/filter.zig`（純粋・zigzag 非依存・TDD 対象・MINOR4）

`FilterSpec` は `model.zig` と `messages.zig` の双方から参照されるため、独立モジュールへ分離（MINOR4）。phase 3a は `author: ?[]u8`（persistent 所有）のみ。

**`FilterSpec` 構造体の field 定義**（実装コードは書かない・field と意味のみ）:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `author` | `?[]u8` | persistent 所有・null または dup 済み `[]u8` | 作者名 partial（ユーザ入力そのまま・未 escape）。null = フィルタ無し。空文字は null と同義（`isEmpty()`==true）。長さ上限は Unicode scalar 数で `max_author_runes`（256・m-N2） |

**定数**:
- `max_author_runes: usize = 256`（Unicode scalar 数・m-N2。`TextInput.setCharLimit(256)` と整合）。※バイト数上限ではない。日本語 256 文字 = 最大 768 バイトまで許容。

**方針（メソッド実装コードは書かない・ステップで記述）**:
- `init()`: `.author = null` を返す（非失敗）。
- `isEmpty()`: `author` が null または空文字なら true。argv へ `--author` を追加しない判定に使う。
- `setAuthor(a, value)`: 空文字は `clearAuthor` へ正規化。Unicode scalar 数 > `max_author_runes` は `error.AuthorTooLong`。dup 成功後に旧を free（トランザクショナル・OOM で self 不変）。Unicode scalar 数のカウントは `std.unicode.utf8CountCodepoints` で（m-N2）。
- `clearAuthor(a)`: 旧を free して null。
- `clone(a)`: deep-copy。各 optional field 毎に errdefer で順次 rollback（★M4 payload-first で Model swap 後に AppCmd 用を確保するために使う）。
- `eql(other)`: slice 内容比較。stale reject 等では使わない（generation で管理）。
- `deinit(a)`: `clearAuthor`。

> **注意**: `escapeRegexLiteral` は rev.2 に存在したが **rev.3 では廃止**（§2 の `--fixed-strings` 採用により不要・M8/M-N6 解決）。

`src/root_test.zig` へ `_ = @import("filter.zig");` を追加（MINOR4・追加忘れるとテストが走らない・AGENTS.md「テストの仕組み」）。

### 1.2 `Model` への新フィールド（B1 snapshot_tip 一本化 / B2 graph policy / フィルタ UI 状態）

`src/model.zig` の `Model` 構造体（現状 `src/model.zig:23-66`）へ追加・変更:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `filter_state` | `FilterSpec` | persistent 所有 | 現在有効なフィルタ。`isEmpty` で「無し」 |
| `filter_modal_open` | `bool` | — | モーダル表示状態。input/view/main が参照 |
| `log_load_error` | `[]u8` | persistent 所有・`setStr` で管理 | B4/M3: 初回 log 取得失敗の error_text（空 = エラー無し）。空結果 `log_has_more=false` とは区別（MINOR1） |
| `log_snapshot_tip` | `?[]u8` | persistent 所有 | ★B1/M-N7 解決: snapshot tip（HEAD hash）。初回 LoadLog 実行時に appcmd が `git rev-parse --verify HEAD` で取得し、`LogLoaded.request_tip` へ格納。reducer は初回成功時に dupe 保存。LoadLogPage は Model の snapshot_tip を dupe して `<snapshot_tip>` へ。paging 間で同一 snapshot を保証。filter 変更 / toggle / refresh / bad revision recovery / 初回失敗でクリア（次回 LoadLog で再解決） |
| `graph_render_policy` | `enum { auto, suppressed }` | — | ★B2: graph 表示ポリシー。`.auto`=通常（log_graph_state==.valid で表示）, `.suppressed`=フィルタ中（graph 計算をスキップ・renderLog で graph 列を表示しない）。`apply_filter` arm で `.suppressed` へ、`clear_filter` arm で `.auto` + `invalidateLogGraph` へ |

**`log_paging_tip`（phase2・`src/model.zig:65`）は廃止**:

| 廃止 field | 理由 |
|---|---|
| `log_paging_tip` | M-N7/race 回避のため `log_snapshot_tip` へ一本化（codex rev.2 指摘1）。phase2 では `items[0].hash` から設定していたが、フィルタ後の先頭は HEAD とは限らない（B1）。`log_snapshot_tip` は `git rev-parse --verify HEAD` で取得・フィルタと独立。両者の二重管理でずれが生じるリスクを排除 |

**phase2 からの移行**（実装ステップ）:
1. `log_paging_tip` フィールド・`setLogPagingTip`/`clearLogPagingTip` ヘルパを削除。
2. `handleLogLoaded`（`src/update.zig:578-581`）で `setLogPagingTip(items[0].hash)` していた箇所を `setLogSnapshotTip(ll.request_tip)`（appcmd が解決した HEAD hash）へ置換。
3. `handleLogPageLoaded`（`src/update.zig:606-611`）の stale-reject `request_tip==log_paging_tip` を `request_tip==log_snapshot_tip` へ置換。
4. `handleRequestRefreshLog`/`handleToggleViewMode`/`git_error`(log) の `clearLogPagingTip` を `clearLogSnapshotTip` へ置換。
5. phase2 テスト（`src/model.zig` 該当 test block）を `log_snapshot_tip` へ更新。

**`Model.init`（`src/model.zig:67`）へ追加**: `.filter_state = FilterSpec.init(), .filter_modal_open = false, .log_load_error = try a.dupe(u8, ""), .log_snapshot_tip = null, .graph_render_policy = .auto`。

**`Model.deinit`（`src/model.zig:113`）へ追加**: `self.filter_state.deinit(a); a.free(self.log_load_error); if (self.log_snapshot_tip) |t| a.free(t);`。

**ヘルパ関数（H6/R1 と同型・deep-copy → swap・トランザクショナル・実装コードは書かない）**:
- `setFilterState(new_spec)`: 旧 filter_state を deinit して swap（new_spec の所有権を移譲・消費側は触らない）。
- `clearFilterState()`: deinit + `FilterSpec.init()`。
- `setLogSnapshotTip(hash)`: 旧を free して dup（`setStr` と同型・OOM で self 不変）。
- `clearLogSnapshotTip()`: free して null。
- `setLogLoadError(text)`: `setStr(&log_load_error, text)` と同型。空文字でクリア相当。

> **`filter_draft`（rev.2 に存在）は廃止**（M-N7 解決）。reducer は `Msg.apply_filter: []u8` の payload から直接 FilterSpec を構築する（§3.1/§4.4）。main は都度同期せず、Enter 押下時のみ payload を構築する。

### 1.3 graph 表示ポリティクス（B2 対策の核心）

`.invalid` を「意図的に無効」と兼用しない（B2）。明示的な `graph_render_policy` を見る:

- `handleLogLoaded`/`handleLogPageLoaded`（`src/update.zig:548,599`）で **`graph_render_policy == .suppressed` のとき graph 計算をスキップ**（`log_graph_state` は触らない・`.invalid` のままで可）。これにより「非空 loaded 受領時に即 `computeAll` される」`src/update.zig:582-590` の挙動を回避。
- `renderLog`（`src/view.zig:434`）は `graph_render_policy == .auto and log_graph_state == .valid` で graph 表示。現状の `show_graph = pane_w >= 30 and model.log_graph_state == .valid`（`src/view.zig:447`）へ `and model.graph_render_policy == .auto` を追加。
- `apply_filter` arm で `.suppressed` へ、`clear_filter` arm で `.auto` + `invalidateLogGraph()` へ（§4.4/4.6）。

### 1.4 `log_snapshot_tip` の役割（phase2 `log_paging_tip` から一本化）

| 取得元 | 用途 | クリアタイミング |
|---|---|---|
| appcmd が `git rev-parse --verify HEAD` で取得（`headState` tri-state の `.ok` 時）・**フィルタとは独立** | 初回・追加ページで同じ snapshot を保証。フィルタ後の先頭 commit が HEAD と限らない問題を回避（B1） | filter 変更 / toggle / refresh / bad-rev / 初回失敗 |

**race 回避の仕組み**（codex rev.2 指摘1）: `git rev-parse --verify HEAD` と `git log` を別プロセスで実行すると間に HEAD が動く。revision を `<snapshot_tip>` へ明示限定（`git log --skip=0 --max-count=100 <snapshot_tip> <filter>` 形式）すれば、rev-parse 後に HEAD が動いても log は snapshot_tip 到達可能集合を返すので一貫性が保たれる。

### 1.5 `zz.TextInput` / `zz.Modal` の実 API（codex M7・実ソース読込済み）

> **api-notes（`docs/superpowers/plans/zigzag-api-notes.md` L266-267,278）へ追記する内容**（§15 に全文掲載）。

実読込元:
- `zig-pkg/zigzag-0.1.2-YXwYS17aEQBlpxPETTrhY5leFh7vV0DpnXJbHogs4Lsv/src/components/text_input.zig`
- `zig-pkg/zigzag-0.1.2-YXwYS17aEQBlpxPETTrhY5leFh7vV0DpnXJbHogs4Lsv/src/components/modal.zig`

#### `zz.TextInput`（`text_input.zig:10-462`）— field/signature のみ

| field / signature | 意味 |
|---|---|
| `value: std.array_list.Managed(u8)` | 内部コンテンツ（Managed・アプリ側は unmanaged を使うのと対照） |
| `cursor: usize` | カーソル位置 |
| `placeholder: []const u8` | `setPlaceholder(text)` で設定 |
| `prompt: []const u8` | `setPrompt(text)` |
| `width: ?u16` | `setWidth(w)` |
| `char_limit: ?usize` | `setCharLimit(n)` ★phase 3a で 256 へ（`max_author_runes` と整合・m-N2） |
| `echo_mode: EchoMode` | `.normal`/`.password`/`.none` |
| `focused: bool` | `focus()`/`blur()` |
| `suggestions: []const []const u8` | `setSuggestions(list)`・phase 3a では未使用 |
| `pub const EchoMode = enum { normal, password, none }` | — |
| `init(allocator) TextInput` | 非失敗（L48）。`persistent_allocator` を渡す |
| `deinit() void` | L94 |
| `setValue(text) !void` | 全置換 |
| `getValue() []const u8` | ★重要: TextArea とは異なり **borrowed**（呼出側 free 不要）。内部 value.items への借用 slice |
| `setPlaceholder(text) void` / `setPrompt(text) void` / `setWidth(w) void` / `setCharLimit(n) void` / `setEchoMode(mode) void` | — |
| `focus() void` / `blur() void` | — |
| `handleKey(key) void` | Ctrl+a/e/k/u/w, Alt+arrow, 文字/BS/Del/左右/Home/End/tab を処理。★`enter`/`escape` は処理しない（`else => {}`）。よってアプリ側で Enter/Esc を先に横取りして Msg 化し、それ以外を `TextInput.handleKey` へ委譲する設計が成立（§7.1） |
| `view(allocator) ![]const u8` | 描画文字列（呼出側 = フレーム arena 想定）。cursor 位置に reverse ハイライト |

> ⚠️ api-notes L266-267 の「`zz.TextInput`。単一行版。MVP では未使用想定だが存在する」を本節の実シグネチャへ全面置換（§15）。

#### `zz.Modal`（`modal.zig:52-761`）— field/signature のみ

| field / signature | 意味 |
|---|---|
| `visible: bool = false` | `show()`/`hide()`/`isVisible()` |
| `focused: bool = false` | `focus()`/`blur()` |
| `result: ?Result = null` | `getResult()`・button_pressed/dismissed |
| `title: []const u8 = ""` | — |
| `body: []const u8 = ""` | ★TextInput の `view()` 結果をここへ設定して body 化 |
| `footer: ?[]const u8 = null` | — |
| `buttons: [max_buttons]?Button` | `addButton(label, shortcut)` |
| `button_count: usize = 0` | ★phase 3a では 0（button 追加せず・§7.1 でアプリ側が Enter/Esc を横取り） |
| `selected_button: usize = 0` | — |
| `width: Size = .{ .percent = 0.5 }` | fixed/percent/auto |
| `height: Size = .auto` | — |
| `h_position: f32 = 0.5` / `v_position: f32 = 0.5` | 中央 |
| `padding: Padding` | — |
| `close_on_escape: bool = true` | — |
| `border_chars: border_mod.BorderChars = .rounded` | — |
| `border_fg: Color = .gray(18)` | — |
| `backdrop: ?Backdrop = null` | Backdrop.dark 等 |
| `pub const Result = union(enum) { button_pressed: usize, dismissed: void }` | — |
| `pub const Button = struct { label: []const u8, shortcut: ?keys.Key = null }` | — |
| `pub const Size = union(enum) { fixed: u16, percent: f32, auto: void }` | — |
| `pub const Backdrop = struct { char: []const u8 = " ", style: style_mod.Style, ... }` | — |
| `info(title, body) Modal` / `confirm(title, body) Modal` / `warning(title, body) Modal` / `err(title, body) Modal` | Presets（L190-L227） |
| `init() Modal` | blank（L239・phase 3a はこれを使用） |
| `addButton(label, shortcut) void` | L246 |
| `show() void` / `hide() void` / `isVisible() bool` / `getResult() ?Result` / `reset() void` / `focus() void` / `blur() void` | L265-L288 |
| `handleKey(key) void` | button shortcut 一致 → result.button_pressed + visible=false / escape → result.dismissed + visible=false（close_on_escape 時）/ enter → result.button_pressed=selected_button + visible=false / tab,left,right → button 選択移動。★button_count==0 なら enter は no-op（L332）。フィルタ TextInput を body に置き Enter/Esc をアプリで制御したい場合は **Modal.handleKey に渡す前にアプリ側で横取り**（phase 3a では Modal へ渡さない・§7.1） |
| `view(allocator, term_width, term_height) ![]const u8` | 中央 box のみ・透明 canvas（背面が透ける） |
| `viewWithBackdrop(allocator, term_width, term_height) ![]const u8` | ★重要（m-N5）: **全面 canvas**（solid backdrop + box）。透過しない。MINOR5: 既存 render 文字列との単純 join は overlay にならない。modal 表示中は base view を返さず viewWithBackdrop を返す（§8） |
| `renderBox(allocator, term_width, term_height) ![]const u8` | box のみ（backdrop/配置無し） |

> ⚠️ api-notes L278 の「`Modal` 等の既製コンポーネント多数」を本節の実シグネチャへ拡充（§15）。

---

## 2. 作者フィルタの意味論（codex M8 / M-N6 解決）

`git log --author=<pattern>` は **regex** で、name/email 双方が対象（`git-log(1)`, `gitrevisions(7)`）。ユーザが `[` 等を入れると git error になり、大小文字も区別される（既定）。

phase 3a の仕様（プロダクト判断・§19 で覆可能）:

- **方式**: `git log --fixed-strings --author=<ユーザ入力そのまま>`（M8/M-N6 解決）。`--fixed-strings` で regex 解釈を無効化し literal match へ。**rev.2 の `escapeRegexLiteral` は廃止**（バグりやすい自前 escape を排除）。
- **`--fixed-strings` の副作用**: `--grep` 等にも影響するが、phase3a は `--author` のみなので副作用なし（phase 3b で --grep を追加する場合は再検証）。
- **大小文字区別**: あり（git 既定・仕様化）。case insensitive は phase 3b 以降のオプション（`--regexp-ignore-case` 追加・将来）。
- **name/email**: git が双方を対象（仕様化・ユーザへ README 明記）。
- **空文字**: `FilterSpec.isEmpty()`==true となり argv へ `--author` を追加しない（既存 logArgv と完全互換）。
- **長さ上限**: `FilterSpec.max_author_runes = 256`（Unicode scalar 数・m-N2）。超過は `setAuthor` が `error.AuthorTooLong`。`TextInput.setCharLimit(256)` と整合するため UI 側で入力段階で弾かれ、apply 時に弾かれることは稀（二重防御）。
- **UTF-8**: 作者名は多バイト可（`--fixed-strings` はバイト列比較のため UTF-8 を壊さない・§14 でテスト）。
- **空白**: 含めてよい（`Foo Bar` で name 部分一致）。ただし先頭末尾の空白はユーザ責任（trim しない・仕様化）。
- **invalid 入力**: literal なので起きない（`[` 等もそのまま文字として扱われる・rev.2 の invalid regex test は `--fixed-strings` 仕様と矛盾するため §14 で削除）。

---

## 3. Msg & AppCmd changes（messages.zig）

### 3.1 新入力 Msg（M-N7 解決: apply_filter payload 化）

`Msg`（`src/messages.zig:8`）へ追加:

| tag | payload | 意味 |
|---|---|---|
| `open_filter_modal` | 無し | `f`（log モード・focus==.changes） |
| `close_filter_modal` | 無し | Esc（モーダル中） |
| `apply_filter` | `[]u8`（所有・**main が `TextInput.getValue()` を dupe して送る**・Msg consumer が free） | Enter（モーダル中）。M-N7 解決: `filter_draft` 廃止・TextInput が唯一の編集正本・同期 OOM 握り潰し問題を排除 |
| `clear_filter` | 無し | `F`（shift・log モード・focus==.changes） |

> **rev.2 との差分**: rev.2 は `apply_filter` を payload 無し + `model.filter_draft`（persistent 所有）へ依存していた。main がモーダル中の TextInput 変更を都度同期（`syncFilterDraft` が `setStr catch {}` で OOM を握る）する設計で、Enter で古い draft が適用されるバグがあった（M-N7）。rev.3 は `apply_filter: []u8` payload へ変更し、`filter_draft` / `setFilterDraft` / `clearFilterDraft` / `syncFilterDraft` を全て廃止。

`Msg.deinit` switch（`src/messages.zig:90-168`）へ追加:
- `.apply_filter => |text| a.free(text),`（payload を free）。
- `.open_filter_modal` / `.close_filter_modal` / `.clear_filter` は `=> {}`（payload 無し）。

### 3.2 結果系 Msg の拡張（B1/B4/M3/m-N1）

`Msg`（`src/messages.zig:49-52`）へ追加・変更:

| tag | 変更 | payload |
|---|---|---|
| `log_loaded: LogLoaded` | 拡張: `request_tip` / `is_unborn` 追加 | 下記構造体 |
| `log_load_failed: LogLoadFailed` | ★新設（B4/M3）: 初回 load_log 失敗専用 | 下記構造体 |
| `log_load_failed_silent: LogLoadFailedSilent` | ★新設（codex rev.2 指摘4）: OOM 極限用・payload 無し | 下記構造体 |
| `log_page_loaded: LogPageLoaded` | 既存のまま（但し stale-reject で `log_snapshot_tip` と照合・§4.2） | 変更無し |
| `log_page_failed: LogPageFailed` | 既存のまま | 変更無し |
| `log_page_failed_silent: LogPageFailedSilent` | 既存のまま | 変更無し |

**`LogLoaded` 構造体の field 定義**:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `request_skip` | `usize` | — | 既存 |
| `request_max_count` | `usize` | — | 既存 |
| `request_generation` | `u64` | — | 既存 |
| `request_tip` | `[]u8` | 所有・消費者が deinit | ★B1 追加: appcmd が解決した HEAD hash。unborn HEAD のときは長さ 0 の所有 slice（空文字・m-N1） |
| `is_unborn` | `bool` | — | ★m-N1 追加: appcmd が headState tri-state で判定。view は `is_unborn` で `(no commits)` / filter 空一致で `(no matching commits)` を切り分け |
| `entries` | `[]log.Commit` | 所有 | 既存 |

**`LogLoadFailed` 構造体の field 定義**（★B4/M3）:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `request_generation` | `u64` | — | stale reject 用 |
| `request_tip` | `?[]u8` | 所有 | null = snapshot_tip 解決前失敗（headState spawn OOM 等） |
| `error_text` | `[]u8` | 所有 | ユーザへ表示するエラー文 |

**`LogLoadFailedSilent` 構造体の field 定義**（codex rev.2 指摘4）:

| field | 型 | 意味 |
|---|---|---|
| `request_generation` | `u64` | stale reject 用 |

> OOM 極限で `error_text` の dupe すら失敗する場合に `LogLoadFailedSilent` を使う（`log_page_failed_silent` と同型・payload 無しで reducer は generation 照合のみ）。

`Msg.deinit` switch（`src/messages.zig:90-168`）へ追加:
- `.log_loaded` に `a.free(ll.request_tip);` を追加（既存の entries 解放と併存）。
- `.log_load_failed` arm を新設: `a.free(llf.error_text); if (llf.request_tip) |t| a.free(t);`。
- `.log_load_failed_silent` arm を新設: `=> {}`（payload 無し）。

### 3.3 AppCmd の拡張（D1）

`AppCmd`（`src/messages.zig:180-184`）へ変更:

| tag | 変更 | payload |
|---|---|---|
| `load_log: LoadLog` | 拡張: `filter` 追加 | 下記 |
| `load_log_page: LoadLogPage` | 拡張: `filter` 追加 | 下記 |

**`LoadLog` 構造体の field 定義**:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `skip` | `usize` | — | 既存 |
| `max_count` | `usize` | — | 既存 |
| `generation` | `u64` | — | 既存 |
| `filter` | `FilterSpec` | 所有コピー | ★D1 追加: `isEmpty` なら argv へ `--author` を追加しない |

**`LoadLogPage` 構造体の field 定義**:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `skip` | `usize` | — | 既存 |
| `max_count` | `usize` | — | 既存 |
| `generation` | `u64` | — | 既存 |
| `tip_hash` | `[]u8` | 所有 | 既存（= `log_snapshot_tip` の dupe） |
| `filter` | `FilterSpec` | 所有コピー | ★D1 追加 |

`AppCmd.deinit` switch（`src/messages.zig:202-235`）へ追加:
- `.load_log` へ `cmd.load_log.filter.deinit(a);`（phase 2 は `=> {}` だったため所有 payload 追加に伴い arm を独立化）。
- `.load_log_page` へ `cmd.load_log_page.filter.deinit(a);` を追加（既存の `a.free(llp.tip_hash);` と併存）。

---

## 4. Reducer changes（update.zig）

> **記述形式**: 各 arm を番号付きステップで記述（コード block 無し・実装コードは plan/実装フェーズへ委ねる）。

### 4.1 `handleLogLoaded`（B1/B2/M-N8・`src/update.zig:548` 拡張）

1. **stale reject（既存）**: `inLogMode` / `request_generation==log_request_generation` / `request_skip==0`。不一致は `Msg.deinit` して `.none`。※ B1: `request_tip` はこの時点では model 側に対応物が無い（初回確定前）ので照合しない。snapshot_tip は本 arm 内で `ll.request_tip` から設定する（下記 3）。
2. `replaceLogCommits(ll.entries)`。
3. **★B1**: `log_snapshot_tip` を `ll.request_tip` から dupe 保存（`setLogSnapshotTip`）。OOM は安全側へ `clearLogSnapshotTip` して継続（旧 `setLogPagingTip` と同型・`src/update.zig:578-581`）。
4. **★B2**: `graph_render_policy==.suppressed` なら graph 計算をスキップ（`handleLogPageLoaded` も同様）。`.auto` なら phase 2 どおり `graph.computeAll`。
5. **★M-N8**: `setStr(&model.log_load_error, "")` で前回エラーをクリア（commits 更新と同一トランザクション）。
6. R4 restore hash / `log_has_more`（M3: `entries.len >= request_max_count`）/ `log_page_requested=null` / `detail_kind=.files`。
7. R2 空 guard（`log_commits.items.len==0` なら `clearDetailOwner` + `replaceDetailFiles(&.{})` + `.none`）。
8. **★MINOR1/m-N1**: 空結果のとき `log_load_error` は触らない（空結果 != エラー）。view は `log_has_more=false` + `log_commits.items.len==0` + `is_unborn` で表示切り分け（§8.3）。
9. `setDetailOwnerHash` + `return .{ .load_commit_detail = dupe(hash) }`。

### 4.2 `handleLogPageLoaded`（B2・`src/update.zig:599` 拡張）

1. **stale reject（既存 + H-07）**: `inLogMode` / `request_generation` / `request_skip==log_page_requested`。
2. **★B1**: `request_tip` を `log_snapshot_tip` と照合（一致必須・不一致は stale reject）。※ phase 2 では `log_paging_tip` のみだったが、phase 3a では一本化済みの `log_snapshot_tip` へ。
3. **★R22**: `log_page_requested=null` を `appendLogCommits` の前に。
4. `appendLogCommits(lpl.entries)`。
5. `log_has_more` 設定（M3: `entries.len >= request_max_count`）。
6. **★B2**: `graph_render_policy==.suppressed` なら graph 計算スキップ。`.auto` なら phase 2 M-11 switch（`.valid`→incremental / `.invalid`→computeAll）。
7. R10: 選択が存在すれば `load_commit_detail` で整合性回復。

### 4.3 `handleLogLoadFailed` / `handleLogLoadFailedSilent`（★新設・B4/M3）

**`handleLogLoadFailed(model, llf)`**:

1. **stale reject**: `inLogMode` / `request_generation==log_request_generation`。不一致は deinit して `.none`。
2. **★B4**: `setStr(&model.log_load_error, llf.error_text)`（空結果とは区別）。
3. `log_page_requested=null`（念のため）。
4. `replaceLogCommits(&.{})`・`clearDetailOwner`・`replaceDetailFiles(&.{})`・`setStr(&detail_diff, "")`。
5. **★B1**: snapshot_tip は `llf.request_tip` があればそれを保存（次回 page で使える可能性）。無ければ `clearLogSnapshotTip`（次回 LoadLog で再解決）。
6. `return .none`（ユーザーは filter を修正して再適用 or clear して再取得）。

**`handleLogLoadFailedSilent(model, llfs)`**: 上記 1 の stale reject のみ・2〜5 をスキップ（OOM 極限・payload 無し）。

`update` 本体 switch（`src/update.zig:340-345`）へ `.log_load_failed => |llf| return try handleLogLoadFailed(model, llf),` と `.log_load_failed_silent => |llfs| return try handleLogLoadFailedSilent(model, llfs.request_generation),` を追加。

### 4.4 `apply_filter` arm（★新設・M4/M-N7 トランザクショナル）

**入力**: `Msg.apply_filter: []u8`（payload・ユーザ入力・呼出側=main が `TextInput.getValue()` を dupe 済み）。

1. **payload から FilterSpec を1つ構築**:
   - `var new_spec = FilterSpec.init()` → `errdefer new_spec.deinit(a)`。
   - `new_spec.setAuthor(a, payload)`（空文字は null 化・`max_author_runes` チェック・`error.AuthorTooLong` は reducer が `error_text` へ変換して `.none`・Model 不変）。
2. **Model 用へ swap**（強例外保証・CLAUDE.md:55-57 / `src/update.zig:446-472` payload-first 規約）:
   - `model.setFilterState(new_spec)`（`new_spec` の所有権を Model へ移譲・`setFilterState` 内で旧 filter_state を deinit）。※ この時点で `new_spec` は触ってはいけない（所有権移譲済み）。
3. **AppCmd 用は swap 後の model.filter_state から clone**:
   - `const cmd_spec = try model.filter_state.clone(a)` → `errdefer cmd_spec.deinit(a)`。
   - ※ swap 後に clone するため、Model と AppCmd が常に一致。clone 失敗時は model.filter_state を空へ戻す（`clearFilterState`）ことで強例外保証（旧 filter_state は swap 時に失われているため復元不可だが、空 filter で再取得すれば UI は一貫・§17 Risks 参照照）。
4. **成功後の Model 更新**（payload-first の commit phase・全て非失敗操作）:
   - `model.filter_modal_open = false`（モーダルを閉じる）。
   - `model.log_request_generation += 1`（★R3/M3: 旧結果を stale 化）。
   - `model.log_page_requested = null`。
   - `model.log_has_more = false`。
   - `model.clearLogSnapshotTip()`（★B1: 次 LoadLog で再解決）。
   - `model.graph_render_policy = .suppressed`（★B2）。
   - `model.invalidateLogGraph()`（既存 graph を破棄）。
   - `model.clearDetailOwner()` / `model.replaceDetailFiles(&.{})` / `model.setStr(&model.detail_diff, "")`。
   - `model.setStr(&model.log_load_error, "")`（前回エラーをクリア）。
   - `model.replaceLogCommits(&.{})`（一旦空へ）。
5. **AppCmd 構築**（cmd_spec を move）:
   - `return .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = model.log_request_generation, .filter = cmd_spec } }`。

**失敗時**:
- 1 の `setAuthor` OOM: `new_spec.deinit(a)`（errdefer）→ Model 不変・`.none`（`setStr(&log_load_error, "フィルタ適用に失敗（メモリ不足）")` してユーザへ通知）。
- 1 の `error.AuthorTooLong`: Model 不変・`setStr(&log_load_error, "作者名が長すぎます（256 Unicode scalar まで）")` → `.none`。
- 3 の clone OOM: `cmd_spec.deinit(a)`（errdefer）+ `model.clearFilterState()`（強例外保証・空 filter へ戻す）→ `.none`（`setStr(&log_load_error, ...)`）。

> **rev.2 との差分**: rev.2 は FilterSpec clone を3つ（new_spec/model_spec/cmd_spec）確保する手順だったが、所有権破綻していた（codex rev.2 指摘2）。rev.3 は「payload → FilterSpec 1つ → Model へ swap → swap 後から clone」の順で clone 数を最小化。`checkAllAllocationFailures` は 1/3 の各 dupe 失敗を検証（但し 3 の回復は `clearFilterState` で Model を変えるため m-N3 に従い FailingAllocator の特定 fail index テストへ・§14）。

### 4.5 共通 `buildLoadLogCmd` builder（★新設・M5 伝播漏れ防止）

`src/update.zig` 内のプライベートヘルパ（実装コードは書かない・ステップで）:

1. `model.filter_state.clone(a)` → `errdefer deinit`。
2. `return .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = model.log_request_generation, .filter = <clone> } }`。

**全 `load_log` 発火 site（spec 明示・テストで網羅・M5）**:

| site | 現状コード | phase 3a 変更 |
|---|---|---|
| `handleToggleViewMode`（changes→log） | `src/update.zig:383-387` | generation+=1 → `clearLogSnapshotTip` → `return try buildLoadLogCmd(model);` |
| `handleRequestRefreshLog`（`r`・log 中） | `src/update.zig:519-523` | generation+=1 → `clearLogSnapshotTip` → `buildLoadLogCmd`（★filter 保持） |
| `git_error`（log 中・bad revision recovery） | `src/update.zig:269-273` | **廃止**（M3・§4.8 で detail 系のみへ）。bad revision 回復は `LogPageFailed` arm 側で `clearLogSnapshotTip` + 次 down で再試行、またはユーザーの `r`（`handleRequestRefreshLog` 経由・filter 保持）で回復 |
| `apply_filter`（★新設） | §4.4 | payload-first で filter clone 済み・直接 `load_log` 構築（builder を経由しないが filter は明示的に渡す・テストで担保） |
| `clear_filter`（★新設・§4.6） | — | generation+=1 → `clearFilterState` → `clearLogSnapshotTip` → `buildLoadLogCmd`（filter は isEmpty） |

> `apply_filter` だけは builder を経由しない（payload-first で既に clone 済みの cmd_spec を使うため）。それ以外は全て builder 経由で filter を `model.filter_state` から取得するので伝播漏れが起きない。コンパイラで検知できないため site 一覧をテストで網羅（§14）。

### 4.6 `clear_filter` arm（★新設）

1. `model.clearFilterState()`。
2. `model.filter_modal_open = false`。
3. `model.log_request_generation += 1`。
4. `model.log_page_requested = null`。
5. `model.log_has_more = false`。
6. `model.clearLogSnapshotTip()`。
7. `model.graph_render_policy = .auto`（★B2: graph 復活）。
8. `model.invalidateLogGraph()`（次回 log_loaded で computeAll）。
9. `model.clearDetailOwner()` / `replaceDetailFiles(&.{})` / `setStr(&detail_diff, "")`。
10. `model.setStr(&log_load_error, "")`。
11. `model.replaceLogCommits(&.{})`。
12. `return try buildLoadLogCmd(model);`（filter は isEmpty・全件再取得）。

### 4.7 `open_filter_modal` / `close_filter_modal` arms（★新設）

**`handleOpenFilterModal(model)`**:
- log モード限定（input 側で保証・changes モードで呼ばれない）。
- `model.filter_modal_open = true`。
- ※ reducer は TextInput へ触れない（App 側所有）。main が `filter_modal_open` の遷移を検知して `filter_textinput.setValue(<現 filter_state.author or "">)` を呼ぶ（§9.3・`committed` 時の `textarea.setValue("")` `src/main.zig:324` と同パターン）。
- `return .none`。

**`handleCloseFilterModal(model)`**:
- `model.filter_modal_open = false`。
- `return .none`（TextInput の内容は破棄・`filter_draft` は存在しないため触らない）。

### 4.8 `git_error`（log 中）の filter 保持 → detail 系のみへ縮小（MINOR2/M3/M-N9）

**M-N9 最小対処**: detail 系（show 失敗等）の `git_error` に owner hash（`detail_owner_hash` 相当）を持たせ、reducer で現在の owner と一致しなければ破棄（busy を下ろさない）。これは既存の `handleCommitDetailLoaded`/`handleDetailDiffLoaded`（`src/update.zig:672-689`）の stale-reject と同型。

> 現状 `Msg.git_error: []u8` は owner hash を持たない。これを構造体化（`git_error: GitError{ owner_hash: ?[]u8, text: []u8 }`）するか、detail 系のみ新しい failure Msg（`DetailFailed` 等）へ分離するかは実装で判断。phase 3a では**最小対処として現状の `git_error` を流用し、reducer 側で `detail_owner_hash` の有無で振り分け**（log 中の `git_error` は全て detail 系と仮定・`busy=false` は維持）。

**busy の完全修正**: runtime lifecycle のみで busy を管理（reducer で `busy=true/false` を触らない）する方針は §18 将来課題（M-N9）。

**`git_error` arm 変更（`src/update.zig:253-273`）**:

1. **stale reject（M-N9 最小対処）**: detail 系 `git_error` の場合、現在の `detail_owner_hash`（または `detail_diff_owner_hash`）と一致しなければ破棄。※ `Msg.git_error` が owner hash を持たない現状では、log 中の `git_error` は「最後に発行した detail 系の失敗」と仮定して受理するか、または構造体化が必要。phase 3a では**log 中の `git_error` を全て無視（`.none`）するのが安全**（detail 系 stale 結果は `detail_owner_hash` 照合で別途弾かれる）。
2. `model.busy = false`（detail 系失敗で busy を下ろす・但し上記 1 で stale なら触らない）。
3. `setStr(&model.error_text, err_text)`。
4. `return .none`。

> **phase 2 からの変更点**: phase 2 は `view_mode==.log` の `git_error` で `load_log` を発火していた（bad revision recovery・`src/update.zig:269-273`）。phase 3a では bad revision を `LogPageFailed`（§6.2）へ変更したため、`git_error` は detail 系のみとなり `load_log` 発火を廃止。filter 保持の必要も消失（`LogPageFailed` arm 側で `clearLogSnapshotTip` + 次 down で再試行・filter は `model.filter_state` に残る）。

### 4.9 stale-reject 拡張（M3）

`LogLoaded`/`LogLoadFailed`/`LogLoadFailedSilent` の generation 照合を追加（§4.1/4.3）。フィルタ変更後の旧結果（成功・失敗とも）を破棄。

---

## 5. commands.zig changes（M8/M11/D1/M-N6）

### 5.1 `escapeRegexLiteral` は廃止（M-N6 解決）

rev.2 に存在した `escapeRegexLiteral` は **rev.3 では廃止**。`--fixed-strings` 採用により regex escape が不要（§2）。テストも削除（rev.2 の「各 metachar escape」テストは不要）。

### 5.2 `logArgv` / `logPageArgv` へ filter 引数追加と snapshot_tip 明示（D1/M11/B1）

**方針のみ（実装コードは書かない）**:

- `logArgv(a, skip, max_count, snapshot_tip: ?[]const u8, filter: FilterSpec) !OwnedArgv`（★引数追加: `snapshot_tip` と `filter`）。
- `logPageArgv(a, skip, max_count, snapshot_tip: []const u8, filter: FilterSpec) !OwnedArgv`（★引数追加: `filter`・`snapshot_tip` は必須）。
- **★B1 一本化**: `logArgv` も `logPageArgv` と同様に `<snapshot_tip>` を argv 末尾へ明示限定（初回 query も同じ tip・race 回避）。
- **★M8**: `filter.isEmpty()` なら argv 変更なし（既存テスト完全互換）。author ありなら `--fixed-strings` と `--author=<ユーザ入力そのまま>` を argv へ追加（escape 不要・M-N6）。
- argv 形式: `["git", "-c", "core.quotePath=false", "log", "--topo-order", ("--skip=N"), "--max-count=N", "--pretty=format:...", "-z", "--decorate=short", "--no-color", ("--fixed-strings", "--author=<literal>"), "<snapshot_tip>"]`（`--fixed-strings` と `--author` は filter.author が非空のときのみ追加・順序は git log が解釈できる位置）。

**`OwnedArgv` 構造体の field 定義（M11）**:

| field | 型 | 所有権 | 意味 |
|---|---|---|---|
| `args` | `[]const []const u8` | 所有（`toOwnedSlice`） | `process.run` へ渡す argv |
| `owned` | `std.ArrayList([]const u8)` | 所有 | 動的確保した文字列のみ（free 対象） |

**OwnedArgv の方針（M11/M-N6 解決・実装コードは書かない）**:
- **動的確保（`allocPrint` 系）のみを `owned` リストへ追跡**。
- **各確保直後に `errdefer` で rollback**（`owned` へ append する前・順序厳守）。
- **借用（`snapshot_tip` / path 等）は `owned` へ入れず free しない**（呼出側所有・`LoadLogPage.tip_hash` 等）。
- **`args` slice 自体は `toOwnedSlice` なので `deinit` で free**。
- `deinit(a)`: `for (owned.items) |s| a.free(s); owned.deinit(a); a.free(args);`。

> 既存 `logArgv`/`logPageArgv` テスト（`src/git/commands.zig:341-443`）は引数追加に伴い `snapshot_tip=null` / `filter=FilterSpec.init()`（isEmpty）を渡すよう更新。argv 内容は isEmpty 時に変わらないことを検証（回帰保護）。`freeLogArgv`/`freeLogPageArgv`（`src/appcmd.zig:265-284`）は `OwnedArgv.deinit` へ置換。

### 5.3 `revParseHeadArgv` / `revParseHead`（★B1）

**方針のみ**:
- `revParseHeadArgv() []const []const u8`: `&.{ "git", "rev-parse", "--verify", "HEAD" }`。
- `revParseHead(a, io, cwd) !?[]u8`: 既存 `headState`（`src/git/commands.zig:193-218`）と協調。`headState` が `.ok` を返したときだけ呼ぶ（`.unborn`/`.err` は snapshot_tip 解決不要）。stdout を trim して HEAD hash を dupe。
- 実装は既存 `headState` 内部で hash も返すよう拡張（コマンド呼び出しを節約）してもよいが、`headState` の呼出元（`runLogInt` 等）への影響を最小化するため分離（責務明確化）。

---

## 6. AppCmd interpreter changes（appcmd.zig・B1/B4/M3/MINOR7）

### 6.1 `runLogInt` 拡張（B1/B4/M3/m-N1）

**ステップ**（実装コードは書かない）:

1. `headState(a, io, cwd)` を catch（R20: spawn/OOM も `LogLoadFailed` へ・`mkLoadFailedOrSilent` ヘルパ新設・`log_page_failed` 版と同型）。
2. `switch (hs)`:
   - `.unborn`: `entries=&.{}` で `LogLoaded{request_tip=空文字 dupe, is_unborn=true, ...}` を返す（R6 互換・m-N1）。
   - `.err`: `mkLoadFailedOrSilent(a, cmd, "git リポジトリ状態が壊れています")` を `LogLoadFailed` で返す。
   - `.ok`: 下へ。
3. **★B1**: `revParseHead(a, io, cwd)` で HEAD hash を取得。
   - 失敗（exit 128 等）: `LogLoadFailed{request_generation, request_tip=null, error_text="HEAD 解決失敗"}`。
   - 成功: `tip = 取得した hash`。
4. `logArgv(a, cmd.skip, cmd.max_count, tip, cmd.filter)`（★`snapshot_tip` 明示 + `filter` 追加）→ `OwnedArgv`。
5. `process.run(a, io, owned.args, cwd)` を catch（R7/MINOR7: `StreamTooLong` 含む `RunError` を `LogLoadFailed` へ）。
6. `exit_code != 0`:
   - **★B4**: `LogLoadFailed{request_generation, request_tip=dupe(tip), error_text=dupe(stderr)}` を返す（phase 2 は `log_page_failed` だったが phase 3a は `LogLoadFailed`・初回失敗を区別）。
7. `log.parse(a, stdout)` を catch → `LogLoadFailed`。
8. `LogLoaded{request_skip, request_max_count, request_generation, request_tip=dupe(tip), is_unborn=false, entries}`。

**`mkLoadFailedOrSilent` / `mkLoadFailedSilent`**（phase 2 の page 版 `src/appcmd.zig:199-207` と同型・`LogLoadFailed` 用を新設）:
- `mkLoadFailedOrSilent(a, cmd, prefix)`: `error_text = a.dupe(prefix) catch return mkLoadFailedSilent(cmd)`。
- `mkLoadFailedSilent(cmd)`: OOM 極限・`LogLoadFailedSilent{request_generation}`（payload 無し）。

### 6.2 `runLogPageInt` 拡張（M3/MINOR2/MINOR7）

**ステップ**:

1. `logPageArgv(a, cmd.skip, cmd.max_count, cmd.tip_hash, cmd.filter)`（★`filter` 追加・`cmd.tip_hash` は `log_snapshot_tip` の dupe）→ `OwnedArgv`。
2. `process.run` を catch（MINOR7: `StreamTooLong` 含む）→ `LogPageFailed`。
3. `exit_code != 0`:
   - **★M3**: exit 128（bad revision: tip 期限切れ）は phase 2 は `git_error` だったが、phase 3a では **`LogPageFailed`** へ変更（M3: `git_error` で log recovery しない）。`error_text = "tip が期限切れです（履歴が移動しました）"`。
   - それ以外: `LogPageFailed{request_skip, request_generation, error_text=stderr}`。
4. `log.parse` → `LogPageLoaded{request_tip=dupe(cmd.tip_hash), entries, ...}`（phase 2 どおり）。

> **bad revision recovery**: `LogPageFailed` arm（`src/update.zig:643-656`）で `clearLogSnapshotTip` を追加（次回 LoadLog で再解決・filter 保持）。ユーザーが `r` で明示的に全 refresh してもよい（`handleRequestRefreshLog` 経由・filter 保持・MINOR2）。

### 6.3 StreamTooLong 正規化（MINOR7）

`std.process.run` の 16MiB 制限（`src/git/process.zig:37-38` の `.limited(16 * 1024 * 1024)`）で `error.StreamTooLong` が発生し得る。`process.run` の `RunError`（`src/git/process.zig:12`）に含まれるため、`runLogInt`/`runLogPageInt` の catch 範囲（`process.run(...) catch return mkLoadFailed...`）で自然に `LogLoadFailed`/`LogPageFailed` へ正規化される。追加コード不要・§14 でテスト（但し 16MiB 実データは重いので **limit 注入設計**を推奨: `process.run` の limit を引数で渡せるよう `process.zig` を拡張し、テストでは小さな limit で `StreamTooLong` を再現・m-N3/m-N4 境界）。

---

## 7. Input changes（input.zig・M6）

### 7.1 モーダル入力優先（M6 対策の核心）

`keyToMsgForMode`（`src/input.zig:158`）の**前**に modal visible 判定を置く新エントリを追加（実装コードは書かない・ステップで）:

**`keyToMsgForModeWithModal(mode, focus, detail_kind, key, filter_modal_open) ?Msg`**:

1. `filter_modal_open==true` のとき:
   - `key == .enter` → `return .apply_filter`（★但し payload `[]u8` は **main 側で構築**・input 関数は tag のみ返す・payload を input 側で作ると allocator が必要になり純粋性が崩れるため）。
     - **※設計判断**: `apply_filter` の payload を input 側で構築すると `TextInput` 参照と allocator が必要になる。input は「`Msg.apply_filter` tag のみ返す」設計とし、main が `Msg.apply_filter` 受領後に `TextInput.getValue()` を dupe して payload を付与した `Msg` を `update` へ送る。これで input の純粋性を保つ。
   - `key == .escape` → `return .close_filter_modal`。
   - それ以外のキーは `return null`（main が `TextInput.handleKey` へ委譲）。
   - `q`/`r`/`L`/`tab` 等 global mapping も抑制（null を返すことで main が TextInput へ回す）。
   - `Ctrl+U` は TextInput.handleKey が「Kill to start」を処理する（phase 3a では TextInput 既定へ任せ・`clear_filter` は `F` キーのみ・§19 Open product decisions）。
2. `filter_modal_open==false` のとき: 既存 `keyToMsgForMode(mode, focus, detail_kind, key)` へ delegating。

`keyToMsgForLog`（`src/input.zig:173`）へ `f` / `F` キーを追加:
- `focus==.changes`（log 左ペイン）のとき `c=='f'` → `.open_filter_modal`、`c=='F'` → `.clear_filter`（shift-f = clear）。

`main.handleKey`（`src/main.zig:339`）の呼出を `keyToMsgForModeWithModal` へ変更:
1. `input.keyToMsgForModeWithModal(...)` が non-null を返したとき:
   - `Msg.apply_filter` の場合: main が `app.filter_textinput.getValue()` を `app.gpa.dupe` して payload を付与した `Msg` を構築 → `step(app, program, msg)`。OOM で dupe 失敗時は `setStr(&model.log_load_error, "フィルタ適用に失敗（メモリ不足）")` 相当の Msg へ差し替え（または `Msg` を破棄してモーダルを維持）。
   - それ以外の Msg: そのまま `step`。
2. null のときの委譲先:
   - `model.filter_modal_open==true` → `app.filter_textinput.handleKey(k)`（文字/Backspace/矢印/Ctrl+a/e/k/u/w 等。Enter/Esc は 1 で処理済みのため来ない）。
   - `view_mode==.changes and focus==.commit` → 既存の `app.textarea.handleKey(k)` + `syncCommitText`（`src/main.zig:352-355`）。

> **rev.2 との差分**: rev.2 は `syncFilterDraft`（`setStr catch {}` で OOM を握る）で都度同期していた（M-N7）。rev.3 は `filter_draft` 廃止・`syncFilterDraft` 廃除。Enter 押下時のみ payload を構築。

### 7.2 mouse 抑止（M6）

`handleMouse`（`src/main.zig:358`）で `app.model.filter_modal_open==true` のとき背面 pane への routing をスキップ（モーダル外クリックは無視・デフォルト・§19）。

---

## 8. View changes（view.zig・B2/MINOR1/MINOR5/m-N5）

### 8.1 `renderLogMode` の最終段で modal 有無を分岐（MINOR5/m-N5）

**ステップ**（実装コードは書かない）:

1. 既存どおり `log` / `detail` / `status` を `fitPane` → `joinHorizontal` → `joinVertical` で `base` を構築。
2. **★m-N5**: `model.filter_modal_open==true` のとき、`base` を返さず `modal.viewWithBackdrop(a, ctx.width, ctx.height)` を返す。
   - **前提**: App 側（main.zig）が modal + filter_textinput を所有するため、view へ何らかの方法で渡す必要がある。本設計では file-scope `g_view_modal: ?*zz.Modal` / `g_view_textinput: ?*zz.TextInput`（`g_program`/`g_app` `src/main.zig:111,314` と同パターン）を main.zig が設定し、view.zig が参照。
   - **modal.body への TextInput 描画**: `modal.body = ti.view(a) catch ""`（TextInput は `ctx.allocator` フレーム arena で view・所有は arena・free 不要・M7）。
3. `filter_modal_open==false` のとき: `base` を返す。

> **設計判断（m-N5 解決）**: `viewWithBackdrop` は全面 canvas を solid backdrop で構築（透過しない）。よって modal 表示中は base view が見えない。これを**受け入ける**（簡素・確実）。オーバーレイ compositor（base を透けて見せる）は §18 将来課題。

### 8.2 graph 非表示理由表示（B2 / 新規プロダクト判断・§19）

`renderLog`（`src/view.zig:434`）と `renderStatus`（`src/view.zig:343`）へ:

- `show_graph = pane_w >= 30 and model.log_graph_state == .valid and model.graph_render_policy == .auto`（★`graph_render_policy` 追加）。
- **graph 非表示理由**: `!model.filter_state.isEmpty() and model.graph_render_policy == .suppressed` のとき、log ペイン先頭（または status bar）へ `Filter: author="<raw>" (graph hidden)` を挿入。`fitPane` 高さ調整済み（height を 1 行減らす）。※ n-N3 により「MINOR8」ID は廃止・新規プロダクト判断として §19 へ移動。
- **`log_load_error` 表示**: `model.view_mode == .log and model.log_load_error.len > 0` のとき `(error) <text>` を status bar へ（B4/M3・MINOR1）。

### 8.3 空結果 vs エラー vs unborn の表示切り分け（MINOR1/m-N1）

`renderLog` の空表示（`src/view.zig:436` の `"(no commits)"`）を状況で切り分け:

| 状態 | 表示 |
|---|---|
| `log_commits.items.len==0 and log_load_error.len>0` | `(error) <log_load_error>` |
| `log_commits.items.len==0 and filter_state.isEmpty()==false and log_load_error.len==0` | `(no matching commits)` |
| `log_commits.items.len==0 and filter_state.isEmpty()==true and log_load_error.len==0 and is_unborn==true`（最後の LogLoaded.is_unborn） | `(no commits)`（既存・unborn） |
| `log_commits.items.len==0 and filter_state.isEmpty()==true and log_load_error.len==0 and is_unborn==false`（通常時・初回ロード前等） | `(no commits)`（既存） |

> ※ `is_unborn` は `LogLoaded` の payload だが、model へ保持する必要がある（空結果と unborn の区別のため）。`Model` へ `log_is_unborn: bool` フラグを追加するか、`log_snapshot_tip` が空文字（長さ0）かで代用するかは実装で判断（m-N1）。本設計では `log_snapshot_tip` が空文字（長さ0）を unborn sentinel とする方針（所有・長さ0・null とは区別）。

### 8.4 TextInput のプレースホルダ・プロンプト

`filter_textinput` の初期化（main.zig・§9）で:
- `setPlaceholder("作者名（部分一致）")`
- `setPrompt("Filter> ")`
- `setCharLimit(FilterSpec.max_author_runes)`（256 Unicode scalar・m-N2）
- `setWidth(...)`（モーダル幅に合わせる）

---

## 9. Main changes（main.zig・M7/M12/M-N7）

### 9.1 `App` 構造体へ TextInput/Modal 追加（M7）

`src/main.zig:95-109` の `App` へ追加:

| field | 型 | 所有権 |
|---|---|---|
| `textarea` | `zz.TextArea` | 既存（commit message 用） |
| `filter_textinput` | `zz.TextInput` | ★phase 3a 追加（`persistent_allocator` で所有） |
| `filter_modal` | `zz.Modal` | ★phase 3a 追加（blank・`init()` 後に title/body 等を設定） |

`RuntimeModel.init`（`src/main.zig:258-266`）で:
- `g_app.filter_textinput = zz.TextInput.init(ctx.persistent_allocator)`
- `setPlaceholder("作者名（部分一致）")` / `setPrompt("Filter> ")` / `setCharLimit(FilterSpec.max_author_runes)`
- `g_app.filter_modal = zz.Modal.init()`
- `filter_modal.title = "Filter Commits"`
- `filter_modal.border_fg = .cyan`
- `filter_modal.width = .{ .percent = 0.5 }`
- body は毎フレーム view 側で `filter_textinput.view()` 結果を設定（§8.1）。
- **button は追加しない**（Enter/Esc をアプリ側で横取り・§7.1・button_count==0 で enter は no-op）。
- file-scope の view 参照を設定: `g_view_modal = &g_app.filter_modal; g_view_textinput = &g_app.filter_textinput;`。

`RuntimeModel.deinit`（`src/main.zig:292-308`）へ `app.filter_textinput.deinit();` を追加（`app.filter_modal` は所有ポインタを持たないため deinit 不要）。

### 9.2 modal 中のキー routing（M6/M-N7）

§7.1 の `handleKey` 拡張で実装。`filter_modal_open==true` のとき `filter_textinput.handleKey(k)` へ委譲（Enter/Esc は `keyToMsgForModeWithModal` で Msg 化済み・payload は main 側で付与）。

### 9.3 `open_filter_modal` で TextInput へ現 filter をロード

reducer は TextInput へ触れない（App 側所有）。main が `model.filter_modal_open` の遷移（false→true）を検知して `filter_textinput.setValue(<現 filter_state.author or "">)` を呼ぶ（`committed` 時の `textarea.setValue("")` `src/main.zig:324` と同パターン・`drainQueue` 内で監視）。

### 9.4 worker/pending latest-wins と filter の競合（M12）

既存の latest-wins 機構（`src/main.zig:153-175` の `dispatchSideEffect`・`src/main.zig:216-232` の `reapWorker`）が効くことをテストで確認（§14・但し m-N4 に従い pure helper 抽出で非決定性を排除）。reducer 側の stale-reject（generation 照合）と main 側の pending 上書きの**二重防御**:

- 連続 `apply_filter`: 後の要求が `pending` で前者を上書き（latest-wins）。
- page in-flight 中の `apply_filter`: `pending` へ入り、page 完了後に dispatch。reducer の `handleLogLoaded`/`handleLogPageLoaded` は generation 不一致で旧結果を破棄。

---

## 10. Memory ownership（CLAUDE.md 規約準拠）

- **FilterSpec**: persistent 所有・`clone`/`swap`/`deinit` トランザクショナル（`setFilterState` で旧を free して swap）。`apply_filter` は payload `[]u8` → FilterSpec 1つ → Model へ swap → AppCmd 用は swap 後から clone（M4/M-N7・§4.4）。
- **Msg/AppCmd ペイロードの FilterSpec**: 複製所有・消費者が `deinit`。`messages.zig` の `deinit` switch の網羅更新（§3.1/3.3）。
- **Msg.apply_filter payload `[]u8`**: main が `TextInput.getValue()` を dupe して送る・Msg consumer（reducer 呼出後の main）が free（M-N7）。
- **LogLoaded.request_tip / LogLoadFailed.request_tip**: 所有・消費者が deinit（§3.2）。
- **log_snapshot_tip**: persistent 所有・`setLogSnapshotTip`/`clearLogSnapshotTip` で管理（phase2 `log_paging_tip` から一本化）。
- **log_load_error**: persistent 所有・`setStr` で管理。
- **TextInput/Modal**: App（main.zig）が `persistent_allocator` で所有。`ctx.allocator`（フレーム arena）で生成すると次フレームで use-after-free（api-notes L188-191 の罠）。

---

## 11. Error handling

| ケース | Msg | reducer 挙動 | view 表示 |
|---|---|---|---|
| 初回 LoadLog 失敗（spawn・parse・OOM・`StreamTooLong`・bad revision・`--fixed-strings` でも git error は起き得る: 例 HEAD 解決失敗） | `LogLoadFailed{generation, request_tip, error_text}` | §4.3: generation 照合で受理 → `model.log_load_error` へ保存・commits 空化・snapshot_tip は request_tip があれば保存 | `(error) <text>`（MINOR1） |
| 初回 LoadLog OOM 極限（`error_text` dupe 失敗） | `LogLoadFailedSilent{generation}` | §4.3 silent 版: generation 照合のみ・`log_load_error` は空のまま | （表示無し・次回操作で回復） |
| page 失敗（bad revision=tip 期限切れ・spawn・OOM・`StreamTooLong`） | `LogPageFailed{skip, generation, error_text}` | phase 2 どおり（`src/update.zig:643-656`）+ M3: bad revision は `LogPageFailed` へ・`clearLogSnapshotTip` + 次 LoadLog で再解決（filter 保持・MINOR2） | status bar の error_text |
| 空一致（filter 適用・0 件） | `LogLoaded{entries=&.{}, request_tip=HEAD hash, is_unborn=false}` | §4.1: `log_has_more=false`・commits 空・snapshot_tip 保存・graph policy suppressed で計算スキップ | `(no matching commits)`（MINOR1） |
| unborn repo | `LogLoaded{entries=&.{}, request_tip=空文字, is_unborn=true}`（headState=.unborn 時・appcmd） | §4.1 と同パス | `(no commits)`（フィルタ UI は使えるが結果空） |
| detail 系 git_error（show 失敗等） | `git_error`（現状）または新 `DetailFailed`（実装で判断） | §4.8: log 中の `git_error` は detail 系と仮定・stale reject（M-N9 最小対処） | status bar の error_text |

---

## 12. phase 3a 完了条件（受け入れ基準）

1. `f` キーでモーダルが開き、作者名入力 → Enter で線形一覧が更新される（pty 検証）。
2. `F` で filter が解除され、graph 付き全件一覧へ戻る。
3. 空一致で `(no matching commits)`・graph は非表示。
4. mode toggle（L）/ refresh（r）/ bad revision recovery で **filter が保持**される（M5）。
5. filter 中の graph は非表示・理由（`Filter: author="..." (graph hidden)`）が表示される（B2・§19）。
6. モーダル中に `q`/`r`/`L`/`tab` が効かない（M6）。
7. モーダル中に背面 pane クリックが無視される（M6 mouse 抑止）。
8. 分岐履歴で作者 paging が正しい（B1 snapshot_tip・前ページ末尾と次ページ先頭が重複しない）。
9. UTF-8 作者名（日本語含む）の `--fixed-strings` match が壊れない（M8/m-N2）。
10. 初回失敗（例: HEAD 解決失敗・spawn OOM）で `(error) <text>` 表示・アプリが停止しない（B4）。
11. `zig build test --summary all` が green（Debug 既定・AGENTS.md）。

> ※ rev.2 の完了条件 3「invalid regex（`[`）で `(error)` 表示」は `--fixed-strings` 仕様と矛盾するため削除（codex rev.2 指摘・literal 入力で invalid は起きない）。

---

## 13. TDD breakdown（純粋層 → UI 配線）

### 13.1 純粋層

1. **`filter.zig` 新設**: `FilterSpec` の `isEmpty`/`eql`/`clone`/`deinit`/`setAuthor`/`clearAuthor`。`std.testing.allocator` + `checkAllAllocationFailures`（§14・但し m-N3 に従い OOM を伝播する純粋 helper のみへ使用）。**`src/root_test.zig` へ `_ = @import("filter.zig");` 追加を忘れない**（MINOR4）。
2. **`commands.logArgv`/`logPageArgv` の filter + snapshot_tip 拡張**: `FilterSpec.init()`（isEmpty）+ `snapshot_tip=null` で argv が変わらない（回帰）・author あり + snapshot_tip ありで `--fixed-strings --author=<literal>` と `<snapshot_tip>` が追加・`OwnedArgv.deinit` で leak 無し。
3. **`commands.revParseHeadArgv`/`revParseHead`**: argv 形式・`headState` との協調。
4. **`messages.Msg/AppCmd` の新バリアント**: `log_load_failed`/`log_load_failed_silent`/`apply_filter: []u8`/`close_filter_modal`/`open_filter_modal`/`clear_filter` の deinit・`LoadLog.filter`/`LoadLogPage.filter`/`LogLoaded.request_tip`/`LogLoaded.is_unborn` の deinit。
5. **`model.setFilterState`/`clearFilterState`/`setLogSnapshotTip`/`clearLogSnapshotTip`/`setLogLoadError`**: H6/R1 と同型・`checkAllAllocationFailures`。
6. **phase2 `log_paging_tip` 削除の回帰テスト**: 既存 phase2 テスト（`src/model.zig` 該当 test block）を `log_snapshot_tip` へ更新・`handleLogPageLoaded` の stale-reject が `log_snapshot_tip` で機能することを検証。
7. **`update.handleApplyFilter`（payload-first・M4/M-N7）**: payload から FilterSpec 構築失敗で Model 不変・成功で filter_state/generation/snapshot_tip/policy 更新・load_log 発火。`checkAllAllocationFailures` は 1 の `setAuthor` OOM のみ・3 の clone OOM 回復は FailingAllocator 特定 fail index（m-N3）。
8. **`update.handleClearFilter`**: filter_state 空化・policy=.auto・graph invalidate・load_log（filter isEmpty）発火。
9. **`update.handleLogLoaded`（B1/B2/M-N8）**: snapshot_tip dupe・policy==.suppressed で graph 計算スキップ・空結果で `log_load_error` を clear（M-N8）。
10. **`update.handleLogLoadFailed`/`handleLogLoadFailedSilent`（B4/M3）**: generation 照合・`log_load_error` へ保存・snapshot_tip 保存/クリア。
11. **`update.handleLogPageLoaded`（B2/B1 一本化）**: policy==.suppressed で graph 計算スキップ・`request_tip==log_snapshot_tip` 照合。
12. **`update.handleRequestRefreshLog`/`handleToggleViewMode`/`git_error`(log) の filter 保持（M5）**: `buildLoadLogCmd` 経由で filter が伝播・全 site のテスト網羅。`git_error`(log) は `load_log` 発火を廃止（M3・§4.8）。
13. **`update.keyToMsgForModeWithModal`（M6）**: modal visible で Enter→apply_filter（tag のみ・payload は main 側）/Esc→close_filter_modal/それ以外 null。
14. **`update.handleOpenFilterModal`/`handleCloseFilterModal`**: modal_open/policy の遷移。
15. **appcmd 結合（`runLogInt`/`runLogPageInt`）**: `TmpRepo` で複数作者 commit を作り `--fixed-strings --author` で絞り込み・B1 snapshot_tip が HEAD と一致・B4 初回失敗（HEAD 解決失敗・spawn OOM）で `LogLoadFailed`・M3 bad revision で `LogPageFailed`・MINOR7 `StreamTooLong` 正規化（limit 注入）・m-N1 unborn で `is_unborn=true`。

### 13.2 UI 層

16. **`view.renderLogMode` modal 分岐（MINOR5/m-N5）**: modal visible で `viewWithBackdrop` が返る・base は返らない（背景は見えない）。
17. **`view.renderLog` graph policy 表示（B2）**: policy==.suppressed で graph 列が表示されない・理由メタ行が入る（§19）。
18. **`view.renderStatus` filter indicator + log_load_error**: filter 適用中 `[Filter: author="..."]`・`(error) <text>`。
19. **`view.renderLog` 空表示切り分け（MINOR1/m-N1）**: `(no commits)` / `(no matching commits)` / `(error) <text>` の切り分け。
20. **main 結合**: `f` で modal open・TextInput 入力・Enter で apply（payload 構築）・Esc で close・`F` で clear（pty 検証は tmux・AGENTS.md「TUI の手動検証」）。

---

## 14. テスト境界（codex MINOR6 + rev.2 m-N3/m-N4・網羅リスト）

### 14.1 `checkAllAllocationFailures` の使用範囲（m-N3 解決）

- **使用する（OOM を伝播する純粋 helper）**: `FilterSpec.clone`/`setAuthor`/`OwnedArgv` 構築/`Model.setFilterState`/`setLogSnapshotTip`/`setLogLoadError`。
- **使用しない（OOM を内部回復・握る関数）**: `apply_filter` の clone OOM 回復（`clearFilterState` で Model を変える・FailingAllocator の特定 fail index で検証）/ snapshot_tip 保存の OOM 回復（`clearLogSnapshotTip` へ fallback）/ appcmd failure 変換（`mkLoadFailedOrSilent` が `mkLoadFailedSilent` へ fallback・特定 fail index）。
- **使用しない（subprocess 含む appcmd 全体）**: 非決定性のため（git 実行のタイミング・ファイルシステム状態に依存）。

### 14.2 worker 競合テスト harness（m-N4 解決）

`main.zig` の worker/queue/pending は private・実 thread + 33ms tick 依存で非決定的。以下のいずれかで対処:
- **dispatcher/reaper の state machine を pure helper へ抽出**: `dispatchSideEffect(app, cmd)` と `reapWorker(app)` の core logic（pending 上書き・worker 起動判定）を `App` の状態遷移関数として切り出し、テストでは `App` を直接構築して状態遷移を検証（実 thread を回さない）。
- **test-only barrier 付き fake executor 注入**: `program.send` を fake に置き換え、結果 Msg の順序を制御。

> **sleep 依存テストにしない**（m-N3/m-N4）。

### 14.3 網羅リスト

- 分岐履歴（A←B, A←C・merge D）で作者 paging（snapshot_tip が正しく機能・B1）。
- **★B1 race 回避テスト（codex rev.2 指摘）**: 初回 query へも同じ tip が渡ること・rev-parse 後に HEAD が動いても log は snapshot_tip 到達可能集合を返すこと（`<snapshot_tip>` 明示限定の検証・fake で HEAD 移動をシミュレート）。
- 100件/101件一致（EOF 判定・M3: `entries.len >= max_count`）。
- 空一致（`(no matching commits)`・MINOR1）。
- **invalid regex test は削除**（`--fixed-strings` 仕様・codex rev.2 指摘・literal 入力で invalid は起きない）。
- **16MiB 超過 → `StreamTooLong` → `LogLoadFailed`/`LogPageFailed`（MINOR7）**: limit 注入設計で小さな limit で再現（重い実データを作らない・codex rev.2 指摘）。
- unborn repo / detached HEAD（snapshot_tip 解決・phase1 R5/R19 の tri-state 再利用・m-N1 の `is_unborn=true`）。
- filter 変更中の旧 page 成功結果の破棄（stale-reject・generation 照合）。
- filter 変更中の旧 page 失敗結果の破棄（`LogPageFailed` の generation 照合）。
- filter 変更中の旧 detail git_error の破棄（M-N9 最小対処・owner hash 照合）。
- OOM clone（payload-first トランザクション・`apply_filter` の M4・`checkAllAllocationFailures` は伝播 helper のみ・回復は特定 fail index）。
- UTF-8 作者名（`山田太郎`・`José` 等）の `--fixed-strings` match が壊れない（M8/m-N2）。
- モーダル中 global key（`q`/`r`/`L`/`tab`）抑止（M6）。
- モーダル中 mouse routing 抑止（M6）。
- mode toggle/refresh/bad-revision で filter 保持（M5/MINOR2・全 load_log site）。
- **`escapeRegexLiteral` test は削除**（M-N6・`--fixed-strings` 採用で廃止）。
- filter 適用 → paging → 適用解除（`F`）で graph 復活（B2 policy 遷移）。
- filter 適用 → bad revision recovery → filter 保持・再取得（MINOR2）。
- 連続 `apply_filter`（worker/pending latest-wins・M12・pure helper 抽出で検証）。
- page in-flight 中の `apply_filter`（pending へ入り page 完了後 dispatch・M12）。
- detail in-flight 中の `apply_filter`（同上・M12・但し detail git_error が新 filter worker の busy を解除しないこと・M-N9）。
- `FilterSpec.max_author_runes` 境界（256 Unicode scalar ok / 257 error・m-N2）。
- `FilterSpec` 空文字 → null 正規化（`isEmpty()==true`）。
- `log_load_error` の上書き（前回エラー→成功でクリア・M-N8→別エラーで上書き）。
- **`log_snapshot_tip` 一本化テスト**: phase2 の `log_paging_tip` 関連テストが `log_snapshot_tip` で全て機能すること。

---

## 15. api-notes（`docs/superpowers/plans/zigzag-api-notes.md`）への追記内容

L266-267 と L278 を以下へ全面置換・拡充（実シグネチャ・§1.5 と同一内容・重複するため本節では要点のみ）:

- **`TextInput`**: `init(allocator)`/`deinit()`/`setValue(text) !void`/`getValue() []const u8`（★borrowed・TextArea と異なり allocator 不要）/`setPlaceholder`/`setPrompt`/`setWidth`/`setCharLimit`/`setEchoMode`/`focus`/`blur`/`handleKey(key) void`（Ctrl+a/e/k/u/w, Alt+arrow, 文字/BS/Del/左右/Home/End/tab・★enter/escape は処理しない）/`view(allocator) ![]const u8`（フレーム arena 想定）。生成は `persistent_allocator`、毎フレーム描画は `ctx.allocator`。多バイト入力 OK。submit シグナルは無い（アプリ側で Enter を横取り）。
- **`Modal`**: `init()`/`show()`/`hide()`/`isVisible()`/`addButton(label, shortcut)`/`handleKey(key) void`（button shortcut / escape→dismissed / enter→button_pressed / tab,left,right で button 選移・★button_count==0 なら enter は no-op）/`view(allocator, w, h) ![]const u8`（中央 box のみ・透明 canvas）/`viewWithBackdrop(allocator, w, h) ![]const u8`（★全面 canvas・solid backdrop・透過しない・MINOR5/m-N5）/`renderBox(allocator, w, h) ![]const u8`。Presets: `info`/`confirm`/`warning`/`err`。`Result = union(enum) { button_pressed: usize, dismissed: void }`。`Size = union(enum) { fixed: u16, percent: f32, auto: void }`。
- **overlay 描画の罠（MINOR5/m-N5）**: `view`/`viewWithBackdrop` は全面 canvas を返す。既存 render 文字列との単純 join（`zz.joinVertical` 等）は overlay にならない（backdrop が base を隠す）。modal 表示中は base view を返さず `viewWithBackdrop` を返す設計。
- **button と TextInput の混在**: Modal は button を前提とした `handleKey`（Enter→button_pressed）。body に TextInput を置き Enter/Esc をアプリで制御したい場合は、`Modal.handleKey` に渡す前にアプリ側で横取り（button を追加しない or `close_on_escape=false` + アプリ側で Esc 判定・phase 3a では Modal へ渡さない）。

---

## 16. phase 3b 拡張ポイント（概要のみ・本設計では実装しない）

- **FilterSpec へ追加**: `since: ?[]u8` / `until: ?[]u8`（ISO 8601 UTC・M9: timezone は UTC 固定・phase 2 の date 表示と整合）/ `path: ?[]u8`（MINOR3: literal repo-relative または `:(literal)<path>`）/ `branches: ?[]u8`（B3: 単一 branch は hash 解決して snapshot_tip へ・複数 branch は和集合問題の解決が前提）。
- **`logArgv`/`logPageArgv` へ引数追加**: `--since=<date>` / `--until=<date>` / `-- <path>`（argv 末尾・`--` 後へ借用追加・M11 の OwnedArgv で owned には入れない）/ `--branches=<glob>`（B3 注意）。`--fixed-strings` は `--author`/`--grep` に影響するため、phase 3b で `--grep` を追加する場合は再検証。
- **UI へ各入力フィールド追加**: モーダル内に TextInput 複数（or タブ切り替え）・`zz.Form`（`components/form.zig`）の活用候補。
- **graph policy**: 全フィルタ種別で `.suppressed`（部分集合で topology 保証できないため・M1）。graph 維持は nearest-visible-parent 投影（L 案）または Git history simplification（別案）を別 spec で検討。
- **branch と snapshot_tip**: B3 の和集合問題を避けるため、単一 branch 選択時は選択 branch ref を `git rev-parse --verify <branch>` で hash 解決し、それ自体を snapshot_tip とする。複数 branch は snapshot owner を単一 tip ではなく複数 hash の所有集合にする必要がある（要件定義から・codex 未解決論点 6）。

---

## 17. Risks & mitigations

| Risk | 重要度 | mitigation | 根拠 |
|---|---|---|---|
| `log_snapshot_tip` 一本化で phase2 テストが壊れる | 中 | §1.2 移行ステップ（5 段階）で機械的に置換・phase2 テストを `log_snapshot_tip` へ更新して `zig build test` で回帰確認 | `src/update.zig:578-581,606-611`, `src/model.zig:65` |
| `apply_filter` の clone OOM で Model を `clearFilterState` へ戻すと UI が一時的に空 filter になる | 中 | §4.4 失敗時・強例外保証の妥協（旧 filter_state は swap 時に失われているため復元不可）・ユーザーは再入力で回復・`log_load_error` で通知 | CLAUDE.md:55-57 / `src/update.zig:446-472` |
| `viewWithBackdrop` 全面 canvas が base を隠す（m-N5） | 中 | §8 で「modal 表示中は base view を返さず viewWithBackdrop を返す・背景は見えない」を基準へ明記・tmux pty で目視検証（AGENTS.md） | `modal.zig:379-432` |
| `g_view_modal`/`g_view_textinput` の file-scope var が thread-safety の懸念 | 低 | zigzag の view はメインスレッドのみから呼ばれる（`program.tick` 内・`src/main.zig:286-290`）。`g_program`/`g_app` と同様 | `src/main.zig:111,314` |
| `OwnedArgv` 導入で既存 `freeLogArgv`/`freeLogPageArgv`（`src/appcmd.zig:265-284`）と二重管理 | 低 | `OwnedArgv.deinit` へ統一・旧関数は削除。appcmd の呼出元を全て OwnedArgv へ更新 | M11 |
| detail git_error の stale reject が不完全（M-N9 最小対処） | 中 | §4.8 で owner hash 照合を追加・busy の完全修正は §18 将来課題 | `src/update.zig:253-273,672-689` |
| `Msg.git_error` が owner hash を持たず stale reject が困難 | 中 | §4.8 で log 中の `git_error` を全て無視（`.none`）するのが安全・detail 系 stale 結果は `detail_owner_hash` 照合で別途弾かれる・または `git_error` を構造体化（実装で判断） | M-N9 |
| `--fixed-strings` が phase 3b で `--grep` と併用時に意図しない挙動 | 低 | phase 3a は `--author` のみなので副作用なし・phase 3b で `--grep` 追加時に再検証 | §2 |
| worker 競合テストが非決定的（m-N4） | 中 | §14.2 で dispatcher/reaper を pure helper へ抽出・sleep 依存テストにしない | `src/main.zig:153-175,216-232` |
| TextInput.getValue が borrowed なため reducer が直接読めない | 低 | §3.1/§9 で `Msg.apply_filter: []u8` payload 化・main が Enter 押下時に dupe（M-N7） | `text_input.zig:106` |

---

## 18. 将来課題（phase 3a 完了後・phase 3b 以前に検討）

- **busy lifecycle の完全修正（M-N9）**: runtime lifecycle（main.zig の `reapWorker`/`dispatchSideEffect`）のみで busy を管理し、reducer で `busy=true/false` を触らない方針。これにより stale detail git_error が新 filter worker の busy を解除する問題を根本解決。phase 3a は最小対処（§4.8 owner hash 照合）で凌ぐ。
- **graph 維持（phase 3b 以降）**: nearest-visible-parent 投影（L 案）= visible commit 間の最近親可視親を事前計算して既存 `processCommit`（`src/git/graph.zig:86-303`）へ入力・phase2 spec §G.4 を活用。または Git history simplification（`--simplify-by-decoration` 等＋拓浦順）= 別案。いずれも別 spec。
- **オーバーレイ compositor（m-N5）**: `viewWithBackdrop` 全面置換ではなく、base view の上に modal box を透過描画する compositor を設計。zz 側のサポート要確認。
- **filter 履歴**: `TextInput.suggestions`（`text_input.zig:159-178`）へ過去 N 件の作者名を設定し Tab 補完。
- **コミットメッセージエディタ（TextArea）と filter TextInput のフォーカス切り替え**: phase 3a では modal 中のみ TextInput 利用だが、将来的にインライン編集等をする場合は `FocusGroup`（`components/focus.py`）の活用。

---

## 19. Open product decisions（ユーザーが spec レビューで覆可能）

以下は**デフォルト**。ユーザーが spec レビューで変更可能。

1. **filter 永続化範囲**: log→changes→log の mode toggle / `r`（refresh）/ bad revision recovery / 空結果後の再取得の**いずれでも FilterSpec を保持**（解除はユーザーが明示的に `F` or clear するまで）。全 `load_log` 発火 site を共通 builder（§4.5）へ集約。**変更可能**: 例えば mode toggle では解除する等。
2. **作者マッチ方式**: `git log --fixed-strings --author=<literal>`（escape 不要・M-N6）・大小文字区別あり（git 既定）・name/email 双方が git の対象・長さ上限 256 Unicode scalar（m-N2）・UTF-8。**変更可能**: 例えば regex として公開（`--fixed-strings` を外す）・case insensitive（`--regexp-ignore-case` 追加）・email/name のみ等。
3. **graph 非表示時の UX（n-N3・新規プロダクト判断）**: status bar or log ペイン上部メタ行に `Filter: author="<raw>" (graph hidden)` の理由表示（§8.2）。**変更可能**: 単なる線形一覧で理由表示しない（codex 未解決論点 8）。
4. **モーダル外クリック**: 無視（デフォルト・誤クリック保護）。**変更可能**: close する。
5. **`Ctrl+U` の割当**: TextInput 既定（Kill to start = 全削除）。**変更可能**: `clear_filter` へ割当（`F` キーと重複なく）。
6. **open_filter_modal 時の TextInput 初期値**: 現 `filter_state.author` を再表示（編集継続を自然に・§9.3・デフォルト）。**変更可能**: 毎回空（新規入力固定）。
7. **unborn と空一致の表示区別（m-N1）**: `LogLoaded.is_unborn` で `(no commits)` / `(no matching commits)` を切り分け（§8.3・デフォルト）。**変更可能**: 統一して `(no commits)` のみ。
8. **`log_snapshot_tip` 一本化（rev.3 の方針）**: phase2 `log_paging_tip` を廃止し `log_snapshot_tip` へ一本化（race 回避・codex rev.2 指摘1）。**変更可能**: 並存させる（但し二重管理リスク・§17）。

---

## 20. References

- codex レビュー:
  - `/tmp/opencode/phase3-codex-review.md`（rev.1・BLOCKER4/MAJOR12/MINOR7/NIT3）
  - `/tmp/opencode/phase3-codex-review-rev2.md`（rev.2・M-N7..M-N9/m-N1..m-N5/n-N1..n-N3）
- rev.1 ドラフト: `/tmp/opencode/phase3-filter-design-draft.md`
- rev.2 設計 doc: `/home/hatai/.local/share/opencode/tool-output/tool_ee2deb3b0001Rymgnif9d39nnv`
- プロジェクト規約: `CLAUDE.md`（所有権規約 L55-57・テスト規約 L48-53・Zig 0.16 落とし穴 L40-46）
- TODO: `TODO.md` phase 3（L178-180）
- phase 1 spec: `docs/superpowers/specs/2026-06-18-todo2-log-view-phase1-design.md`（rev.9・H1-H7/R1-R26）
- phase 2 spec: `docs/superpowers/specs/2026-06-19-todo2-log-view-phase2-display-design.md`（rev.2・H-01..H-08/M-01..M-14）
- api-notes: `docs/superpowers/plans/zigzag-api-notes.md`（L266-267,278 を§15 で拡充）
- 実コード根拠:
  - `src/model.zig:23-66`（Model 構造体）, `:65`（log_paging_tip・phase3a で廃止）, `:237-368`（所有権ヘルパ）, `:347-368`（setLogGraphState/setLogPagingTip 等）
  - `src/messages.zig:8-57`（Msg union）, `:58-79`（LogLoaded/LogPageLoaded/LogPageFailed 構造体）, `:180-200`（AppCmd/LoadLog/LoadLogPage）, `:90-168,202-235`（deinit switch）
  - `src/update.zig:253-277`（git_error arm・phase 3a で load_log 発火を廃止）, `:340-345`（結果系 arms dispatch）, `:366-400`（handleToggleViewMode）, `:446-472`（payload-first 規約）, `:501-524`（handleRequestRefreshLog）, `:548-592`（handleLogLoaded・B1/B2/M-N8 拡張点）, `:599-640`（handleLogPageLoaded・B1 一本化）, `:643-668`（handleLogPageFailed/Silent）, `:672-689`（handleCommitDetailLoaded/handleDetailDiffLoaded・M-N9 stale reject 参照）
  - `src/appcmd.zig:107-108`（load_log/load_log_page arm）, `:155-196`（runLogInt・B1/B4 拡張点）, `:199-219`（mkPageFailed*）, `:221-260`（runLogPageInt・M3 bad revision を LogPageFailed へ）, `:262-284`（freeLogArgv/freeLogPageArgv → OwnedArgv.deinit へ）
  - `src/git/commands.zig:60-112`（logArgv/logPageArgv・snapshot_tip + filter 拡張点）, `:193-218`（headState tri-state）, `:341-443`（logArgv/logPageArgv テスト）
  - `src/git/process.zig:12,28-45`（RunError/16MiB limit・MINOR7）
  - `src/git/log.zig:7-22`（Commit 構造体・author: []u8）
  - `src/input.zig:158-235`（keyToMsgForMode/keyToMsgForLog・M6 拡張点）, `:297-313`（fromZigzagMouseForMode）
  - `src/view.zig:343-363`（renderStatus）, `:434-449`（renderLog・show_graph 判定 L447・B2 拡張点）, `:644-682`（render/renderLogMode・MINOR5/m-N5 拡張点）
  - `src/main.zig:95-109`（App 構造体）, `:153-175`（dispatchSideEffect・latest-wins）, `:210-214`（syncCommitText・rev.2 syncFilterDraft の先例・rev.3 で廃止）, `:216-235`（reapWorker）, `:258-266`（RuntimeModel.init）, `:292-308`（RuntimeModel.deinit）, `:324`（drainQueue で textarea.setValue・§9.3 の先例）, `:339-355`（handleKey・TextArea 横取り）, `:358-409`（handleMouse）
  - `src/autorefresh.zig:21`（log モード抑止）
  - `src/root_test.zig`（MINOR4・`@import("filter.zig")` 追加）
  - `zig-pkg/.../components/text_input.zig:10-462`（TextInput 実 API）
  - `zig-pkg/.../components/modal.zig:52-761`（Modal 実 API）
- git 公式資料:
  - `git-log(1)`: `--author=<pattern>`（regex・name/email 双方が対象）, `--fixed-strings`（regex 解釈を無効化・literal match）
  - `git-rev-list(1)`, `gitrevisions(7):524-530`: 複数 positive revisions は "reachable from any"（B3 和集合問題）

---

（以上・rev.3・コード編集・ファイル作成は行っていません）
</task_result>
</task>