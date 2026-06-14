# git-tui 設計ドキュメント

- 日付: 2026-06-14
- ステータス: 承認待ち（spec レビュー）
- 対象: JetBrains IDE 付属 git GUI 相当の機能を TUI で提供するツール

## 1. 概要 / 目的

JetBrains IDE（IntelliJ / GoLand など）に付属する git GUI のような操作感を、
ターミナル上の TUI として提供する。マウス操作にも対応する。

**MVP のゴール**: 変更ファイルの一覧表示・ファイル単位の stage/unstage・diff 閲覧・
コミットを、キーボードとマウスの両方で快適に行えること。

将来的にログ/コミットグラフ表示、Drag&Drop interactive rebase、ACP による
コミットメッセージ生成を追加する（本 spec では MVP 外。詳細は `TODO.md`）。

## 2. スコープ

### MVP に含む

- 変更ファイル一覧（staged / unstaged / untracked の区別）
- **ファイル単位**の stage / unstage
  - 同一ファイルが staged 変更と unstaged 変更を**同時に**持ちうる（porcelain v2 が X/Y 別々に報告）。
    Model は `(path, section)` をキーとし、Staged 行と Unstaged 行を別エントリとして扱う。
- 選択ファイルの diff 閲覧（読み取り専用、スクロール可）
  - **Staged 行を選択 → `git diff --cached`**、**Unstaged 行を選択 → `git diff`** を右ペインに表示する。
  - **untracked ファイル**は `git diff` が空を返すため、`git diff --no-index -- /dev/null <path>`
    （exit code 1 が正常）で全行を「追加」として表示する。
- 複数行コミットメッセージ入力とコミット実行
- 空リポジトリ（HEAD なし = 初回コミット、親なし）への対応
- **マウス操作**（クリックで選択・フォーカス、ダブルクリックで stage/unstage、diff のホイールスクロール）
- **日本語対応**（東アジア文字幅・全角/半角の正しい桁計算、マルチバイト入力、
  ファイルパスや diff・コミットメッセージ中の日本語表示）

### MVP に含まない（`TODO.md` に詳細記載）

- 部分ステージング（ハンク単位・行単位）
- ログ / コミットグラフ表示
- Drag&Drop interactive rebase
- ACP（Agent Client Protocol）によるコミットメッセージ生成
- ブランチ操作（作成/切替/マージ）、stash、cherry-pick、blame、コンフリクト解決
- **変更の破棄（Rollback / discard、`git restore <path>`）**: JetBrains では stage/unstage の隣に
  ある一般的操作だが、破壊的（未コミットの変更が消える）なため MVP からは意図的に除外し、
  確認ダイアログ付きで将来追加する（`TODO.md` 参照）。

### MVP 受け入れ基準（完成判定）

以下がすべて満たされれば MVP 完成とする。

1. git リポジトリ内で起動すると、変更ファイルが Staged / Unstaged / Untracked に分かれて表示される。
2. ファイルを選択すると右ペインに適切な diff が出る（Staged→`--cached` / Unstaged→通常 /
   Untracked→`--no-index` の追加表示）。
3. キーボードのみで stage → unstage → コミットメッセージ入力 → コミット まで完結できる。
4. **空リポジトリ（HEAD なし）で初回コミットが完了できる**。
5. **日本語ファイル名のファイルを stage → diff 表示 → commit でき、桁ずれが起きない**。
   コミットメッセージに日本語を入力・編集・コミットできる。
6. マウス対応端末でクリック選択・ダブルクリック stage・ホイールスクロールが動く。
7. **マウス無効/非対応端末でも、キーボードのみで上記すべてが完結する**。
8. git コマンド失敗時に stderr が表示され、Model の状態が壊れない。
9. パーサ単体テスト・Update 遷移テスト・一時リポジトリへの結合テストが通る
   （`std.testing.allocator` でリークなし）。

## 3. 技術選定

### 言語: Zig 0.16.0

`mise.toml` で固定（`zig = "0.16.0"`）。

### TUI フレームワーク: zigzag

