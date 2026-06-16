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
- [ ] untracked ファイルのハンク stage（intent-to-add `git add -N`）（phase 2）
- [x] パッチ生成のユニットテスト（コンテキスト行・改行末尾・日本語を含む差分）
- [ ] rename ファイルのハンク stage（phase 2: file_header の rename 行を扱う）

### 留意点
- パッチのコンテキスト行・`\ No newline at end of file`・CRLF の扱いに注意。
- 日本語を含む行でもバイトオフセットではなく行単位でパッチを組む。
- **phase 1 の既知の制約（phase 2 で対応）**:
  - 一時パッチを `<repo_root>/.git/` に書くため、linked worktree / submodule（`.git` がファイル）ではハンク stage が失敗する。実 git-dir 解決（`git rev-parse --absolute-git-dir`）またはシステム tmpdir 絶対パス書込で対応予定。
  - `focus!=.diff`（changes フォーカス）で `Ctrl+d/u` を多用すると `diff_scroll` が diff 行数を超え得る。その状態の diff ペインクリックは範囲外で no-op（誤選択にはならない）。根治は reducer の `scroll_diff_down` で diff 行数クランプ。
  - `input.fromZigzagMouse` の戻り値 MouseEvent リテラルが分岐ごとに重複しており、フィールド追加時に漏れやすい。ベースを 1 度組んで `.kind` だけ差し替える factoring を検討。
  - **行単位 stage の phase 2 で未対応（さらに将来）**:
    - 飛び飛び（discontiguous）のマーク集合選択（チェックボックス型）。現状は連続レンジのみ。
    - マウスのドラッグ範囲拡張 / Shift クリック範囲拡張（`MouseEvent` に修飾キーフィールド追加が前提。現状クリックはカーソル移動のみ）。
    - No-newline 境界に掛かる選択は矛盾パッチ回避のため no-op（ガイダンス表示）。

---

## TODO 2. ログ / コミットグラフ表示

### Goal
コミット履歴をグラフ（ブランチの分岐・マージ）付きで表示し、コミットを選択すると
その diff を閲覧できるようにする。

### Description
JetBrains の Git Log 相当。コミット列・作者・日時・メッセージ・参照（ブランチ/タグ）を
表示し、選択コミットの変更ファイルと diff を見られる。

### Sub Tasks
- [ ] コミット取得: `git log --pretty=format:%H%x00%P%x00%an%x00%at%x00%s -z` で
      (hash, 親hash列, author, 日時, subject) を NUL 区切りで取得・パース
- [ ] **グラフレーン割り当てアルゴリズムの選定**:
      (A) `git log --graph` の ASCII 出力をパースする方式（実装容易だが脆い）
      (B) 親子関係から自前でレーンを割り当てて罫線描画する方式（堅牢だが実装重い）
      → 推奨は (B)。各コミットの親を辿りレーン（列）を確保・解放し、分岐/マージを罫線文字で描く
- [ ] グラフ描画（`│ ├ ┐ ┘ ╮ ╯` 等の罫線文字でブランチの分岐・マージを表現、色分け）
- [ ] コミット選択 → 変更ファイル一覧（`git show --name-status`）→ diff 表示
- [ ] フィルタ（ブランチ / 作者 / 日付 / パス）
- [ ] 参照（HEAD / ブランチ / タグ）のラベル表示（`git log --decorate` 相当）
- [ ] **ページング / 遅延読み込み**: `--max-count` と `--skip`、またはスクロール到達で追加取得
- [ ] マウスでコミット選択・スクロール
- [ ] 日本語の作者名・コミットメッセージ・参照ラベルの桁計算（東アジア文字幅）

### 留意点
- グラフ描画は描画コストが高くなりがち。大規模リポジトリでは初期に N 件のみ取得し、
  スクロールで追加ロードする（全件をメモリに展開しない）。
- レーン割り当ては「同時に生存する分岐数」がレーン数になる。色はレーン番号でローテーション。
- マージコミット（親 2 つ以上）の罫線合流表現が描画の難所。代表的な分岐/マージ履歴で要テスト。

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
