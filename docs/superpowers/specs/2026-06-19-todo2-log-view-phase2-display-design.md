# ログ / コミットグラフ表示 設計 — TODO 2 / phase 2（表示系: グラフ罫線 + East Asian Width + author/日時）

- 日付: 2026-06-19（rev.2: codex 第 2 段レビュー H-06(再)/H-07/H-02(再)/H-08/M-07(再)/M-01(再)/M-08..M-14/L-03..L-05 反映版）
- 対象: `TODO.md`「TODO 2. ログ / コミットグラフ表示」のうち **phase 2 の表示系**
  - グラフレーン割当アルゴリズム + 罫線描画（`│ ├ ┐ ┘ ╮ ╯` 等・色分け）
  - East Asian Width（東アジア文字幅）の桁計算
  - author / コミット日時の表示（phase 1 では Model 保持のみ・描画は phase 2 ヘ移行済み）
- 親設計:
  - `docs/superpowers/specs/2026-06-14-git-tui-design.md`
  - `docs/superpowers/specs/2026-06-18-todo2-log-view-phase1-design.md`（rev.9・**phase 1 完了版**・データ構造・所有権・stale-result reject・paging・H1-H7/R1-R26 規約を踏襲）
- 実 API: `docs/superpowers/plans/zigzag-api-notes.md`（**zigzag/std の実 API はこれが正**・計画書の擬似コードより優先）
- スコープ外:
  - フィルタ機能（branch/author/date/path）— 独立 spec で後日対応。UI 方針は「`f` キーでモーダル（JetBrains 風）」を予定知見として付記するのみ。
  - `--cc`（combined diff）等 detail 拡張
- 前提:
  - phase 1 実装（`src/git/log.zig`/`src/git/show.zig`/`src/git/commands.zig`/`src/model.zig`/`src/view.zig`/`src/input.zig`/`src/update.zig`/`src/messages.zig`/`src/main.zig`/`src/appcmd.zig`/`src/autorefresh.zig`）は完成済み。
  - `Commit.parents: [][]u8` は既に存在（phase 1 でグラフ描画の伏線として保持）。本設計はこれを活用する。

---

## 0. 用語と前提確認

- **lane（レーン）**: グラフの 1 列。分岐毎に新規レーンを確保し、マージで解放する。1 コミットは描画時に 1 つの lane に属する。
- **frontier（フロンティア）**: 「現在描画済みの最下行（= 直前のコミット）から下へ伸びる生きた親の集合」。レーン割当アルゴリズムが保持し、次行のレーン解決に使う。
- **commit graph node**: 1 コミットに対応するグラフ行。ノード文字（`*`/`●` 等）と、上下に伸びる罫線セグメントで構成される。
- **格納順 = git log 出力順**: `Model.log_commits.items` は git log（拓浦順・`--skip`/`--max-count` のページング結果）の出力順に格納される（phase 1 実装で確認済み）。phase 2 のレーン割当はこの順序を入力とする。**★rev.1 H-03**: frontier 法は「子が必ず親より先に現れる」ことを前提とするため、`logArgv` へ `--topo-order` を**追加指定**する（詳細は §A.3.8）。
- **dense frontier**: ★rev.1 M-01。frontier slot に `null` hole を作らず、親を追加する際は現 node lane の隣へ挿入し、消費/重複集約後に詰める方式。sparse（first-fit hole 探索）よりも単純で見た目が安定する。
- **GraphState**: ★rev.1 M-02。`generation`/`processed_len`/`rows`/`frontier` を 1 つの tagged union（`.invalid`/`.valid`）へ集約し、フィールド間の整合性を型で保証する。

---

## 0.1 codex 第 1 段レビュー反映の対応表（rev.0 → rev.1）

| ID | 重要度 | 内容 | 反映節 |
|---|---|---|---|
| H-01 | 高 | 共通親を持つ frontier の集約未定義（M←B,C・B,C←A で `[A,A]` 残存）→ 代表 lane へ集約し残りを削除 | §A.3.3, §A.3.6 |
| H-02 | 高 | `Edge` 4 種では接続表現不足（`┬ ┴ ┼ ─` 水平接続・交差不可）→ before/after frontier 遷移 + cells bitset | §B.1 |
| H-03 | 高 | `--topo-order` 未指定で親が子より先に現れるリスク → `logArgv` へ追加 | §A.3.8, §B.4 |
| H-04 | 高 | `computeIncremental` OOM で frontier が部分更新され再試行不能 → 一時状態計算 → swap | §A.3.4, §B.1, §E.1 |
| H-05 | 高 | commits と graph の更新が非トランザクショナル → graph OOM は reducer で catch・commits 採用・graph を `.invalid` へ | §E.1 |
| H-06 | 高 | page 間で tip hash が動くと frontier 壊れる → tip hash を paging owner として保持し `git log` を同 revision へ固定 | §B.5, §E.6 |
| M-01 | 中 | sparse frontier + first-fit は複雑 → dense frontier（隣挿入＋詰め） | §A.3.6 |
| M-02 | 中 | `log_graph_valid` 等の 3 フィールドは不正状態を表現可能 → `GraphState` tagged union | §B.1 |
| M-03 | 中 | `appendLogCommits` が既存全 clone で O(N²) → graph 増分と並行して commit append の最適化を検討 | §G.6 |
| M-04 | 中 | レーン上限は計算と描画で分離 → 計算は全 lane 保持・描画時のみ射影 | §D.3, §G.1 |
| M-05 | 中 | 80 桁端末/32 桁 log ペインで固定カラムが subject を圧迫 → 段階的カラム省略 | §D.2 |
| M-06 | 中 | subject が「残り全幅」で refs が常に truncate → refs を subject 前/上限予約幅 | §D.2 |
| M-07 | 中 | date の意味（author/committer）と timezone が未確定 → `%aI` 等で offset 取得 or UTC 固定 | §D.7 |
| L-01 | 低 | 方式 A の却下理由が不正確（`--graph` と `-z` は現 git 2.54 では併用可）→ 却下理由を「paging と状態継承の不整合/非構造化出力/ordering への影響」へ | §A.2.4 |
| L-02 | 低 | lane 色 16/8 が矛盾・branch identity ではない明示 → 6-8 色固定パレット・視認補助 | §D.3 |

### 0.2 第 2 段レビュー（rev.1 → rev.2）で追加反映

| ID | 重要度 | 内容 | 反映節 |
|---|---|---|---|
| H-06(再) | 高 | page先頭==前ページ末尾親の検証が topo-order でも保証されない（正常履歴を誤判定）→ 検証削除・tip+generation+skip で snapshot 保証 | §E.6 |
| H-07 | 高 | tip hash が stale-result owner に含まれない → 結果 Msg へ `request_tip` 追加・generation と一体化して paging owner 定義 | §E.6, §B.5 |
| H-02(再) | 高 | GraphRow の before/after/cells 描画契約未定義 → 1 コミット=1 表示行・cells は表示行全体の接続 bitset と明記 | §B.1 |
| H-08 | 高 | `computeIncremental` が既存 rows 全 deep-copy で O(N²) → delta rows + frontier 一時構築 → append/swap | §B.1, §E.1 |
| M-07(再) | 中 | Zig 0.16 に `std.time.local` 相当 API 無し → phase 2 は UTC 固定（`%aI` 由来 offset は将来） | §D.7 |
| M-01(再) | 中 | dense frontier の interior hole 処理不備 → 行処理後に全 null slot を左詰め | §A.3.3 |
| M-08 | 中 | `lane_count = after_cells.len` が不正 → 行幅は `max(before, after, node_lane+1)` | §B.1 |
| M-09 | 中 | lane index 移動で `lane mod 6` 色が行途中で変わる → 色変化を仕様受容 or frontier slot へ color id 保持（将来） | §D.3 |
| M-10 | 中 | tip hash の所有権・OOM 手順不足 → `LoadLogPage` 独立所有型・tip dupe + `AppCmd.deinit` で解放・dupe 成功後に `log_page_requested` 設定 | §B.5, §E.6 |
| M-11 | 中 | `.invalid` 回復分岐が手順に無い → `log_page_loaded` を `.valid→incremental`/`.invalid→computeAll(items)` の switch へ | §E.1 |
| M-12 | 中 | tip 消失（gc）時の回復無し → bad revision 検出で generation 進め tip/commits/graph clear・初回 load へ | §E.6 |
| M-13 | 中 | 60 桁「全カラム」が成立しない → 最小 subject 幅を先予約・残幅から諸カラム採用 | §D.2 |
| M-14 | 中 | GraphState は整合性全てを型保証しない → runtime invariant 明記・compute/描画入口で assert or reject | §B.1 |
| L-03 | 低 | 6 色パレットは theme 依存で低コントラストあり → 色無しでも形で判別・node bold 併用 | §D.3 |
| L-04 | 低 | 省略セル `⋮`/`…` が未確定 → 1 つに確定し `zz.width` で検証・ASCII fallback | §D.3 |
| L-05 | 低 | OOM テスト適用範囲が曖昧 → graph 関数は全 alloc failure 網羅・reducer は failing allocator または失敗位置限定 | §F.1, §F.2 |