- リポジトリ: https://github.com/meszmate/zigzag （v0.1.5, 2026-05）
- Bubble Tea / Lipgloss 着想の Elm アーキテクチャ（Model-Update-View）
- Zig 0.16+ 対応
- マウストラッキング対応
- Unicode 幅戦略（`legacy_wcwidth` / `unicode`）+ DEC mode 2027 プローブ +
  環境変数 `ZZ_UNICODE_WIDTH=auto|legacy|unicode` → **東アジア文字幅（日本語）対応**
- `TextInput` / `TextArea`（複数行）コンポーネント → コミットメッセージ欄に利用
  - v0.1.3 で「Form: submit on Ctrl+S（あらゆる端末で動作）」が追加されており、
    本ツールの `Ctrl+S` コミット採用と整合する。
- 退避案: libvaxis（より枯れているが複数行入力は自前実装が必要）

#### 着手前の必須前提（dependency spike）★ブロッカー

実装フェーズに入る前に、以下を**最初のタスク**として完了させる（現状リポジトリには
`build.zig` / `build.zig.zon` が無い）。

1. `build.zig` / `build.zig.zon` を作成し、**zigzag を v0.1.5 のタグ または対応コミット SHA で固定**
   （`zig fetch --save` で取得したハッシュを `build.zig.zon` に記録。再現性のため SHA 固定を優先）。
2. 「Hello world + キー入力 + マウス入力 + 全角文字を含む TextArea」が **Zig 0.16.0 で実際にビルド・起動**
   することを確認するスパイクを作る。
3. 本 spec が依存する zigzag の API を、**固定したリビジョンの実ソースで実在確認**する:
   - `Cmd(Msg)` の正確なシグネチャ（§4 の前提）
   - `Program.run()` / `update(...)` のシグネチャと、非同期実行手段（`AsyncRunner` 等が
     あるか）→ §4 のランタイムアダプタ設計に直結
   - `TextArea` の API・`Ctrl+S` サブミット・マルチバイトカーソル
   - マウス（SGR）有効化/無効化 Cmd と入力イベント型、custom I/O（ヘッドレステスト用）
   - 確認結果を §4 / §9 に反映し、相違があれば設計を修正する。

### git バックエンド: git CLI への委譲

`git` コマンドを子プロセスで実行し、出力をパースする。

- 採用理由:
  - C 依存（libgit2）を持ち込まない
  - **コミットフックが自動で走る**
  - 空リポジトリ（親なし初回コミット）にそのまま対応できる
- 使用コマンド例:
  - 状態取得: `git status --porcelain=v2 -z`（NUL 区切り、リネーム/コピー判定込み）
  - HEAD 有無判定: `git rev-parse --verify HEAD`（exit 0 = HEAD あり / 非0 = 空リポジトリ）。
    この結果で unstage コマンドを分岐する。
  - ブランチ名: `git symbolic-ref --short HEAD`（HEAD なし時も unborn ブランチ名を返す）
  - diff（unstaged）: `git diff -- <path>`
  - diff（staged）: `git diff --cached -- <path>`
  - diff（untracked）: `git diff --no-index -- /dev/null <path>`（exit 1 が正常）
  - stage: `git add -- <path>`（untracked も同じ）
  - unstage: HEAD ありなら `git restore --staged -- <path>`、
    **空リポジトリ（HEAD なし）なら `git rm --cached -- <path>`**
    （unborn HEAD では `restore --staged` が exit 128 で失敗するため。実測確認済み）
  - コミット: `git commit -F -`（メッセージを stdin で渡す）
- 退避: libgit2（MVP では採用しない）

#### porcelain=v2 `-z` パーサの注意点（バグ要因）

- レコード種別ごとにフィールド数が異なる: `1`（通常変更）/ `2`（rename/copy）/
  `u`（未マージ）/ `?`（untracked）/ `!`（ignored）。
- **`2`（rename/copy）レコードは NUL 区切りのパスを 2 つ消費する**
  （`<path>\0<origPath>\0`）。NUL で素朴に split すると最初の rename 以降で全エントリがずれる。
  種別が `2` のときだけ次トークンを origPath として消費する状態機械が必須。
