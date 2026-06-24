# 設計: busy lifecycle 完全修正（TODO 2 phase 3b #4・M-N9）

- **日付**: 2026-06-24
- **関連**: `TODO.md` phase 3b #4（`TODO.md:198`）/ phase3a spec §18 将来課題（`docs/superpowers/specs/2026-06-20-todo2-log-view-phase3a-filter-design.md:961`）/ §4.8 最小対処（同 `:571-587`）/ §17 risk（同 `:951-952`）/ handoff `docs/superpowers/handoffs/2026-06-23-todo2-phase3b-handoff.md`
- **状態**: 設計（ユーザ承認済）→ plan レビュー待ち

---

## 1. 背景・問題

`Model.busy` は reducer の二重実行ゲート（`request_commit`/`stage_lines`/`stage_hunk` が `if (model.busy) return .none;` で弾く・`src/update.zig:93,178,216`）。意図は「in-flight 副作用があれば mutating 操作を弾く」。

### 1.1 M-N9 の競合（根本原因）

`busy` は現在 **2 箇所**で書かれる:

- **runtime**（本来の所有者）: `dispatchSideEffect`（`src/main.zig:168` busy=true）・`reapWorker`（`src/main.zig:233` join 後 busy=false）・`seedInitialStatus`（`src/main.zig:612`）。
- **reducer**（副次的）: `status_loaded`/`diff_loaded`/`git_error`/`committed`（`src/update.zig:240,245,257,269`）が busy=false。

1 tick 内の競合シーケンス:

1. `reapWorker`: 旧 worker 完了（`takeWorkerDone`=true）→ join → **busy=false** → pending を dispatch → 新 worker spawn → **busy=true**。
2. `drainQueue`: 旧 worker が push 済みの **stale 結果**（例: `git_error`）を drain → reducer の `git_error` arm → **busy=false**。
3. 新 worker 仍在飛なのに busy=false → ユーザの `Ctrl+S`/`s`/`H` が busy ゲートを通過 → **二重実行**。

phase3a §4.8 は「log 中の `git_error` を無条件 `.none`」の最小対処で凌いだが、`git_error:257` の `busy=false` は残っており、stale detail 系の排除が不完全（§17 risk）。本設計は §18 の完全修正。

### 1.2 なぜ reducer が busy を触ってはいけないか

reducer は「ある結果 Msg を処理した」という事実しか知らない。その結果が「どの worker に属するか（stale か fresh か）」を reducer は持たない（`Msg.git_error` は owner hash 無し・§4.8）。よって reducer が busy を下ろすと、必ず上記競合が開く。**runtime のみが busy を所有**すれば、busy は「実際に join したか」でのみ下り、stale 結果の drain では触れない → 構造的に競合不能。

---

## 2. 解決の核心（1 行）

> **`busy` は runtime のみが所有する。reducer は `busy` を読むことのみ（3 ガード）・一切書かない。**
> よっていかなる stale 結果のインターリーブでも busy は変わらず、busy は `reapWorker` の join のみで下りる。

これは必要十分: reducer がいかなる結果 Msg を処理しても busy 不変（reducer テストで証明）+ busy の上げ下げは runtime のみ（runtime テストで証明）。

---

## 3. 設計: runtime 所有権規則

busy の書き込みサイト（変更後）:

| サイト | 動作 | `src/main.zig` 行 | 変更 |
|---|---|---|---|
| `dispatchSideEffect`（spawn 成功） | `busy = true` | `:168` | 維持 |
| `reapWorker`（join 後） | `busy = false` | `:233` | 維持 |
| sync フォールバック（spawn 失敗） | `workerRun` 後 `busy = false` | `:170-179` 周辺 | **新設** |
| `seedInitialStatus`（末尾） | `busy = false` | `:612` | 維持（既に runtime 所有・pre-`start()` 同期） |

reducer 側の busy 書き込みは **4 箇所すべて削除**（`src/update.zig:240,245,257,269`）。ガード読み取り 3 箇所（`:93,178,216`）は維持。`working`（スピナ・`model.zig:43`）は既に runtime 所有（`dispatchSideEffect:169`/`reapWorker:234`）・**本件の対象外**。

### 3.1 sync フォールバックの busy 下ろし

現状: spawn 失敗時 `worker=null; working=false; workerRun(app,cmd);`（busy=true のまま・以後 reducer が下ろす）。修正後は reducer が下ろさないため **ここで明示的に下ろす**。

```text
spawn 失敗時:
  app.worker = null          // (WorkerHandle 型・§4)
  app.model.busy = false     // ← 新設（workerRun 完了直後）
  app.model.working = false  // 維持
  workerRun(app, cmd)        // 維持（結果は次 tick の drainQueue へ）
```

根拠: sync 実行は 1 tick 内で完了し、in-flight worker は存在しない。busy=false は「worker 在飛無し」の正しい状態。キュー内の結果は次 tick で drain されるが、それは並発ではなく「保留中の reducer 入力」なので busy 保護不要。

### 3.2 `.committed` フローの確認