---

## A. レーン割当アルゴリズム比較（subagent 起案・codex 確定対象）

### A.1 共通の問題設定

入力: コミット列 `C_0, C_1, ..., C_{n-1}`（新しい順・`log_commits.items` と同じ順序）。
各 `C_i` は `(hash, parents: []const hash)` を持つ。目的: 各 `C_i` に `lane(C_i): u16`（レーン番号・0 起点）を割り当て、グラフの上下セグメントを box-drawing 文字で描けるようにする。

### A.2 方式 A: `git log --graph` ASCII 出力をパースする方式

#### A.2.1 アプローチ
phase 1 の `logArgv`（NUL 区切り `--pretty=format:`）とは別に、グラフ描画用の補助コマンド `git log --graph --format=%H ...` を発行し、その ASCII 出力（`*`/`|`/`/`/`\` 等）からレーン情報を復元する。各コミット行の `hash` と ASCII 行を対応付ける。

#### A.2.2 出力例（想定）
```
* abc1234 (HEAD -> main) commit 3
| * def5678 (feature) commit 2 on feature
|/
* 9abcdef commit 1
```

#### A.2.3 メリット
- git 自身がレーン割当を行うため、アルゴリズム実装が不要。
- 分岐/マージの表現が git と完全一致（ユーザの `git log --graph` 経験と同じ見た目）。

#### A.2.4 デメリット（致命的）
- **paging と状態継承の不整合（★rev.1 L-01 主理由）**: phase 1 の 100 件毎のページング（`--skip`/`--max-count`）で `--graph` を使うと、`--skip` で切り出された部分グラフの罫線が途切れる（前のページ末尾の `|` が次ページ冒頭に継承されない）。レーン解決には前ページの frontier が必要だが、`--graph` はそれを与えない。本ツールの Model は独自に frontier を保持するアーキテクチャ（phase 1 stale-result reject/H1/R18 と整合）であり、`--graph` の stateless な ASCII 出力とは前提が合わない。
- **非構造化出力**: `--graph` 出力は「コミット行 + グラフ展開行」が混在する非構造化形式。1 コミットが複数行に展開されるため hash ↔ 行 の対応付けが脆弱（subject が `*`/`|` を含む・折返し発生時）。
- **`--graph` が ordering に影響する**: `--graph` 指定時は git がグラフ描画用に ordering を調整し得る（`--topo-order`/`--date-order` の暗黙付与に近い挙動）。phase 1 の `logArgv` が想定する順序との整合が取れない。
- **git version による見た目の差**: git 2.x 系でも `--graph` のレーン選択 heuristic がマイナーバージョンで変わり得る（実際に過去に変わった）。見た目の再現性が担保できない。
- **phase 1 の `Commit.parents` を活かせない**: 既に parents を保持しているのに再パースは無駄。

#### A.2.4b ★rev.1 L-01 訂正
rev.0 で「`--graph` と `-z` は排他」「`COLUMNS` 環境変数で折返す」と書いたが、現 git 2.54 では `--graph` と `-z` は併用可能・`COLUMNS` 非依存でも運用可能。これらは主理由ではなく、**上記の paging/状態継承/非構造化/ordering の不整合**が却下の本質。git version 差は「見た目の非互換」として副次的扱い。

#### A.2.5 推奨: **不採用**。paging との非互換が致命的。phase 1 の NUL 区切り `--pretty=format:` アーキテクチャ（stale-result reject/H1/R18 等）との整合も取れない。

### A.3 方式 B: 親子関係から自前でレーンを割り当てる方式（frontier-based lane assignment）

#### A.3.1 アプローチ
`Commit.parents` を使って自前でレーンを割り当てる。代表的な frontier-based アルゴリズム（gitui/git-graph/blinky 等の OSS で実績あり）を採用。

#### A.3.2 データ構造（提案）
```zig
/// 1 コミット分のグラフ描画情報（lane/edge）。Model が所有。
pub const GraphRow = struct {
    /// 当該コミットが属するレーン（0 起点）。
    lane: u16,
    /// 上→下へ伸びる罫線の分岐/合流情報。1 行描画で必要な全エッジ。
    /// element i はレーン i の列。phase 2 では最大 N レーンまで（N は同時生存分岐数）。
    /// セグメント種別: |（直進）/ ├（分岐開始）/ └（分岐終了→合流）/ etc.
    edges: []Edge,
    pub fn deinit(self: *GraphRow, a: std.mem.Allocator) void { a.free(self.edges); }
};

pub const Edge = enum(u8) {
    straight, // │ 親と同じレーンへ直進
    branch_start, // ├ 子から新レーンへ分岐
    merge_end, // ┘ 子レーンが親レーンへ合流
    empty, // この列に線無し
};
```

#### A.3.3 アルゴリズム（frontier-based・dense・共通親集約付き・★rev.1 H-01/M-01 反映）

**※注意**: `log_commits.items` は**新しい順**（`C_0` = HEAD 側）。グラフは上=新しい・下=古い。frontier アルゴリズムは「現在行の親を次行へ伝播」するため、**items 順（新しい→古い）**で 1 パス処理する。**★rev.1 H-03**: この前提が成り立つには `git log --topo-order` が必要（§A.3.8）。

**★rev.1 H-01 重要**: 同一親 hash を持つ複数 frontier slot（`M←B,C`・`B,C←A` で `[A,A]`）は**代表 1 slot へ集約**し、残りを削除する。これを怠ると偽レーンが永続残存する。

**★rev.1 M-01 重要**: frontier は **dense**（`null` hole を作らない）。親追加は現 node lane の**直後へ挿入**し、消費/集約後に末尾から詰める。sparse first-fit は見た目が不安定になるため採用しない。

```
frontier: ArrayList(?Hash)   // 各 slot の「次行へ伝播する親 hash」。dense・null は末尾詰めでのみ発生
                               // 初期は空。