- **untracked は行頭 1 文字 `?`**（`??` は porcelain v1 の表記。混同しないこと）。
- パーサは文字列入力に対する単体テストの代表ケースとして、M/A/D/`?`/rename/日本語パスを含める。

#### rename/copy エントリの取り扱い（パーサで止めない）

`origPath` をパースして捨てるのではなく、**status エントリに保持**し、コマンドへ正しく渡す。

- Model のファイルエントリは rename の場合 `{ path（新）, orig_path（旧）, section }` を持つ。
- **stage**: rename を 1 操作として確定するため、`git add -- <新path> <旧path>` のように
  **両方のパスを pathspec に渡す**（旧パスの削除＋新パスの追加を同時にステージ）。
- **unstage**: 同様に新旧両パスを対象にする（HEAD あり: `git restore --staged -- <新> <旧>`）。
- **diff**: rename は `git diff [--cached] -- <新> <旧>` で両側を表示。
- 結合テストに **staged / unstaged の rename ケース**を必ず含める（片側だけ操作して
  予期せぬステージ残りが出ないことを検証）。

## 4. アーキテクチャ（層構成）

Elm アーキテクチャの各要素に層をマッピングする。

```
+-----------------------------------------------+
| View 層 (zigzag: パネル描画)                    |  ← 端末必須・自動テスト対象外
+-----------------------------------------------+
| Update 層 (Msg → 状態更新 + AppCmd発行)         |  ← 純粋関数・テスト可能
|   入力(キー/マウス) を Msg に正規化する部分も含む  |
+-----------------------------------------------+
| Model (repo state model)                       |  ← テスト可能（所有権は下記方針）
|   ファイル一覧[(path,section)] / 選択 / diff /   |
|   ブランチ名 / HEAD有無 / コミットメッセージ /     |
|   フォーカス位置 / マウス有効フラグ / エラー表示    |
+-----------------------------------------------+
| AppCmd 解釈器 (side-effect runner)              |  ← 端末不要・結合テスト可能
|   AppCmd を解釈し git backend を実行 → Msg 再注入  |
+-----------------------------------------------+
| git backend (CLI 実行 + porcelain v2 パース)    |  ← 純粋（パース部）・テスト可能
+-----------------------------------------------+
```

### 副作用の扱い（zigzag の Cmd 制約への対応）★重要

zigzag の `Cmd(Msg)` は `perform: *const fn () ?Msg`、すなわち**引数もキャプチャも持たない
素の関数ポインタ**であり、`git add -- <path>` のように「パス」「allocator」を渡す副作用を
zigzag の Cmd として直接表現できない（プロセス起動用の async Cmd も無い。zigzag ソース実読で確認）。

そこで **Update は zigzag の Cmd を返さず、自前の `AppCmd` enum を返す**設計にする。

- `AppCmd` 例: `.refresh_status`, `.stage{path}`, `.unstage{path}`, `.load_diff{path, section}`,
  `.commit{message}`。
- main ループ（`AppCmd` 解釈器）が `AppCmd` を受け取り、git backend を実行し、
  結果を `Msg`（例: `.status_loaded{...}`, `.git_error{stderr}`）として Model へ再注入する。
- これにより **Update 関数は純粋**（Model と Msg → 新 Model と AppCmd）に保たれ、端末も git も
  使わずに単体テストできる。git の実行は解釈器（端末不要）に隔離され、一時リポジトリへの
  結合テスト対象となる。

#### zigzag ランタイムへの接続（アダプタ）★要スパイク確認

zigzag は `Program.run()` がイベントループを所有し、`update(...)` は `zz.Cmd(Msg)` を返す前提。
本ツールの純粋 reducer（`Model + Msg → Model + AppCmd`）をこのコールバックに橋渡しするアダプタを
`src/main.zig` に置く。具体的な配線は **dependency spike（§3）で zigzag の実 API を確認してから確定**
するが、方針は以下:

