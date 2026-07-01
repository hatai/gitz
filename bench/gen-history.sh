#!/usr/bin/env bash
# 大規模履歴ジェネレータ (Phase 0 perf-tuning・spec §4.2)。
# 6 プロファイル × {1千, 1万, 10万} コミットのリポジトリを bench/repos/<profile>-<n>/ へ生成。
# 各 repo で substrate (git rev-list --topo-order --parents HEAD) と log commits をファイルへ保存。
# bench.zig (Phase 0 Task 4) がこれらのファイルを読んでフェンス計測を行う。
#
# 使い方: ./bench/gen-history.sh <profile> <count> <out_dir>
#   profile: linear | wide-branches | periodic-merge | path-filter-sparse | author-filter-sparse | long-subject-refs
#   count:   コミット数 (例: 1000, 10000, 100000)
#   out_dir: 出力ディレクトリ (例: bench/repos/linear-1000)
#
# 10万コミットは数十分かかる場合あり（手動実行・CI では走らせない）。bench/repos/ は .gitignore 対象。
set -euo pipefail

PROFILE="${1:?profile required (linear|wide-branches|periodic-merge|path-filter-sparse|author-filter-sparse|long-subject-refs)}"
COUNT="${2:?count required (e.g. 1000)}"
OUT="${3:?out_dir required (e.g. bench/repos/linear-1000)}"

# 共通: リポジトリを (re)initialize。
init_repo() {
    rm -rf "$OUT"
    mkdir -p "$OUT"
    git -C "$OUT" init -q
    # default branch 名が master/main 混在なので main へ統一。
    git -C "$OUT" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git -C "$OUT" config user.email "bench@git-tui.local"
    git -C "$OUT" config user.name "Bench Generator"
    git -C "$OUT" config commit.gpgsign false
}

# 共通: substrate と log をファイルへ抽出（commands.zig/log.zig の形式に合わせる・NUL 区切り）。
extract() {
    git -C "$OUT" rev-list --topo-order --parents HEAD > "$OUT/substrate.txt"
    # %H hash, %P parents (space), %an author name, %at author epoch, %s subject, %d refs
    # --topo-order は本番 commands.zig:93 logArgv と一致させるため（codex review Important）。
    git -C "$OUT" -c core.quotePath=false log --topo-order --pretty=format:'%H%x00%P%x00%an%x00%at%x00%s%x00%d' -z --decorate=short --no-color --max-count="$COUNT" > "$OUT/log.txt"
}

# linear: 親1 のみを N 件一直線。
gen_linear() {
    init_repo
    local i
    for i in $(seq 1 "$COUNT"); do
        git -C "$OUT" commit --allow-empty -q -m "commit $i"
    done
    extract
}

# periodic-merge: linear + 7件ごとに merge commit (parent 2) を挿入。
gen_periodic_merge() {
    init_repo
    local i
    for i in $(seq 1 "$COUNT"); do
        git -C "$OUT" commit --allow-empty -q -m "commit $i"
        if (( i % 7 == 0 )); then
            git -C "$OUT" branch -q tmp-merge
            git -C "$OUT" checkout -q tmp-merge
            git -C "$OUT" commit --allow-empty -q -m "side $i"
            git -C "$OUT" checkout -q main
            git -C "$OUT" merge -q --no-ff -m "merge $i" tmp-merge
            git -C "$OUT" branch -q -D tmp-merge
        fi
    done
    extract
}

# wide-branches: 10 本の branch を並行進行し最後に master へ merge → frontier 幅が最大。
gen_wide_branches() {
    init_repo
    local branches=10
    local i=1 b
    git -C "$OUT" commit --allow-empty -q -m "init"
    for b in $(seq 1 $branches); do
        git -C "$OUT" branch -q "feat-$b"
    done
    while (( i <= COUNT )); do
        for b in $(seq 1 $branches); do
            (( i > COUNT )) && break
            git -C "$OUT" checkout -q "feat-$b"
            git -C "$OUT" commit --allow-empty -q -m "feat-$b commit $i"
            i=$((i + 1))
        done
    done
    git -C "$OUT" checkout -q main
    for b in $(seq 1 $branches); do
        git -C "$OUT" merge -q --no-ff -m "merge feat-$b" "feat-$b" || true
    done
    extract
}

# path-filter-sparse: file_a/file_b を交互に変更。path filter で片方を指定すると visible が疎。
gen_path_sparse() {
    init_repo
    mkdir -p "$OUT"
    echo "a1" > "$OUT/file_a"
    echo "b1" > "$OUT/file_b"
    git -C "$OUT" add file_a file_b
    git -C "$OUT" commit -q -m "init files"
    local i
    for i in $(seq 2 "$COUNT"); do
        if (( i % 10 == 0 )); then
            echo "b$i" > "$OUT/file_b"
            git -C "$OUT" add file_b
        else
            echo "a$i" > "$OUT/file_a"
            git -C "$OUT" add file_a
        fi
        git -C "$OUT" commit -q -m "edit $i"
    done
    extract
}

# author-filter-sparse: 3 author で偏在 (Alice 80% / Bob 15% / Carol 5%)。
gen_author_sparse() {
    init_repo
    local i name email
    local names=("Alice" "Bob" "Carol")
    local emails=("alice@x" "bob@x" "carol@x")
    for i in $(seq 1 "$COUNT"); do
        if (( i % 20 == 0 )); then
            name="${names[2]}"; email="${emails[2]}"
        elif (( i % 7 == 0 )); then
            name="${names[1]}"; email="${emails[1]}"
        else
            name="${names[0]}"; email="${emails[0]}"
        fi
        git -C "$OUT" -c user.name="$name" -c user.email="$email" commit --allow-empty -q -m "$name commit $i"
    done
    extract
}

# long-subject-refs: 長い日本語 subject + 100件ごとに branch/tag で多数の refs。
gen_long_subject_refs() {
    init_repo
    local i
    local long_subject="これはパフォーマンス計測用の非常に長いコミットメッセージの件名です。East Asian Width 計算の負荷を測るため、わざと長くしています。本番のコミットメッセージには稀に長大な件名が含まれることがあり、それらの描画コスト（truncation・幅計算・スクロール）を正しく計測するための意図的な長文サンプルとして機能します。"
    for i in $(seq 1 "$COUNT"); do
        git -C "$OUT" commit --allow-empty -q -m "$long_subject (commit $i)"
        if (( i % 100 == 0 )); then
            git -C "$OUT" branch -q "ref-$i" 2>/dev/null || true
            git -C "$OUT" tag -q "tag-$i" 2>/dev/null || true
        fi
    done
    extract
}

case "$PROFILE" in
    linear) gen_linear ;;
    wide-branches) gen_wide_branches ;;
    periodic-merge) gen_periodic_merge ;;
    path-filter-sparse) gen_path_sparse ;;
    author-filter-sparse) gen_author_sparse ;;
    long-subject-refs) gen_long_subject_refs ;;
    *) echo "unknown profile: $PROFILE" >&2; exit 1 ;;
esac

echo "generated: $OUT ($COUNT commits, profile=$PROFILE)"
