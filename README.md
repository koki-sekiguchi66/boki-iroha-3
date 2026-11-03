# ケースで学ぶ簿記3級

身近な会社の21のケースを通じて、日商簿記3級の全範囲を学ぶ HTML 教科書です。

## 読み方

- `public/index.html` をブラウザで開くと、表紙と目次が表示されます（スマートフォン最適化済み）。
- `public/all.html` は全章を1ファイルにまとめた一気読み版です（オフライン閲覧や印刷向け）。
- 表示には Tailwind CSS（CDN）と Google Fonts を読み込むため、インターネット接続が必要です。

## 構成

| パス | 内容 |
| --- | --- |
| `public/` | **公開するファイル（HTMLのみ）**。`build.pl` が自動生成する |
| `public/index.html` | 表紙と目次（学習を始めるための最小限の情報だけ） |
| `public/guide.html` | 本書の使い方（ボックスの見方・学習の進め方・出題範囲） |
| `public/ch00.html` | 序章　黒字倒産と、簿記を学ぶ意味 |
| `public/ch01.html`〜`ch19.html` | 第1章〜第19章（簿記の基本原理 → 諸取引 → 決算） |
| `public/ch20.html` | 終章　2級・1級、そして実務へ |
| `public/apx-a.html` | 付録A　勘定科目・完全辞典 |
| `public/apx-b.html` | 付録B　試験攻略マニュアル |
| `public/apx-c.html` | 付録C　仕訳道場（第1問対策・64問） |
| `public/apx-d.html` | 付録D　模擬試験（本試験形式・60分） |
| `public/all.html` | 全章一気読み版 |
| `_src/` | 本文の原稿（公開しない） |
| `build.pl` | HTMLを生成するスクリプト（公開しない） |

出題範囲は、2026年度（2027年3月まで）の試験に適用される出題区分表（2022年度適用版）を網羅し、2027年4月以降の改定点（2025年12月公表の暫定版）も併記しています。

## 公開（Cloudflare Pages）

サイトとして配信するのは `public/` の中身だけです。Cloudflare Pages のビルド設定は次のとおりにします。

| 項目 | 設定値 |
| --- | --- |
| Production branch | `main` |
| Framework preset | `None` |
| Build command | 空欄 |
| Build output directory | `public` |

`main` に push すると自動で再デプロイされます。

## 編集・再生成

本文は `_src/*.txt`（独自の軽量マークアップ）に書かれており、`build.pl` が Tailwind のクラス付き HTML を `public/` に生成します。追加モジュール不要の Perl 5 で動きます（Git Bash 同梱の Perl で可）。

```sh
perl build.pl
git add -A
git commit -m "変更内容"
git push
```

- 記法の一覧は `build.pl` 冒頭のコメントを参照してください。
- 章の並びは `_src/book.txt` で管理しています。
- ビルド時に、すべての仕訳の貸借一致、T字勘定の合計、`sum` 指定した帳簿・試算表・財務諸表の縦計、表の列数を自動で検証します。不一致があると警告を表示して終了コード1で終わります。
- 例題・確認問題のうち、解答に仕訳があるものには「TRY」欄（勘定科目のドラッグ＋金額入力＋答え合わせ）が自動で付きます。分類問題は `::sort` ブロックで書きます。ページの URL に `?selftest` を付けて開くと、全演習の自己テスト結果が表示されます。

本書に登場する企業・人物・数値は、すべて学習用に設計した架空のものです。
