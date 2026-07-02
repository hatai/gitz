# git-tui — Claude 向けプロジェクトメモ

JetBrains の git GUI 相当を目指す TUI。Zig 0.16 + zigzag(v0.1.5 固定)。
ユーザ向けの使い方・キー操作・ビルドオプションは **README.md** を参照（ここでは重複しない）。

## コマンド（要点）
- ビルド: `zig build` / 配布: `zig build -Doptimize=ReleaseFast`
- テスト: `zig build test --summary all`（**既定 Debug を維持** = テストの実行時安全チェックを保つ）
- 実行: `zig-out/bin/git-tui`（git リポジトリ内で）

## アーキテクチャ（Elm 風 + 副作用隔離）
純粋ロジックを端末/zigzag/git から分離してテスト可能にしている。
- `src/model.zig` — 状態 `Model`。所有権/`deinit` 規約あり。
- `src/messages.zig` — `Msg`（入力/結果）と `AppCmd`（副作用要求）の tagged union。
- `src/update.zig` — **純粋 reducer** `update(*Model, Msg) !AppCmd`（端末/git に触れない）。
- `src/appcmd.zig` — `AppCmd` 解釈器。git を実行し結果 `Msg` を返す（端末不要・結合テスト対象）。
- `src/git/{process,status,commands}.zig` — git CLI 委譲（`std.process.run`）+ porcelain v2 パーサ + argv 生成。
- `src/input.zig` — zigzag イベント→`Msg` 正規化（`keyToMsg`/`mouseToMsg` は純粋でテスト済み）。
- `src/view.zig` — zigzag 描画 + レイアウト計算（`computeLayout` は純粋）。
- `src/main.zig` — `pub fn main(init: std.process.Init)`。reducer↔解釈器を配線。git は**ワーカースレッド**で実行し `program.send(msg)` で結果注入。

## ドキュメントの所在
- 設計(spec): `docs/superpowers/specs/2026-06-14-git-tui-design.md` — 設計判断の根拠。
- 実装計画: `docs/superpowers/plans/2026-06-14-git-tui-mvp.md`（タスク分解）。
- zigzag/std 実 API ノート: `docs/superpowers/plans/zigzag-api-notes.md`（**実 API はこれが正**）。
- **将来 TODO: `TODO.md`** — 下記参照。

## 将来 TODO（`TODO.md`）★新機能の着手前に必読
MVP に含めなかった機能は **`TODO.md` に Goal / Description / Sub Tasks / 留意点つきで詳細記載**。
新機能を実装するときは、まず `TODO.md` の該当項目を読み、そこに書かれた方式・留意点・サブタスクに従うこと
（重複設計や方式ミスを防ぐ）。現在の項目:
1. 部分ステージング（ハンク/行単位）— `git apply --cached` でのパッチ生成。
2. ログ/コミットグラフ表示 — レーン割り当て + ページング。
3. Drag&Drop interactive rebase — `GIT_SEQUENCE_EDITOR` + `GIT_EDITOR` の二系統を自ツールへ。
4. ACP（Agent Client Protocol）コミットメッセージ生成 — ACP はエディタ=クライアント前提のため要検討、代替案あり。
5. 変更の破棄（Rollback / discard）— 破壊的操作のため確認ダイアログ必須。

実装が TODO 項目に影響/完了する変更を入れたら、`TODO.md` の該当チェックボックスや記述も更新すること。

## Zig 0.16 の落とし穴（Writergate）★編集前に必読
**実 API は `docs/superpowers/plans/zigzag-api-notes.md` が正**。計画書の擬似コードと食い違う場合はノート優先。
- 子プロセスは `std.process.Child.run` ではなく **`std.process.run(gpa, io, opts)`**（`io` 必須）。
- `opts.stdout_limit`/`stderr_limit` は **`std.Io.Limit`**（`.limited(N)`/`.unlimited`、整数不可）。
- `Term.exited`（**小文字・`u8`**、`@intCast` 不要）。`cwd` は `std.process.Child.Cwd` ユニオン。
- `std.ArrayList(T)` は **unmanaged**（`.empty` / `append(a, x)` / `toOwnedSlice(a)`）。
- ファイル I/O も io 必須。`std.Io` はテストで `std.testing.io`、本番は `init.io`。

## テスト規約
- テストは**実装と同じ `.zig` 内の `test {}` ブロック**に書く（別テストファイルを作らない）。
- 新モジュールは `src/root_test.zig` の `_ = @import("...")` 行を有効化（`zig build test` が全体を一括実行）。
- 必ず `std.testing.allocator`（リーク検出）。**arena で動く関数（view の `fitPane` 等）のテストは
  `std.heap.ArenaAllocator` を渡す**（中間確保を個別 free しないため）。
- zigzag 依存の pub 関数は参照されないと型検査されない → 各ファイルに `test { std.testing.refAllDecls(@This()); }`。

## 所有権の規約
- `Msg`/`AppCmd` のペイロードは Model を**借用せず複製所有**し、**消費者が `deinit`**（main が Msg を、解釈器が AppCmd を解放）。
- `Model` の文字列は persistent allocator 所有、置換時に旧を free（`setStr`/`replaceFiles` はトランザクショナル）。
- **例外（パフォーマンスチューニング・2026-07-02）**: 現時点では **`Msg.LogLoaded.substrate` のみ**、reducer が Model へ所有権を **move（take）** できる。このため純粋 reducer `update` は `msg: *Msg`（ポインタ渡し）で、`Msg.LogLoaded.takeSubstrate()` が substrate を null 化（disarm）して `Msg.deinit` の二重解放を防ぐ。take は stale reject 通過後・Model 適用成功後に限定。**`AppCmd` は現行どおり**（解釈器が複製所有）。他の Msg バリアントへ move 例外を広げる場合は**個別 spec + `takeXxx()` helper + `checkAllAllocationFailures` による OOM safety test を必須**とする。

## 描画の gotcha（過去に表示崩れバグを生んだ箇所）
- **`view.fitPane` は各行をペイン幅に切り詰める**。切り詰めを外すと長い diff 行がオーバーフロー→端末折り返し→上段がスクロールアウトする。
- **`renderChanges`/`renderDiff` は `zz.joinVertical` を使わずプレーン `\n` 結合**（joinVertical は全行を最長行幅にパディングし、短い行にも余計な切り詰め "..." が付くため）。パディングは `place` に一任。
- zigzag: `ctx.allocator` は**毎フレーム arena**（一時文字列用）、ステートフル要素は `ctx.persistent_allocator`。`TextArea` に Ctrl+S サブミットは無く、アプリ側で Ctrl+S を横取りする。
- ファイル一覧は `model.zig replaceFiles` で **section→path 順にソート**済み（格納順 == 表示順 = j/k 連続移動の前提）。

## 進め方
- 機能追加は「純粋層（model/update/messages/appcmd/git）を TDD →（必要なら）view/input/main を配線」の順。
- 対話 TUI は非 tty で目視確認できない → 実 pty 検証は `tmux`（`new-session -x W -y H` → `send-keys` → `capture-pane -p`）。