- zigzag の `update` コールバック内で純粋 reducer を呼び、返ってきた `AppCmd` を
  **アダプタが zigzag の実行手段に変換**する（zigzag 側 Cmd / `AsyncRunner` 等の有無で実装が変わる）。
- **同期実行で git を呼ぶと、遅い git 操作やコミットフック中に入力・描画がフリーズする**。
  これを避けるため、git 実行は**ワーカースレッド（または zigzag の非同期 Cmd）で行い**、
  完了時に結果 `Msg`（`.status_loaded` / `.diff_loaded` / `.git_error`）をイベントキューへ
  注入してメインループに戻す。実行中は Model に `busy` フラグを立て、UI にローディング表示。
- **コマンドの直列化**: 同種の副作用（連続 stage など）が競合しないよう、解釈器は
  AppCmd を 1 本のキューで順次処理する（並行 git 実行はしない）。
- 注入手段（外部スレッド → イベントループ）が zigzag に無い場合は、メインループの tick で
  完了済みワーカー結果をポーリングして Msg 化するフォールバックを採る。

### Model の所有権・メモリ管理（Zig: GC なし）★重要

Elm の純粋性は GC 前提だが Zig には GC が無いため、Model 内の文字列（ファイルパス・diff 本文・
コミットメッセージ）の allocator とライフタイムを明示する。

- Model が保持する文字列は **persistent allocator 所有**とし、状態置換時に**旧データを明示的に free**
  してから新データをセットする（diff の再読み込み・status の再取得時など）。
- フレームごとに作る一時文字列（描画整形など）は **arena（毎フレームリセット）** に置く。
- 全テストは `std.testing.allocator`（リーク検出）で実行し、use-after-free / leak を検出する。

#### Msg / AppCmd ペイロードの所有権規約（dangling/leak 防止）★重要

「Update は純粋」とは **I/O を行わない**意味であり、メモリ確保が無いという意味ではない。
ペイロードの所有権を明文化し、Model の再構築（status 再取得等）が進行中コマンドの参照を
壊さないようにする。

- **AppCmd のペイロード（path / message 等）は Model のスライスを借用せず、必ず複製して所有する**
  （`.stage{ path: owned []u8 }` のように）。これにより、解釈器が git を実行する前に Model が
  置換・解放されても dangling しない。
- 各 `AppCmd` / `Msg` は `deinit(allocator)` を持ち、**解釈器は処理後に AppCmd を、Update は
  消費後に Msg を、それぞれ free する**（生成者ではなく消費者が解放、を原則とする）。
- 複製に使う allocator は persistent。複製・解放の往復は `std.testing.allocator` でリーク検証する。
- リネームの `origPath` も同様に所有権を持って複製する（下記 §3 パーサ参照）。

### 設計上の合格基準（テスト容易性）

- **端末なしで** 「stage → unstage → commit」サイクルを駆動できること:
  Update 関数（純粋）の遷移テスト + AppCmd 解釈器を一時 git リポジトリに対して回す結合テスト。
- git backend のパース部（`porcelain=v2` → ファイルリスト）は文字列入力で
  単体テスト可能であること。
- View 層（zigzag 依存）にはロジックを置かない。

### モジュール分割（暫定）

- `src/git/` — git CLI 実行と出力パース（state model に依存しない純粋寄りのモジュール）
  - `process.zig` — 子プロセス実行ラッパ
  - `status.zig` — `porcelain=v2` パーサ
  - `diff.zig` — diff 取得
  - `commands.zig` — add/restore/commit ラッパ
- `src/model.zig` — Model 定義（状態）と所有権/メモリ管理
- `src/update.zig` — Msg 定義と Update 関数（純粋: Model+Msg → Model+AppCmd）
- `src/appcmd.zig` — `AppCmd` enum 定義と解釈器（git backend を実行し Msg を再注入）
- `src/view.zig` — zigzag を用いた描画
- `src/input.zig` — キー/マウスイベント → Msg 正規化
- `src/main.zig` — 起動・zigzag ランタイム接続・Update↔AppCmd 解釈器の配線
- `src/width.zig` — 文字幅ユーティリティ（必要なら zigzag の機能を薄くラップ）