for (commits.items, 0..) |c, row_idx| {
    // (1) c.hash と一致する frontier slot を**全て**列挙（H-01: 重複親の集約）。
    //     - 該当 slot が 1 つ: それを代表 lane とする（lane = slot index）。
    //     - 該当 slot が 2 つ以上（前の行で重複親が伝播していた）: 最初の slot を代表とし、
    //       残りを削除して dense 化（末尾詰め）。削除された slot の罫線は代表 lane へ
    //       水平接続（`─`/`┴` 等）として edge に記録。
    //     - 該当 slot が 0 個（新規分岐の tip）: frontier 末尾へ c.hash を append し、
    //       その index を代表 lane とする。
    // (2) c.lane = 代表 lane。
    // (3) frontier[c.lane] を消費（null 化）。
    // (4) c.parents の配置:
    //     - 0 個（root）: このレーンはここで終了。frontier[c.lane] は null のまま。
    //     - 1 個: frontier[c.lane] = parent（★H-01: 既に同一 parent が別 slot にあれば
    //       新規配置せずその slot へ集約・c.lane から水平接続）。
    //     - 2 個以上（merge）: 第一親を frontier[c.lane] へ。
    //       第二親以降は★M-01 dense 挿入: c.lane の直後へ挿入して frontier を伸ばす。
    //       ★H-01: 各親も既存 slot と一致すれば集約。
    // (5) ★rev.1 M-01(再): **全** null slot を削除して左詰め（interior hole も残さない）。
    //     末尾連続 null のみの削除では dense invariant が崩れる。
    //     削除に伴い罫線の集約（水平接続）を cells へ記録。
    // (6) GraphRow を計算して保存:
    //     - `cells`: ★rev.1 H-02(再) 表示行全体（1 コミット = 1 表示行）の各列接続 bitset。
    //       上側 frontier（before）と下側 frontier（after）を 1 行へ合成して持たせる。
    //       各セルは「上から来る」「下へ伸びる」「左へ接続」「右へ接続」「node」の組合せ。
    //     - `node_lane`: c.lane（cells 内の node がある列 index）
}
```

#### A.3.4 増分計算 vs 全再計算（★rev.1 H-04 反映）
phase 1 は 100 件毎のページングで `appendLogCommits` される。frontier は「直前のコミットの親情報」のみに依存するため、**増分計算が可能**: 末尾ページ追加分だけ frontier を継続して処理すればよい。

- **増分（推奨）**: `Model.log_graph_state` が `GraphState` tagged union（§B.1）を持ち、`.valid` のとき frontier を保持。`appendLogCommits` 時に frontier を保存しておき追加分のみ計算。
- **全再計算**: `log_loaded`（初回）/`request_refresh` のたびに全行再計算。シンプルだが大規模リポジトリで O(N×L) が毎回走る。

**推奨**: 増分。但し **★rev.1 H-04**: frontier の更新は**一時状態で計算 → 全確保成功後に swap**（strong exception guarantee）。OOM で中途半端に破壊された frontier は再試行不能になるため、`computeIncremental` は入力 frontier を**破壊せず**、新規 frontier を構築して返す。呼出側（reducer）が OOM を catch したら `log_graph_state` を `.invalid` へ（§E.1）。

#### A.3.5 メリット
- paging と完全整合（frontier を継承すれば次ページのグラフも正確）。**★rev.1 H-06**: tip hash 固定と組み合わせれば page 間の履歴移動にも耐える（§E.6）。
- git version 非依存（自分たちのアルゴリズムで決定論的）。
- `Commit.parents`（phase 1 で保持済み）を活用。新規 git コマンド不要（`--topo-order` 追加のみ）。
- テストが決定論的（入力 commits 列 → 出力 GraphRow 列の golden test が書ける）。

#### A.3.6 デメリット
- アルゴリズム実装コスト（frontier 管理・dense 挿入・共通親集約・edge 計算・box-drawing 文字選択ロジック）。
- 「同時に生存する分岐数」が大きい履歴（10+ レーン）で描画幅を食う。**★rev.1 M-04**: 計算は全 lane を保持し、描画時のみ幅へ射影・省略（計算側で上限をかけない）。
- マージコミットの罫線合流表現が描画の難所（`╮`/`╯`/`┐`/`┘` の使い分け）。代表的な分岐/マージ履歴で要 golden test。

#### A.3.7 推奨: **採用**。paging 互換・phase 1 データ活用・テスト容易性の全てで A を上回る。

#### A.3.8 ★rev.1 H-03: `git log --topo-order` の追加指定
frontier 法は「子が必ず親より先に現れる」ことを前提とする。現行 `logArgv` には順序指定が無く、clock skew や複数ブランチ traversal で親が先に現れるとグラフ復元不能になる。`commands.zig logArgv` へ `--topo-order` を追加する（`--date-order` も候補だが、グラフ見やすさ優先で `--topo-order` をデフォルト）。

**影響範囲**: `src/git/commands.zig logArgv` のテスト（`--topo-order` が argv に含まれることを検証）と `src/git/log.zig` のパーサ（変更無し・`--topo-order` は出力順へ影響するだけ）。phase 1 の paging（`--skip`/`--max-count`）との併用も問題無し（`--topo-order --skip=N --max-count=100` は git が正しく解釈）。

### A.4 codex 第 1 段レビューでの確定事項（rev.1）
- 方式 B（frontier-based 自前）で確定。方式 A の却下理由は L-01 修正済み（§A.2.4）。
- 増分計算採用。H-04/H-05 のトランザクション保証と invalid 時 `computeAll` 回復を必須化（§E.1）。
- `GraphRow` は semantic data 保持（描画文字列直保存しない）。但し H-02 のとおり `Edge` 4 種では不十分で**接続 bitset へ拡張**（§B.1）。
- 同期 reducer 計算でよい。100 件単位を benchmark し、問題あれば将来 worker 化。
- カラムレイアウトは固定案のまま不可。M-05 段階的省略へ（§D.2）。
- 色ローテーション可。パレット数を一意にしコントラスト重視（L-02・§D.3）。
- レーン上限は計算と描画で分離（M-04）。計算は全 lane 保持・描画で射影（§D.3/§G.1）。
- date の author/committer と timezone を先に確定（M-07・§D.7）。

---

## B. データ構造設計案

### B.1 新モジュール `src/git/graph.zig`（純粋・zigzag 非依存・TDD 対象・★rev.1 H-02/M-02/H-04 + rev.2 H-02(再)/M-08/H-08/M-14 反映）

```zig
//! コミットグラフのレーン割当とエッジ計算。`log.Commit` の parents から frontier-based で算出。
//! zigzag 非依存・テスト容易（決定論的入力 → 決定論的出力）。

const std = @import("std");
const log = @import("log.zig");

/// ★rev.2 H-02(再): 1 表示行（= 1 コミット）の各列の接続情報を bitset で表現。
/// before/after の 2 レイヤーを別スライスにするのではなく、1 行全体を `cells` で持つ。
/// 各セルは「上から来る」「下へ伸びる」「左へ接続」「右へ接続」「node」の組合せを表現。
/// これにより水平線（─）/交差（┼）/分岐（┬ ┴ ├ ┤）/合流（┐ ┘ └ ┘）を全て表現できる。
pub const Conn = packed struct {
    up: bool = false,     // 上行（= 前 commit）からの罫線接続
    down: bool = false,   // 下行（= 次 commit）への罫線接続
    left: bool = false,   // 同一行内で左のセルへ接続（水平線・合流）
    right: bool = false,  // 同一行内で右のセルへ接続（水平線・分岐）
    is_node: bool = false, // このセルが commit node（`*`/`●`）
};

/// ★rev.2 H-02(再): 1 コミット分のグラフ描画メタデータ。1 コミット = 1 表示行。
/// `cells` は表示行全体の各列接続。Model が所有・`deinit` で free。
pub const GraphRow = struct {
    /// 当該コミットが属するレーン（cells 内の node がある列 index・0 起点）。
    node_lane: u16,
    /// 表示行全体の各列接続 bitset。長さ == 行幅 W。
    /// ★rev.2 M-08: W = max(before_frontier幅, after_frontier幅, node_lane + 1)。
    /// before/after は cells 内の up/down ビットで表現（node 列だけ up/down を適宜切替）。
    cells: []Conn,
    /// ★rev.2 M-08: 行幅 W（= cells.len）。描画側が参照。lane_count 廃止（cells.len で代用）。
    pub fn width(self: GraphRow) u16 { return @intCast(self.cells.len); }
    pub fn deinit(self: *GraphRow, a: std.mem.Allocator) void { a.free(self.cells); }
};

/// frontier: 各レーンの「次行へ伝播する親 hash」。★rev.1 M-01 + rev.2 M-01(再): dense・null hole 無し。
/// 各要素（非 null）は persistent allocator 所有の []u8。Model が所有。
pub const Frontier = struct {
    slots: std.ArrayList(?[]u8), // 各 slot の []u8 は persistent 所有（null は一時的に不可・行処理後に左詰め）
    pub fn init() Frontier { return .{ .slots = .empty }; }
    pub fn deinit(self: *Frontier, a: std.mem.Allocator) void {
        for (self.slots.items) |s| if (s) |h| a.free(h);
        self.slots.deinit(a);
    }
    /// ★rev.1 H-04: deep-copy（別 allocator/同一 allocator へ複製）。増分計算の一時状態構築用。
    pub fn clone(self: Frontier, a: std.mem.Allocator) !Frontier {
        var next: Frontier = .init();
        errdefer next.deinit(a);
        try next.slots.ensureTotalCapacity(a, self.slots.items.len);
        for (self.slots.items) |s| {
            const dup: ?[]u8 = if (s) |h| try a.dupe(u8, h) else null;
            errdefer if (dup) |d| a.free(d);
            try next.slots.append(a, dup);
        }
        return next;
    }
};