`.committed` arm は `busy=false` を削除後も `clear commit_message` → `return .refresh_status`。`.refresh_status` cmd は `applyAppCmd` → `dispatchSideEffect` → busy=true + spawn。commit 後の refresh worker が正しく busy=true を立て、`reapWorker` で下りる。変更後も commit→refresh→reap の busy ライフサイクルは正しい。

---

## 4. 設計: テスト容易性 seam（実スレッド注入可能化・m-N4 部分）

`src/main.zig` は `root_test.zig` に import されておらず `test {}` ブロックも皆無 → worker lifecycle 層は**現在未テスト**。本修正はまさにこの層にあるため、M-N9 競合を決定的に再現する回帰テストを書く。実 thread を回さず、spawn を注入可能にする。

### 4.1 worker ハンドルの分割（1 フィールド・ラップ型）

`worker: ?std.Thread`（`src/main.zig:110`）→ `worker: ?WorkerHandle`:

```zig
const WorkerHandle = struct { thread: ?std.Thread = null };
worker: ?WorkerHandle = null,
```

- **本番**: spawn 成功時 `app.worker = .{ .thread = spawned_thread }`。
- **テスト executor**: `app.worker = .{ .thread = null }`（在飛状態・実 thread 無し）。

`reapWorker` の join は `if (w.thread) |t| t.join();` でガード → テスト（thread=null）では join しない。フィールド 1 つのまま在飛状態を実 thread から切り離す。

### 4.2 spawn の注入（関数ポインタ）

`App`（`src/main.zig:96`）へ追加:

```zig
spawn_fn: *const fn(*App, AppCmd) void,
```

- **本番**（`spawnAsync`）: `std.Thread.spawn(.{}, workerThread, .{ app, cmd })`。成功 → `app.worker = .{ .thread = handle }`。失敗 → §3.1 の sync フォールバック（`workerRun` + busy=false + working=false、**`markWorkerDone` 無し**＝review Issue 2 維持）。`main()` で `app.spawn_fn = spawnAsync` を設定。
- **テスト**（`spawnSync`）: `app.test_staged`（`ArrayList([]const Msg)`）から次の結果グループを pop → 全 Msg を `queue.push` → `markWorkerDone` → `app.worker = .{ .thread = null }`。**同期的**・`appcmd.run` を呼ばない（git 不要）。

`dispatchSideEffect` は `std.Thread.spawn` 直呼びを `app.spawn_fn(app, cmd)` へ置換。

### 4.3 `reapWorker` 書き直し

```text
reapWorker(app):
  if (app.worker == null) return
  if (!app.queue.takeWorkerDone(io)) return
  if (app.worker.?.thread) |t| t.join()   // 本番のみ
  app.worker = null
  app.model.busy = false
  app.model.working = false
  if (app.pending) |next| { app.pending = null; dispatchSideEffect(app, next) }
```

### 4.4 なぜ `worker` を分割するか

`reapWorker` は「在飛 worker があるか」を `app.worker != null` で判定する。テストで実 thread を作らずに在飛状態を作るには、判定フラグと実 thread handle を分離する必要がある。`WorkerHandle.thread: ?std.Thread` がその分離（在飛=handle 有り、join=thread 有り）。フィールド増やさず 1 ラッパで表現。

---

## 5. 設計: reducer 変更（純粋層）

- `src/update.zig:240`（`.status_loaded`）・`:245`（`.diff_loaded`）・`:257`（`.git_error`）・`:269`（`.committed`）の `model.busy = false;` を **4 行削除**。各 arm のそれ以外の挙動は不変（`.committed` → `.refresh_status` 再 dispatch・`.git_error` log 中 `.none` 分岐など）。
- stale コメント更新: `src/main.zig:174-177`（「busy は reducer 結果で下りる」）→「busy は `reapWorker`/sync フォールバックで下りる（reducer は触らない）」。

---

## 6. テスト戦略（TDD: 純粋層 → runtime）

### 6.1 純粋層テスト（`src/update.zig`・既存 root_test.zig 配下）

- **新規 busy 不変テスト**: `status_loaded`/`diff_loaded`/`git_error`/`committed` の各々で `m.busy = true` に設定 → reducer 実行 → **`m.busy == true` を表明**（競合不能の証明）。
- **既存テスト修正**: `git_error preserves file list and only sets error_text/busy`（`src/update.zig:1165-1179`）の `try std.testing.expect(!m.busy);`（`:1177`）を削除（reducer 経由で busy は下りない）。ファイル一覧保持・error_text 設定の表明は維持。テスト名も `…/busy` を外す。
- **ガードテスト据え置き**: `request_commit while busy`（`:1102`）・`stage_lines guards: busy`（`:1457`）・`stage_hunk respects busy guard`（`:1779`）。

### 6.2 runtime テスト（`src/main.zig` 新規 `test {}`・root_test.zig へ `_ = @import("main.zig");` 追加）