## 5. 画面レイアウト

lazygit 風の 2 ペイン + コミット欄。

```
+- Branch: main -----------------------------------------+
|+- Changes -----------++- Diff -----------------------+|
|| Staged              || diff --git a/src.zig b/src.zig||
||  M src/main.zig     || @@ -1,4 +1,6 @@               ||
|| Unstaged            || + 追加された行                  ||
||  M README.md        || - 削除された行                  ||
||  ? new_file.txt     ||   コンテキスト                  ||
|+---------------------++-------------------------------+|
|+- Commit message --------------------------------------+|
|| (複数行入力 / 日本語可)                                  ||
|+--------------------------------------------------------+|
| [space]stage [c]入力 ^S=commit [j/k]移動 [tab]ペイン [q]終了|
+--------------------------------------------------------+
```

- 左ペイン: 変更ファイル一覧（Staged / Unstaged / Untracked をセクション分け）
- 右ペイン: 選択中ファイルの diff（スクロール可）
- 下部: 複数行コミットメッセージ欄（`TextArea`）
- 最下行: ステータスバー / キーヒント

## 6. 操作モデル

### フォーカスとキー捕捉（重要）

UI は **Changes / Diff / Commit** の 3 フォーカスを持つ。グローバルキー（`j` `k` `s`
`space` `r` `c` `q` など）は **Changes / Diff フォーカス時のみ有効**。

- **Commit フォーカス時は、編集キー（文字入力・カーソル移動・Backspace 等）以外の
  グローバルキーを TextArea が吸収し、無効化する**（`q` 等を押しても終了しない）。
  Commit から離脱するのは `Esc` または `Tab`、コミット実行は `Ctrl+S` のみ。
  これにより日本語入力中の誤爆を防ぐ。

### キーボード（完全なパス・必須）

通常（Changes / Diff フォーカス）:
- `j` / `k`（または ↑/↓）: ファイル一覧の選択移動
- `space` または `s`: 選択ファイルの stage / unstage トグル
- `tab`: ペイン間フォーカス移動（Changes → Diff → Commit → Changes）
- `c`: コミットメッセージ欄（Commit）へフォーカス
- diff ペインで `Ctrl+d` / `Ctrl+u`: スクロール
- `r`: 再読み込み（status 再取得）
- `q`: 終了

Commit フォーカス時:
- 文字入力 / カーソル移動 / Backspace 等: テキスト編集
- `Ctrl+S`: コミット実行（メッセージ空なら実行せずエラー表示）
- `Esc` / `Tab`: Commit から離脱（フォーカスを戻す）

※ コミット実行に `Ctrl+Enter` は使わない（多くの端末で Enter と区別できるコードを
送出しないため）。確実に送出される `Ctrl+S` を採用する。

### マウス（MVP から対応・追加機能）

- ファイル行クリック: 選択
- ファイル行ダブルクリック: stage / unstage トグル（閾値はアプリ側で実装、例: 300ms）
- ペインクリック: フォーカス移動
- diff ペインのホイール: スクロール
- **設計方針（グレースフルデグレードの再定義）**: SGR マウス対応を端末に確実に
  問い合わせる手段は実質無い（enable して祈る形）ため、「検出して自動無効化」は前提にしない。
  代わりに **(1) キーボードのみで全操作が常に完結することを保証**し、**(2) マウスは設定で
  オプトアウト可能**とし、**(3) 未パースのマウス由来バイトを TextArea 等の入力へ流さない**
  ことで、部分対応・旧式エンコーディング端末でも破綻しないようにする。

## 7. 日本語 / Unicode 対応

- 文字幅は zigzag の Unicode 幅戦略に委ねる（init 時に `option → ZZ_UNICODE_WIDTH → auto`
  の順で解決。`ZZ_UNICODE_WIDTH=auto|legacy|unicode` で上書き可能とドキュメント化）。
- **CJK 漢字・かな・全角は legacy/unicode いずれの戦略でも常に 2 セル幅**で正しく扱われる
  （zigzag ソース確認済み）。日本語表示の基本動作は安定する。