/// ★rev.1 M-02 + rev.2 M-14: GraphState を tagged union へ。`.invalid`/`.valid` を保証するが、
/// `processed_len == rows.items.len == log_commits.items.len` や generation 一致は **runtime invariant**
/// （型では保証しない）。compute 入口と描画入口で assert/reject する。
pub const GraphState = union(enum) {
    invalid,
    valid: struct {
        generation: u64,           // log_request_generation と同期（runtime invariant）
        processed_len: usize,      // log_commits.items.len と一致（runtime invariant）
        tip_hash: ?[]u8,           // ★rev.2 H-07: paging tip と一体（null = 初回未設定/ unborn）
        rows: std.ArrayList(GraphRow),
        frontier: Frontier,
    },

    pub fn deinit(self: *GraphState, a: std.mem.Allocator) void {
        switch (self.*) {
            .invalid => {},
            .valid => |*v| {
                for (v.rows.items) |*r| r.deinit(a);
                v.rows.deinit(a);
                v.frontier.deinit(a);
                if (v.tip_hash) |t| a.free(t);
            },
        }
    }
    /// ★rev.2 M-14: runtime invariant 検証。compute/描画入口で呼ぶ。
    /// generation/processed_len が期待と一致するか。commits.len と rows.items.len が一致するか。
    pub fn isInvariant(self: GraphState, expected_generation: u64, commits_len: usize) bool {
        switch (self) {
            .invalid => return true,
            .valid => |v| return v.generation == expected_generation and
                v.processed_len == commits_len and
                v.rows.items.len == commits_len,
        }
    }
};

/// 初回（skip=0）/全再計算: 全コミットを一括で処理。rows と最終 frontier を含む GraphState を返す。
/// 呼出側が GraphState を deinit。
/// ★rev.2 M-14: 返り値の `processed_len == commits.len == rows.items.len` を保証。
pub fn computeAll(a: std.mem.Allocator, commits: []const log.Commit, generation: u64, tip_hash: ?[]const u8) !GraphState;

/// ★rev.1 H-04 + rev.2 H-08: 増分。入力 GraphState.valid を**破壊せず**、
/// delta rows + 新 frontier を一時状態で計算 → 全確保成功後に**既存 rows へ append + frontier swap**。
/// 既存 rows の deep-copy はしない（O(N²) 回避）。
/// OOM は error return（入力 state 不変・呼出側が .invalid へ移行して回復）。
pub fn computeIncremental(a: std.mem.Allocator, state: GraphState, new_commits: []const log.Commit) !GraphState;
```

**所有権契約（phase 1 の H6/R1 + rev.1 H-04 + rev.2 H-08 と同型）**:
- `computeAll`: 返り値 `GraphState.valid` の `rows`/`frontier`/`tip_hash` は `a` で所有。呼出側が deinit。
- `computeIncremental`: **入力 state を破壊しない**（strong exception guarantee）。内部で:
  1. frontier を clone（一時状態）
  2. delta rows を新規 ArrayList で構築（追加分のみ）
  3. 全確保成功後 → 新 GraphState へ既存 rows を move + delta rows を append + 新 frontier を swap
  4. OOM は error return・入力 state 不変
- ★rev.2 H-08: 既存 rows の deep-copy をしないことで O(N²) を回避。move/swap で所有権移行。
- `checkAllAllocationFailures`（★rev.2 L-05: graph 関数は全 alloc failure を網羅・phase 1 `status.zig`/`log.zig` と同パターン）。reducer のテストは失敗位置限定（§F.2）。

### B.2 `Model` への新フィールド（★rev.1 M-02: GraphState へ集約）

```zig
// --- TODO 2 phase 2: グラフ描画（GraphState で一体化） ---
log_graph_state: graph.GraphState,   // .invalid or .valid{generation, processed_len, rows, frontier}
```

- `Model.init`: `log_graph_state = .invalid`。
- `Model.deinit`: `log_graph_state.deinit(a)`。
- **log_request_generation との同期**: `GraphState.valid.generation` が `log_request_generation` と一致する間のみ有効。`toggle_view_mode`/`request_refresh`（log）で generation を進めたら `log_graph_state` を `.invalid` へ（§E）。

**ヘルパ関数（H6/R1 と同型・deep-copy → swap）**:
```zig
/// log_graph_state を新規 state へ置換（旧を deinit）。トランザクショナル。
pub fn setLogGraphState(self: *Model, new_state: graph.GraphState) void {
    self.log_graph_state.deinit(self.allocator);
    self.log_graph_state = new_state;
}
/// log_graph_state を .invalid へ（旧を deinit）。refresh/トグル退出/OOM フォールバックで呼ぶ。
pub fn invalidateLogGraph(self: *Model) void {
    self.log_graph_state.deinit(self.allocator);
    self.log_graph_state = .invalid;
}
```

### B.3 新 `Msg`/`AppCmd` バリアント

**追加不要**。グラフ計算は**純粋 reducer 内で同期的**に行う（外部 git コマンド不要・`Commit.parents` は既に手元にある）。`log_loaded`/`log_page_loaded` arm の reducer が `graph.computeAll`/`computeIncremental` を呼び、`Model.log_graph_state` へ格納する。

**理由**:
- グラフ計算は CPU バウンドで高速（100 コミットでもミリ秒オーダー）。ワーカースレッドへ回すと stale-result reject（H1）が複雑化する。
- 入力（commits）は既に Model が所有済み。新規 `Msg`/`AppCmd` を増やすと phase 1 の `isMutating`/`seedInitialStatus`/`applyAppCmd` の網羅的 switch 更新（R9）が必要になり、複雑度が増すだけ。

### B.4 ★rev.1 H-03: `commands.zig logArgv` の更新
`--topo-order` を argv へ追加（順序安定化）。`src/git/commands.zig` の `logArgv` テストも更新（`has_topo_order` 検証を追加）。phase 1 の `log.parse` は変更無し（`--topo-order` は出力順へ影響するだけ・NUL 区切りフォーマットは同じ）。

### B.5 ★rev.1 H-06 + rev.2 H-07/M-10: tip hash 固定（paging owner の一部・独立所有型）
`--skip=N` は各要求時点の履歴に対する offset のため、page 間に HEAD/ref が移動すると重複・欠落が起きる。初回 `load_log` 時の tip hash（`log_commits.items[0].hash`・HEAD 相当）を paging owner の一部として Model へ保持し、以後の `load_log_page` で同じ revision へ固定する。

**★rev.2 H-07: tip は generation と一体の paging owner**。tip を変更する全経路（toggle/refresh/bad revision 回復）で generation を進める。結果 Msg は `request_tip` を持ち、reducer が `log_paging_tip` と照合する。

```zig
/// ★rev.2 M-10: page 用の独立所有型。tip_hash は dupe して AppCmd.deinit で解放。
pub const LoadLogPage = struct {
    skip: usize,
    max_count: usize,
    generation: u64,
    tip_hash: []u8,   // 所有・dupe 済み
};

pub const LoadLog = struct {
    skip: usize,
    max_count: usize,
    generation: u64,
    // tip 無し（初回は HEAD 起点）。tip は log_loaded 到着後の items[0].hash で確定。
};