- **`makeTestApp()` ヘルパー**: 最小 `App` 構築（既定 `zz.TextInput`/`Modal` の init、`std.testing.allocator`/`std.testing.io`、`spawn_fn = spawnSync`、空 `test_staged`）。deinit 付き。
- **M-N9 競合回帰テスト**（決定性・thread 無し）: `test_staged = [[git_error_A], [status_loaded_B]]`。
  1. `dispatchSideEffect(.load_log)` → A 在飛（busy=true・worker!=null・queue=[git_error_A]・done=true）。
  2. `dispatchSideEffect(.load_log)` → pending=B（busy 変わらず true）。
  3. `reapWorker()` → busy 一度 false → B dispatch → busy=true（B の結果も push・done=true）。
  4. `drainQueue()` → A の stale `git_error` を処理。
  5. **表明 `busy == true`**（B 仍在飛）。※ 修正前は false になる（バグ再現）。
- **所有権テスト**:
  - dispatch（spawn 成功）→ busy=true & `worker != null`。
  - `reapWorker`（done）→ busy=false & `worker == null`。
  - sync フォールバック（spawn 強制失敗）→ `workerRun` 後 busy=false & `worker == null`。
  - pending latest-wins（連続 dispatch で最後のみ残る）。
  - `.committed → .refresh_status` 再 dispatch で busy=true 維持。

### 6.3 io の調達

`App.io: std.Io`（mutex `lockUncancelable(io)` が要求）は `std.testing.io` で構築（`docs/superpowers/plans/zigzag-api-notes.md:52,57`・既存 appcmd テスト 33 箇所で実績）。test ビルド限定。

---

## 7. 影響範囲・非対象

- **変更ファイル**: `src/main.zig`（seam・`reapWorker`/`dispatchSideEffect`/`App`/sync フォールバック・コメント・新規 test）・`src/update.zig`（4 行削除・テスト修正）・`src/root_test.zig`（main.zig import 追加）・`TODO.md`（`:198` チェック）。
- **非対象**: `working`（スピナ）・`maybeAutoRefresh` の busy 点灯セマンティクス・`seedInitialStatus` の構造・`Msg.git_error` の構造体化（不要になる）・detail 系 stale-reject（`detail_owner_hash` 照合・`update.zig:672-689` 相当・維持）・phase3a §4.8 の「log 中 git_error 無視」分岐（維持・busy 行のみ削除）。
- **既存挙動の互換性**: busy の見え方は不変（表示に使わない・`model.zig:42` コメント「表示はしない」）。スピナ（`working`）も不変。自動リフレッシュの busy 点灯も不変。

---

## 8. リスク・緩和

| Risk | 重要度 | mitigation | 根拠 |
|---|---|---|---|
| main.zig を test ビルドへ import すると zz/file-scope 依存でコンパイルが壊れる | 中 | main.zig は exe 向けに単独コンパイル済み（型/`var`=undefined のみ）。import は top-level 宣言と `test {}` を取り込み `pub fn main` は未呼出。壊れれば `makeTestApp` が最小 `App` のみ参照するよう隔離 | `src/root_test.zig`・`src/main.zig:117-119,349` |
| sync フォールバックで `worker` に phantom が残り busy が戻らない | 中 | フォールバックで `app.worker = null` を明示設定（§3.1） | `src/main.zig:170-179` |
| sync フォールバックが `markWorkerDone` すると次回正規 worker が stale done で即 join される（review Issue 2 リグレッション） | 中 | フォールバックは `markWorkerDone` しない（現状維持）・`workerThread` のみが done を立てる | `src/main.zig:122-129` |
| 競合回帰テストが実際には競合を起こさない（偽陰性） | 中 | テストは修正前コードで busy==false を再現することを先ず確認（red）→ 修正で green。`test_staged` の順序が reap→dispatch→drain を正しく模倣 | §6.2 |
| `toggle_stage`（`update.zig:74`）が busy ガードを持たない（既存ギャップ） | 低 | 本件の対象外・別件。必要なら別 spec | `src/update.zig:74` |

---

## 9. 受け入れ基準

1. `src/update.zig` の reducer に `model.busy =` への書き込みが 0 件（ガード読み 3 件のみ）。
2. busy の書き込みは runtime（`dispatchSideEffect`/`reapWorker`/sync フォールバック/`seedInitialStatus`）のみ。
3. §6.1 の busy 不変テスト（4 種）+ §6.2 の runtime テスト（競合回帰 + 所有権）が全て green。
4. `zig build test --summary all` が全件 green（現行 509 + 新規分）。Debug 既定維持。
5. `TODO.md:198` の #4 チェックボックスを `[x]` へ。
6. （手動）tmux pty でフィルタ切替中の高速 `Ctrl+S`/`s`/`H` 連打で二重実行・ハング無しを目視（AGENTS.md 手順）。

---

## 10. Open product decisions（spec レビューで覆可能）

- **D1（既定）**: sync フォールバックで busy=false を `workerRun` **後**に設定（結果は次 tick で drain・busy 保護不要）。代替: `workerRun` 前に false。→ 後設定を採用（「worker 在飛無し」は run 完了後が正確）。
- **D2（既定）**: `App.spawn_fn` は `main()` で `spawnAsync` を設定（既定値なし）。代替: フィールド初期値 `spawnAsync`・テストで上書き。→ 明示設定（テストビルドで意図せず実 spawn しない）。
