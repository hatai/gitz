# git-tui

JetBrains の git GUI 相当の操作感を目指した、ターミナル上で動く git コミット支援 TUI（Zig 0.16 / [zigzag](https://github.com/) ランタイム）。Changes / Diff / Commit の 3 ペインでステージング・差分閲覧・コミットを行います。

## ビルド

```sh
zig build
```

配布・常用ビルドは最適化を有効にしてください。

```sh
# 配布・常用（推奨）: 速度最優先
zig build -Doptimize=ReleaseFast

# 安全性重視（実行時チェック付きで配布したい場合）
zig build -Doptimize=ReleaseSafe
```

既定の `optimize` は `Debug` のままです（`zig build test` の実行時安全性チェックを保つため）。

## 実行

git リポジトリ内（またはサブディレクトリ）で起動します。

```sh
zig build run
# もしくはビルド済みバイナリを直接
zig-out/bin/git-tui
```

オプション:

- `--no-mouse` : マウストラッキングを無効化する。

git リポジトリ外で起動した場合は、日本語のエラーメッセージを表示して終了コード 1 で終了します。

## テスト

```sh
zig build test
# 詳細サマリ付き
zig build test --summary all
```

## 操作キー

| キー | 動作 |
| --- | --- |
| `j` / `↓` | 次のファイルを選択 |
| `k` / `↑` | 前のファイルを選択 |
| `space` / `s` | 選択ファイルを stage / unstage トグル |
| `c` | コミットメッセージ欄へフォーカス |
| `r` | git status を再読み込み |
| `Tab` | ペイン間のフォーカス移動 |
| `Ctrl+D` | diff ペインを下へスクロール |
| `Ctrl+U` | diff ペインを上へスクロール |
| `q` | 終了 |
| `j` / `k`（diff フォーカス時） | ハンクカーソルを上下に移動 |
| `s` / `space` / `Enter`（diff フォーカス時） | 選択中ハンクを stage / unstage |
| `Ctrl+S` | コミット実行（コミットメッセージ欄フォーカス時） |
| `Esc` / `Tab` | コミット欄からフォーカスを戻す |

マウス操作（`--no-mouse` 未指定時）:

- ファイル行クリック: 選択
- ファイル行ダブルクリック: stage / unstage トグル
- diff ペイン上でホイール: diff スクロール
- 各ペインクリック: そのペインへフォーカス
- diff ペイン上でクリック: そのハンクを選択
- untracked / rename ファイルはハンク単位 stage 非対応（`space`/`s` でファイル単位 stage）

コミットメッセージ欄にフォーカス中は、文字入力・改行・カーソル移動などの編集キーはテキストエリアが処理し、グローバルキー（`q` 等）は無効化されます（日本語入力中の誤爆防止）。