/// 結果 Msg 側（★rev.2 H-07）:
pub const LogPageLoaded = struct {
    request_skip: usize,
    request_max_count: usize,
    request_generation: u64,
    request_tip: []u8,   // ★H-07: 要求時の tip と model.log_paging_tip を照合
    entries: []log.Commit,
};
```

**Model への追加**:
```zig
log_paging_tip: ?[]u8,   // paging 間で固定する tip hash。toggle/refresh/bad-rev で clear。
```

**影響**:
- `commands.zig logPageArgv(a, skip, max_count, tip_hash)`: `git log --topo-order --skip=N --max-count=100 <tip_hash> ...`。
- `appcmd.zig .load_log_page` arm: `LoadLogPage.tip_hash` を `logPageArgv` へ渡す。結果 Msg `LogPageLoaded` 構築時に `request_tip = dupe(tip_hash)`（★M-10: errdefer 付き）。
- `update.handleLogPageLoaded`: `request_tip` と `model.log_paging_tip` の照合を追加（不一致は stale reject・★H-07）。
- `update.handleLogLoaded`（初回）: `log_paging_tip = dupe(items[0].hash)` を **generation 更新と同時**に行う（★H-07: tip と generation は一体）。OOM で tip dupe が失敗したら `log_page_requested = null` のまま `.none`（★M-10: 次回 down で再試行）。
- `toggle_view_mode`/`request_refresh`（log）: generation += 1 と同時に `clearLogPagingTip()`。

---

## C. East Asian Width 桁計算の方式

### C.1 現状確認
- `view.fitPane` は `zz.width(line)`（`src/layout/measure.zig`）と `zz.measure.truncate(a, line, w)` を使う。これらは**既に East Asian Width を考慮**（zigzag が `unicode_width_strategy` で全角=2 桁を返す・api-notes L209-212）。
- 従って phase 1 の `renderLog`/`renderDetailFiles` は**追加実装なしで日本語 subject/author/path を正しく扱える**。グラフ罫線列も box-drawing 文字は全て幅 1 なので問題無い。

### C.2 phase 2 での追加対応（必要最小）
- **author/日時カラムの固定幅化**（§D）: author 名の East Asian Width を考慮して右パディングする必要がある。`zz.width(author)` で表示幅を測り、`allocPrint` で `(max_w - width)` 個のスペースを付ける、または `zz.place.place(a, w, 1, .left, .top, author)` で固定幅化（phase 1 の `fitPane` と同パターン）。
- **refs ラベル**: phase 1 と同様 raw 文字列（` (HEAD -> main, tag: v1)`）をそのまま描画し、`fitPane` で切り詰め。East Asian Width は既存の `zz.width`/`truncate` が吸収。

### C.3 独自 East Asian Width 表は**作らない**
- zigzag が提供する `zz.width`/`zz.measure.truncate` に任せる。独自 table を埋め込むと zigzag の `unicode_width_strategy`（環境変数 `ZZ_UNICODE_WIDTH`）と整合しなくなる。
- テスト環境でブレる場合はテスト実行時に `ZZ_UNICODE_WIDTH=unicode` を明示（CI で固定）。これは phase 1 でも同じ前提。

---

## D. 描画設計案（カラムレイアウト・★rev.1 M-04/M-05/M-06/M-07/L-02 反映）

### D.1 log ペインのカラム構成（基本・広い画面）

```
[graph] [refs: 上限付] [hash: 7] [subject: 残り] [author: max 12] [date: 10]
```

★rev.1 M-06 変更: **refs を subject の前へ**（重要なブランチ/tag 情報が truncate されないよう）。subject は「残り可変幅」のまま最後に置く。

- `graph`: `2L+1` 列（L = 同時生存レーン数）。★rev.1 M-04: 描画時に全 lane を保持しつつ表示幅へ射影。上限（例: log_w/3）を超えるレーンは末尾から `...` で省略（省略された生存 edge があることを示す専用セル・後述）。
- `refs`: 上限付き予約幅（例: 20 桁）。★rev.1 M-06: phase 1 の raw 文字列（` (HEAD -> main, tag: v1)`）をそのまま描画し、上限超は `zz.measure.truncate`。
- `hash`: 7 桁固定（phase 1 と同じ short-hash）。
- `subject`: 残り可変幅（`fitPane` でペイン幅へ切り詰め）。
- `author`: 最大 12 桁（全角 6 文字分）。超過は切り詰め。
- `date`: `YYYY-MM-DD` の 10 桁固定（★rev.1 M-07・詳細は §D.7）。

### D.2 ★rev.1 M-05 + rev.2 M-13: 最小 subject 予約・残幅配分
80 桁端末で log ペインは 32 桁程度。固定カラム全表示では subject が潰れるため、★rev.2 M-13 **最小 subject 幅を先予約**し、残幅から諸カラムを採用する:

**配分アルゴリズム**:
1. `subject_min = 10`（最低保証）。
2. `graph_w = min(2L+1, log_w / 3)`（グラフは最大でもペイン幅の 1/3 まで）。
3. `hash_w = 7`（固定）。
4. 残幅 `rest = log_w - graph_w - hash_w - subject_min`。
5. `rest > 0` なら以下を優先順位順に採用:
   - `refs`（最大 20・`min(20, rest)`）→ `rest -= refs_w`
   - `author`（最大 12・`min(12, rest)`）→ `rest -= author_w`
   - `date`（最大 10・`min(10, rest)`）→ `rest -= date_w`
   - `subject_w = subject_min + max(0, rest)`（残りを subject へ回す）
6. `rest < 0`（極小）なら: date→author→refs の順で非表示にし、最悪は graph も非表示。

優先順位（高い順）: **subject > hash > graph node > refs > author > date**。これにより狭い画面でも「コミットの件名と hash」は必ず見える。

| log_w（参考） | graph | refs | hash | subject | author | date |
|---|---|---|---|---|---|---|
| >= 60 | full | 上限 20 | 7 | 残り | max 12 | 10 |
| 45-59 | full | 上限 12 | 7 | 残り | max 8 | 非表示 |
| 30-44 | クランプ | 上限 8 | 7 | 残り | 非表示 | 非表示 |
| < 30 | 非表示 | 非表示 | 7 | 残り | 非表示 | 非表示 |

※表は参考・実装は上記アルゴリズムで動的に決定（★rev.2 M-13）。

### D.3 グラフ罫線の色分け（★rev.1 L-02/M-04 + rev.2 M-09/L-03/L-04 反映）
- ★rev.1 L-02 + rev.2 L-03: 6 色の固定パレット（コントラスト重視・`zz.Color` の `red`/`green`/`yellow`/`blue`/`magenta`/`cyan`）。lane 番号を 6 で割った余りでローテーション。但し ★rev.2 L-03 **theme 依存で低コントラストあり得る**ため、**色無しでも形（`│ ├ └` 等）だけで判別可能**にする。node（`*`）は `bold` 併用で視認性を補強。
- **色は branch identity ではなく視認補助**であることを README へ明記（同一色が別ブランチに使われることがある）。
- ★rev.2 M-09: dense 削除/挿入で lane index が左右へ移動するため、`lane mod 6` では同じ線が行途中で色を変える場合がある。**phase 2 では色変化を仕様として受容**。将来は frontier slot へ安定した color id を保持する拡張を検討。
- ★rev.1 M-04: 計算は全 lane を保持するが、描画時に省略されたレーンは専用の省略セルで表現。★rev.2 L-04: 省略セルは **`⋮`（vertical ellipsis・U+22EE）に確定**（方向も意味も `…` より適切）。`zz.width` で表示幅 1 を検証。ASCII fallback は `:` とし、`unicode_width_strategy` で揺れる場合は環境変数 `ZZ_UNICODE_WIDTH=unicode` で固定。
- `*`/`●`（ノード文字）はブランチの色で描画。選択行（`log_selected`）は reverse で全体を強調（phase 1 と同様）。

### D.4 既存 phase 1 `renderLog` からの移行
```zig
fn renderLog(model: *Model, ctx: *const zz.Context, height: u16) []const u8 {
    // 既存の phase 1 実装（<short-hash> <subject> <refs>）を拡張:
    // (1) log_graph_state が .valid なら GraphRow 列を取り出し、.invalid ならグラフ列をスキップ。
    // (2) ペイン幅（layout.log.w）に応じて段階的カラム省略（§D.2）を決定。
    // (3) 各行を [graph] [refs?] [hash] [subject] [author?] [date?] の順で組み立て
    //     （★M-06: refs は subject 前）。
    // (4) std.mem.join(a, "\n", lines) でプレーン結合（★M9: zz.joinVertical は使わない）。
    // (5) 選択行は reverse で全体を強調。
}
```

### D.5 長い subject・多数レーンでの `fitPane` 挿動
- `fitPane` は行単位で `zz.measure.truncate` するため、グラフ列も含めてペイン幅へ切り詰められる。
- ★rev.1 M-04/M-05 により、段階的省略と graph lane 射影で広い画面では全カラム表示・狭い画面では subject/hash 優先へ自動調整される。`fitPane` は最終安全装置として働く。

### D.6 README/TODO 更新
- README.md: phase 2 の表示要素（グラフ・author・日時）と段階的省略の挙動をキー操作と共に追記。
- TODO.md: TODO 2 phase 2 の「グラフレーン割当アルゴリズム」「グラフ描画」「East Asian Width」「author/日時」を達成チェックボックスへ。フィルタは独立 spec 残として明記。

### D.7 ★rev.1 M-07 + rev.2 M-07(再): date の意味と timezone（UTC 固定）
phase 1 の `logArgv` は `%at`（author timestamp・Unix epoch 秒）を取得済み。phase 2 表示では以下を確定:

- **表示する日付**: **author date**（`%at`）。「誰がいつ変更したか」は author date が直感的。committer date（`%ct`）は将来オプションで。
- **timezone**: ★rev.2 M-07(再) phase 2 では **UTC 固定**（`std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_sec) }` から `YearMonthDay` へ変換・`std.fmt` で `YYYY-MM-DD` フォーマット）。**理由**: Zig 0.16 の `std.time` に `std.time.local` 相当のローカル timezone 変換 API が無い。ローカル timezone は OS 依存（`/etc/localtime` 解析・libc の `localtime_r` 呼出等）で別依存/C 連携が必要。phase 2 スコープ外。
- **フォーマット**: `YYYY-MM-DD`（10 桁固定・`std.fmt` でゼロ埋め）。時分秒は phase 2 では含めない（ペイン幅節約）。UTC であることを README へ明記。

**実装詳細（Zig 0.16 準拠）**:
```zig
/// epoch_sec (i64) -> "YYYY-MM-DD" (UTC) の 10 桁文字列。ctx.allocator で確保（フレーム arena）。
fn formatAuthorDateUTC(a: std.mem.Allocator, epoch_sec: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_sec) };
    const day = es.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, day.year),
        @as(u32, month.month.numeric()),
        @as(u32, month.day_index + 1),
    }) catch "????-??-??";
}
```

**将来拡張（phase 2 範囲外）**: `%aI`（author date in ISO 8601 with timezone offset）の取得とコミット固有 offset での日付計算。`%ct`/`%cI`（committer）。OS ローカル timezone（libc 連携 or `tz` データ埋め込み）。これらは `logArgv` の pretty format 拡張で対応可能。

---

## E. ページング・stale reject・所有権への影響（★rev.1 H-04/H-05/H-06/M-03 反映）

### E.1 paging とグラフ計算の整合（★最重要・トランザクション保証付き・★rev.2 M-11/H-08 反映）

phase 1 の paging フロー:
1. `log_cursor_down` が末尾付近で `load_log_page`（skip = items.len・tip = `log_paging_tip`）を発行。
2. appcmd が `git log --topo-order --skip=N --max-count=100 <tip_hash>` を実行し `log_page_loaded` を返す。
3. reducer `handleLogPageLoaded` が `appendLogCommits(entries)` で items を拡張。

**phase 2 拡張（増分計算・★rev.2 M-11 明示的 switch）**:
- `handleLogLoaded`（初回）:
  1. generation/skip 検証を通過した後、`replaceLogCommits(entries)`（phase 1 どおり）。
  2. ★rev.2 H-07: `log_request_generation += 1`（初回確定）と同時に `setLogPagingTip(items[0].hash)`。OOM は catch して `clearLogPagingTip()` + `.none`（★M-10: 次回 down で再試行）。
  3. `graph.computeAll(a, entries, generation, tip_hash)` を呼び、成功したら `setLogGraphState(.valid{...})`。OOM は catch して `invalidateLogGraph()`（★H-05: commits は採用・graph は `.invalid` へ）。
- `handleLogPageLoaded`（追加分・★rev.2 M-11 明示的 switch）:
  1. generation/skip/**tip**（★H-07）検証を通過した後、`log_page_requested = null`（★R22 どおり・appendLogCommits の前）。
  2. `appendLogCommits(entries)`（phase 1 どおり）。
  3. ★rev.2 H-06(再) 削除: page 先頭 hash の親 hash 検証は**行わない**（topo-order でも保証されない・正常履歴を誤判定するため）。
  4. ★rev.2 M-11: `log_graph_state` で switch:
     - `.valid`: ★rev.2 H-08 `graph.computeIncremental(a, log_graph_state, entries)`（既存 rows の deep-copy 無し・delta + swap）。成功で `setLogGraphState(new_state)`・OOM で `invalidateLogGraph()`。
     - `.invalid`: ★rev.2 M-11 **`graph.computeAll(a, log_commits.items, generation, log_paging_tip)`** で全再構築。成功で `setLogGraphState`・OOM で `.invalid` のまま。

**OOM 時の挙動（R22 + rev.1 H-04/H-05 + rev.2 H-08）**:
- `appendLogCommits` OOM: phase 1 どおり `log_page_requested` は既に null・次回 down で再試行可能。`log_graph_state` は触らない（次回成功で回復）。
- `computeIncremental` OOM: ★rev.2 H-08 入力 state 不変・★H-05 で reducer が catch して `invalidateLogGraph()`。`renderLog` はグラフ列スキップ。
- `computeAll` OOM（`.invalid` からの回復時）: 同様に `.invalid` のまま。`renderLog` はグラフ列スキップ。
- **回復**: 次回 `log_loaded`/`log_page_loaded` 到着時、`.invalid` なら再度 `computeAll` を試みる（★rev.2 M-11: `log_page_loaded` arm の `.invalid` 分岐）。

### E.2 stale-result reject（H1）との整合（★rev.2 H-07 反映）
- グラフ計算は generation/skip/**tip**（★H-07）検証を通過した arm 内で行う。
- `toggle_view_mode`（log→changes）や `request_refresh`（log）で generation を進めたら `invalidateLogGraph()` と `clearLogPagingTip()`（★H-06/H-07: tip も generation と一体でクリア）。

### E.3 refresh（`r`）時のグラフ再計画
- `handleRequestRefreshLog` が `replaceLogCommits(&.{})` で空にするタイミングで、`invalidateLogGraph()` と `clearLogPagingTip()`。generation も +1（★H-07）。
- `log_loaded` 到着後、再度 `graph.computeAll` で再構築。

### E.4 空履歴（R2）との整合
- `log_commits.items.len == 0` のときグラフも空・`log_graph_state = .invalid`・`log_paging_tip = null`。`renderLog` は `"(no commits)"` を返す（phase 1 と同じ）。
- unborn HEAD は初回結果が空なら tip を設定せず `has_more=false`（codex 第 2 段 OK 判定）。

### E.5 ★rev.1 M-03: commit append の O(N²) 最適化（将来検討・phase 2 範囲外）
phase 1 の `appendLogCommits` は既存全 commits を deep-copy するため、page 毎に O(N) の再確保が走り、累積 O(N²)。graph 増分（★rev.2 H-08 で rows 側は解消）だけ最適化しても commits 側が残る。

**phase 2 では対応しない**（所有権契約の変更は phase 1 spec へ影響）。但し §G.6 で将来課題として記録し、別 spec で扱う。100 件/ページ・1000 件程度なら実用上問題無い見込み。

### E.6 ★rev.2 H-06(再)/H-07/M-10/M-12: tip hash 固定とエッジケース
- `Model.log_paging_tip: ?[]u8`（persistent 所有）。
- `handleLogLoaded`（初回）: ★H-07 `log_request_generation += 1` と同時に `setLogPagingTip(items[0].hash)`（OOM で `clearLogPagingTip` + `.none`）。
- `logArgv`（初回）: tip 無し（`HEAD` 起点）。
- `logPageArgv`（追加）: `<tip_hash>` を argv 末尾へ。`--topo-order --skip=N --max-count=100 <tip_hash>` で同一 snapshot を参照。
- ★rev.2 H-06(再) 削除: page 先頭 hash の親 hash 検証は**行わない**。snapshot 統一は tip+generation+skip の owner 照合のみで保証。
- ★rev.2 H-07: 結果 Msg `LogPageLoaded.request_tip` と `model.log_paging_tip` を照合（不一致は stale reject）。
- ★rev.2 M-12: bad revision 検出（`git log <tip>` が exit 128 で bad object/missing commit）時の回復:
  - appcmd が exit 128 を検出したら `Msg{ .git_error = "tip が期限切れです（履歴が移動しました）" }` を返す。
  - reducer が `git_error`（log モード中）で `log_request_generation += 1`・`invalidateLogGraph()`・`clearLogPagingTip()`・`replaceLogCommits(&.{})`・`return .{ .load_log = .{ .skip = 0, .max_count = 100, .generation = new_gen } };`（初回 load へ戻る）。
- `toggle_view_mode`/`request_refresh`（log）: `log_request_generation += 1` と同時に `clearLogPagingTip()`（★H-07）。
- detached HEAD: hash が存在する限り問題無し（codex 第 2 段 OK 判定）。

---

## F. テスト戦略（★rev.1 H-01/H-04/M-04 反映）

### F.1 `git/graph.zig` 単体（`std.testing.allocator` 必須・★rev.2 L-05/H-08/M-11 反映）
- **線形履歴**: 3 コミット A←B←C（親 1 つずつ）。全レーン 0・cells 全て `Conn{.up=true, .down=true}`。
- **分岐**: A←B, A←C（A が共通祖先）。C で新規レーン 1 を確保。
- **マージ**: A←B, A←C, D=merge(B,C)。D でレーン 1 が 0 へ合流（水平接続 `─`/`┴` 相当の cells）。
- **★rev.1 H-01 共通親集約**: M←B, M←C, B←A, C←A。frontier が `[A,A]` にならず代表 1 slot へ集約されること。A 到達時に偽レーンが残らないこと。
- **root**: 親 0 のコミット。そのレーンは次行で終了（`cells` で down=false）。
- **octopus merge**: 親 3 つ以上。dense 挿入で c.lane の直後に 3 つの親が並ぶこと。
- **★rev.1 M-01(再) dense 化**: interior hole が残らないこと（root 終了や集約後に中間 null が無い）。
- **★rev.2 H-08 増分**: `computeAll` で 100 件 → `computeIncremental` で 50 件追加。結果が 150 件一括 `computeAll` と**構造的 equality**（rows/frontier 全て一致）で検証。既存 rows の deep-copy が行われないこともメモリ使用量等で確認可能なら併用。
- **★rev.2 H-08/M-11 OOM**: `computeIncremental`/`computeAll` で OOM 模擬（`checkAllAllocationFailures`）・入力 state が破壊されないこと（strong exception guarantee）。
- **★rev.2 M-14 invariant**: `computeAll`/`computeIncremental` 後の `GraphState.isInvariant(generation, commits.len) == true` を検証。
- ★rev.2 L-05: graph 関数は全 allocation failure を網羅（`checkAllAllocationFailures`）。reducer のテストは失敗位置限定（§F.2）。
- 各セルの `Conn` が期待どおり（up/down/left/right/node の組合せ）。

### F.2 `update.zig` reducer（グラフ計算の呼び出し・★rev.2 H-05/H-07/M-10/M-11/M-12/L-05 反映）
- `log_loaded` arm 後、`log_graph_state` が `.valid`・`processed_len == items.len`・`generation == log_request_generation`・`tip_hash == log_paging_tip`（★M-14 invariant）。
- ★rev.2 H-07: `log_request_generation += 1` と `setLogPagingTip` が同時に行われる（OOM で tip のみ clear + `.none`・★M-10）。
- ★rev.2 M-11: `log_page_loaded` arm で `log_graph_state` switch（`.valid→incremental`/`.invalid→computeAll(items)`）。
- ★rev.2 H-08: `.valid` のとき `computeIncremental` が呼ばれ、既存 rows の deep-copy 無し。
- ★rev.2 H-07: `LogPageLoaded.request_tip` と `model.log_paging_tip` の不一致は stale reject。
- ★rev.2 M-12: bad revision（git_error・log モード中）で `log_request_generation += 1`・`invalidateLogGraph`・`clearLogPagingTip`・`replaceLogCommits(&.{})`・`load_log` 発火。
- ★rev.1 H-05: グラフ計算 OOM（`checkAllAllocationFailures` または failing allocator 注入）で `log_graph_state` が `.invalid` へ・commits は採用されたまま。★rev.2 L-05: reducer の OOM テストは graph 計算部分に限定（commit append の失敗は別途）。
- `toggle_view_mode`（log→changes）で `log_graph_state == .invalid`・`log_paging_tip == null`・generation 進行。
- `request_refresh`（log）でグラフクリア → `log_loaded` で再構築。
- 回復: `.invalid` 状態で次回 `log_loaded`/`log_page_loaded` 到着時に `computeAll` 全再構築が走る。

### F.3 `view.zig`（描画・`ArenaAllocator`・★rev.2 M-09/M-13/L-04 反映）
- `renderLog` が `[graph] [refs?] [hash] [subject] [author?] [date?]` の順で出力（★M-06: refs は subject 前）。
- ★rev.2 M-13: 最小 subject 幅予約・残幅配分アルゴリズム（§D.2）。log_w >= 60 で全カラム・狭画面で段階的省略の各パターンを検証。
- ★rev.2 M-07(再): date が UTC の `YYYY-MM-DD` 10 桁で出力されること（`std.time.epoch` 経由）。
- 日本語 author/subject で East Asian Width が正しく（`zz.width` 経由）。
- グラフ罫線色が lane 毎に切り替わる（6 色・lane mod 6）。★rev.2 M-09 同一線が行途中で色変わる場合があることは許容。
- ★rev.2 L-04: 生存レーン数 > 描画上限のとき省略セルが `⋮`（`zz.width == 1` を検証）。
- 選択行が reverse で強調。
- `fitPane` 回帰（phase 1 既存テストが壊れないこと）。

### F.4 結合（`appcmd.zig` `TmpRepo`）
- 実 git で 3 コミット + ブランチ + マージ履歴を作り、`load_log` → `log_loaded` → reducer が `log_graph_state` を構築。期待レーン割当（線形→分岐→合流）を検証。
- ★rev.1 H-03: `logArgv` が `--topo-order` を含むこと。実 git 出力が topo-order であること（clock skew がある履歴で検証）。
- ★rev.1 H-06: page 間で HEAD を動かさずに 100 件超ページング → グラフが正しく接続されること。
- 日本語 author 名のコミットで描画が崩れない。
- 100 件超でページング → 増分グラフ計算が正しい。

### F.5 手動 pty 検証
- `tmux capture-pane` で分岐/マージ履歴のグラフが正しく描画されること。
- 日本語 author/subject の桁揃え。
- 幅 80/120/40 で段階的カラム省略と graph lane 射影の挙動。

---

## G. リスクと未解決事項（★rev.1 M-04/H-06 反映）

### G.1 性能（大規模リポジトリ・★rev.1 M-04）
- 1000+ コミット・多数分岐で `computeAll` が重くなる。増分計算で緩和されるが、初回ロード（100 件）でも分岐が多いと frontier が大きくなる。
- **対策**: ★rev.1 M-04 計算は全 lane 保持・描画時のみ幅へ射影（計算側で上限をかけない）。描画の省略セルは視覚的に「省略中」を示す。
- 将来的な上限設定（ユーザ設定可能）は別 spec で検討。

### G.2 グラフ計算のタイミング
- `log_loaded`/`log_page_loaded` arm 内で**同期的**に計算する（B.3 のとおり・新規 AppCmd 無し）。100 コミット/ページならミリ秒オーダー。
- ワーカースレッドが appcmd.run を実行中に reducer が呼ばれるわけではない（Elm アーキテクチャ）。reducer は UI スレッドで同期的に動くので、グラフ計算が重いと UI が一瞬固まる可能性。100 件単位なら実用上問題無い見込み。問題あれば将来 worker 化（H1 stale reject 拡張が必要）。

### G.3 phase 1 仕様からの逸脱
- `Commit.parents` を活用（phase 1 spec L1 で「phase 2 拡張を妨げない」と明記済み）。
- `renderLog` の出力フォーマット変更（`<hash> <subject> <refs>` → `[graph] [refs] [hash] [subject] [author] [date]`）。phase 1 の `renderLog` 文字列 golden test は**存在しない**（codex 第 1 段レビュー §H-12 で確認: `logRowLayout`/`fitPane` のテストのみ）。新フォーマット用テストは追加扱い。
- `commands.zig logArgv` へ `--topo-order` 追加（★H-03）。phase 1 の `logArgv` テストへ `has_topo_order` 検証を追加。
- 新設 `logPageArgv`（★H-06 tip_hash 付き）。phase 1 の `load_log_page` AppCmd ペイロードへ `tip_hash` 追加・`appcmd.zig` の該当 arm 更新。

### G.4 フィルタ機能への拡張性
- 本設計では対象外だが、将来のフィルタ spec で「フィルタ適用時のグラフ」がどうなるか（フィルタされた commits のみでグラフ再計算 vs 全履歴グラフのままハイライト）を想定しておく。
- `log_graph_state` は `log_commits` と 1:1 なので、フィルタで `log_commits` が差し替わったら `log_graph_state` を `.invalid` へして再構築で対応可能。

### G.5 box-drawing 文字のフォント依存
- `│ ├ └ ┐ ┘ *` は大半の端末フォントで問題無い。`╮ ╯ ╭ ╰`（曲線）は一部フォントで幅が崩れる可能性。
- **推奨**: 最小セット（`│ ├ └ ┐ ┘ ┬ ┴ ─ ┼ *`）をデフォルト。曲線セットは将来オプションで。
- ★rev.1 M-04 省略セル（`⋮`/`…` 等）もフォント依存を確認要。

### G.6 ★rev.1 M-03: commit append の O(N²)（将来課題・phase 2 範囲外）
phase 1 の `appendLogCommits` が既存全 commits を deep-copy するため、page 毎に O(N) の再確保が走り累積 O(N²)。graph 増分だけ最適化しても効果が限定的。

**phase 2 では対応しない**（所有権契約変更は phase 1 spec へ影響し、別 spec で扱うべき）。100 件/ページ・1000 件程度なら実用上問題無い見込み。将来は「arena でまとめて所有」や「copy-on-write」等を検討。

---

## H. codex 第 1 段レビューでの解決確認（rev.1）

第 1 段レビューで出た 12 問いかけは全て解決済み（§0.1 対応表・各節へ反映）。主な確定事項:
1. 方式 B 採用確定。方式 A の却下理由は L-01 修正済み。
2. 増分計算採用（H-04 トランザクション保証付き）。
3. `GraphRow` は semantic data（`Conn` bitset・H-02 反映）。
4. 同期 reducer 計算でよい。
5. カラムは段階的省略（M-05）。
6. 6 色パレット・lane mod 6（L-02）。
7. レーン上限は計算と描画で分離（M-04）。
8. author は広画面で 12 桁・狭画面で縮小/非表示（M-05）。
9. date は author date・ローカル timezone（M-07）。
10. GraphState tagged union で整合性保証（M-02）。
11. テストは before/after frontier + cells の表形式期待値（H-02）。
12. phase 1 `renderLog` 文字列 golden test は存在しない（新フォーマットは追加扱い）。

---

## I. 実装順序の提案（TDD・純粋層 → UI 層・★rev.2 反映: tip/date 確定を前倒し）

1. **★rev.2 前倒し**: date 変換方式（§D.7 UTC 固定）と paging tip 所有型（§B.5 `LoadLogPage`）を先に確定する文書化（コード不要・設計概念の確定）。
2. `src/git/graph.zig`: `Conn`/`GraphRow`/`Frontier`/`GraphState`（`tip_hash`/`isInvariant` 含む） + `computeAll`/`computeIncremental`（★rev.2 H-08 deep-copy 無し・delta + swap） + 単体（線形/分岐/マージ/共通親集約/dense hole/root/octopus/増分/OOM/invariant/`checkAllAllocationFailures`）。
3. `src/root_test.zig`: `@import("git/graph.zig")` を有効化。
4. `src/git/commands.zig`: `logArgv` へ `--topo-order` 追加・新設 `logPageArgv(tip_hash)`。argv 単体テスト更新。
5. `src/messages.zig`: ★rev.2 H-07 `AppCmd.load_log_page` を独立所有型 `LoadLogPage{skip,max_count,generation,tip_hash}` へ。`Msg.LogPageLoaded` へ `request_tip` 追加。網羅的 `deinit` 更新（tip_hash/request_tip を free）。
6. `src/model.zig`: `log_graph_state`/`log_paging_tip` フィールド + `init`/`deinit` 拡張 + `setLogGraphState`/`invalidateLogGraph`/`setLogPagingTip`/`clearLogPagingTip` ヘルパ + 単体。
7. `src/appcmd.zig`: `.load_log_page` arm で `logPageArgv(tip_hash)` を使用・結果 Msg へ `request_tip = dupe(tip_hash)`（★M-10 errdefer）・bad revision 検出（exit 128 → `git_error`・★M-12） + 結合テスト（tip 固定で page 取得・bad revision 時の `git_error`）。
8. `src/update.zig`: `handleLogLoaded`（★H-07 generation + 1 と `setLogPagingTip` 同時・`computeAll`）/`handleLogPageLoaded`（★M-11 `.valid→incremental`/`.invalid→computeAll` switch・★H-07 `request_tip` 照合）/`git_error`（log モード時の bad revision 回復・★M-12）/`toggle_view_mode`/`handleRequestRefreshLog` で `invalidateLogGraph` + `clearLogPagingTip` + 単体（★rev.2 L-05 失敗位置限定）。
9. `src/view.zig`: `renderLog` のカラムレイアウト拡張（graph/refs/hash/subject/author/date・★M-06 refs 前）。★rev.2 M-13 最小 subject 予約・残幅配分。グラフ罫線色ローテーション（6 色・lane mod 6・node bold）。省略セル `⋮`（★rev.2 L-04）。`formatAuthorDateUTC`（★rev.2 M-07(再)） + 単体（`ArenaAllocator`）。
10. README.md: phase 2 表示要素（グラフ/author/日時・date は UTC）と段階的省略の挙動追記。
11. TODO.md: ★codex 第 2 段指摘「TODO 2 phase 2 は現在フィルタ含むため、表示系完了時に phase を分離して誤って全完了扱いしない」。phase 2 を「表示系」と「フィルタ」へ分割し、表示系だけチェックを入れる。フィルタは独立 spec 残。
12. 手動 pty 検証（`tmux capture-pane`）: 分岐/マージ履歴・日本語 author・グラフ色分け・幅 80/120/40 で段階的省略・UTC date。

---

## J. 設計判断サマリ（codex 第 2 段レビュー反映版・rev.2）

| # | 判断 | 推奨（rev.2） | 理由 |
|---|---|---|---|
| A | レーン割当アルゴリズム | **方式 B（frontier-based 自前・dense + 共通親集約 + interior hole 左詰め）** | A は paging と状態継承の不整合・非構造化出力で不適。B は dense + H-01 集約 + M-01(再) hole 左詰めで堅牢 |
| B | 増分 vs 全再計算 | **増分（GraphState.valid.frontier 保持・H-08 delta+swap で O(N²) 解消）** | 大規模リポジトリで O(N×L) 繰り返し回避。OOM は `.invalid` へフォールバック・M-11 で全再構築回復 |
| C | GraphRow の構造 | **1 コミット=1 表示行の cells bitset（H-02(再)・M-08 width=max(before,after,node+1)）** | before/after 2 レイヤーから 1 行 cells へ統合。水平/交差/合流を bitset で表現 |
| D | グラフ計算のタイミング | **reducer 内で同期的（新規 AppCmd 無し）** | 100 件/ページでミリ秒オーダー。ワーカー化は H1 stale reject を複雑化するだけ |
| E | カラムレイアウト | **`[graph] [refs] [hash] [subject] [author] [date]` + 最小 subject 予約・残幅配分（M-13）** | 広画面で全表示・狭画面で subject/hash 優先。refs を subject 前（M-06）で重要情報保護 |
| F | East Asian Width | **zigzag 既存の `zz.width`/`truncate` に任せる** | 独自 table は `unicode_width_strategy` と不整合。phase 1 と同じ前提 |
| G | レーン色 | **6 色固定パレット・lane mod 6・色変化は仕様受容（M-09）・視認補助・node bold（L-03）** | コントラスト重視・色無しでも形で判別。theme 依存は node bold で補強 |
| H | レーン上限 | **計算は全 lane 保持・描画時のみ射影 + 省略セル `⋮`（L-04）** | 描画で切り詰めても計算精度を落とさない。省略記号は 1 種に確定 |
| I | date の意味 | **author date（`%at`）・UTC 固定・`YYYY-MM-DD`（M-07(再)）** | Zig 0.16 に local timezone API 無し。ローカルは将来オプション（libc 連携） |
| J | paging 間の履歴 snapshot | **tip hash 固定・generation と一体（H-07）・結果 Msg request_tip 照合・bad rev で全 refresh（M-12）** | page 間の HEAD/ref 移動でグラフ破綻を防ぐ。H-06(再) page 先頭親検証は削除 |
| K | GraphState の整合性 | **tagged union で valid/invalid を保証・それ以外は runtime invariant（M-14）** | 型で過大保証せず・compute/描画入口で `isInvariant` で検証 |

---

## 付録: phase 1 spec からの引用（本設計が依存する規約）

- **H1（stale-result reject）**: 全ての結果 Msg は `request_hash`/`request_generation`/`request_skip` を持ち、reducer が model の owner/generation と照合。phase 2 のグラフ計算は generation 検証を通過した arm 内でのみ実行されるため、stale なグラフは構築されない。
- **H6/R1（所有権）**: `replaceLogCommits`/`appendLogCommits` は deep-copy → swap・append 毎に errdefer。`replaceLogGraph`/`appendLogGraph` も同型。
- **R22（OOM で page_requested を先に null 化）**: グラフ計算の OOM でも `log_graph_valid = false` を先にセットし、reducer が error return してもフォールバック可能にする。
- **R3（mode 退出時の generation 無効化）**: `toggle_view_mode`/`request_refresh` で generation を進めたらグラフもクリア。
- **M9（プレーン `\n` 結合）**: `renderLog` は `zz.joinVertical` を使わず `std.mem.join(a, "\n", ...)`。
- **fitPane gotcha**: 各行をペイン幅へ切り詰め（`zz.measure.truncate`）てから `zz.place.place` で右パディング。グラフ罫線を含む行も同じ扱い。
- **L1（phase 2 拡張）**: `Commit.parents: [][]u8` は phase 2 レーン割当の入力。phase 1 実装で既に存在。