- ファイルパス・diff 本文・コミットメッセージはすべて UTF-8 を前提に表示。
- コミットメッセージ欄（`TextArea`）はカーソルがバイトオフセット方式だが UTF-8 境界処理は
  正しく、**日本語の入力・カーソル移動・削除は動作する**（zigzag ソース確認済み）。

### 既知の制約（MVP では許容し、明記しておく）

- **East Asian Ambiguous 幅は zigzag では narrow 固定**。legacy/unicode 戦略の差は主に
  BMP 記号・Dingbats であり、Ambiguous 文字を全角端末に合わせる切替は効かない。
  一般的な日本語（漢字/かな/全角）には影響しない。
- **全角文字上のカーソル描画**は反転 1 セル固定で、2 セル幅文字の片側だけが反転しうる
  （表示上の見た目のみ。編集動作は正しい）。→ 実装時に要検証項目として残す。
- **grapheme cluster 非対応**: 結合文字（`e`+結合アクセント）や絵文字 ZWJ シーケンスは
  コードポイント単位で移動/削除される。日本語の通常テキストには影響しないため MVP では許容。

## 8. エラー処理 / 起動時のリポジトリ解決

- **リポジトリルートと作業ディレクトリ**: 起動時に `git rev-parse --show-toplevel` でリポジトリ
  ルートを特定する。サブディレクトリから起動された場合でも、status / diff のパスは
  **ルート相対で統一**して扱う（porcelain v2 はルート相対でパスを返す）。git コマンドは
  ルートを cwd にして実行するか `-C <root>` を付ける。
- カレントディレクトリが git リポジトリでない場合（`--show-toplevel` が非0）:
  明確なエラーメッセージを出して終了。
- git コマンドが非 0 終了した場合: stderr をステータスバーまたはモーダルに表示し、
  Model の状態は変更しない（楽観更新せず、成功時のみ再取得）。
- 空リポジトリ（HEAD なし）: ブランチ名取得・unstage・diff のフォールバック経路を用意。

## 9. テスト方針

### 自動テスト
- git backend パーサ: `porcelain=v2` の代表的出力（M/A/D/`?`/rename(`2`=2パス)/日本語パス）に
  対する単体テスト。
- Update 関数: Msg 列を与えて Model 遷移を検証（端末不要）。`std.testing.allocator` でリーク検出。
- 結合: 一時ディレクトリに `git init` した実リポジトリへ stage/unstage/commit を流す
  シナリオテスト。最低限カバーするケース:
  - 空リポジトリ初回コミット（unborn HEAD）
  - **rename の staged / unstaged**（新旧両パスが正しく扱われる）
  - untracked ファイルの stage と `--no-index` diff
  - **サブディレクトリからの起動**（リポジトリルート解決が効く）
  - git コマンド失敗時に Model が壊れない
- **ヘッドレス UI/イベントテスト**（zigzag の custom I/O が利用可能なら）:
  合成したキー/マウスイベント列を流し、(a) フォーカス遷移、(b) マウスのヒットテスト、
  (c) Commit フォーカス時のグローバルキー無効化、(d) 全角を含む行のレンダリング桁、を検証。
  ※ custom I/O の有無は §3 スパイクで確認し、無ければ View ロジックを純粋関数へ切り出して検証。

### 手動検証マトリクス（自動化が難しい領域）
- 端末 × マウス: SGR 対応端末 / 非対応端末 / tmux 経由 でクリック・ダブルクリック・ホイール。
- 端末 × 日本語: 全角を含むパス・diff・コミットメッセージの桁ずれ、TextArea のカーソル位置。
- リサイズ・diff の長文スクロール。

## 10. 将来 TODO（`TODO.md` に詳細）

1. 部分ステージング（ハンク / 行単位）
2. ログ / コミットグラフ表示
3. Drag&Drop interactive rebase
4. ACP（Agent Client Protocol）コミットメッセージ生成
5. 変更の破棄（Rollback / discard、確認ダイアログ付き）

各 TODO は Goal / Description / Sub Tasks / 留意点を `TODO.md` に記載する。
