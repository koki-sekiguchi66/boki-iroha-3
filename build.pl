#!/usr/bin/env perl
# ======================================================================
#  ケースで学ぶ簿記3級 ― 静的サイトジェネレーター（Perl 5 / 追加モジュール不要）
#
#  使い方:   perl build.pl          （Git Bash などから実行）
#  入力:     _src/book.txt   … 章の並び（1行1ID）。「@title 書名」などの行で本の設定を変えられる
#                              （@title @subtitle @hero @mark @start @key @scope @site。なければ3級の既定値）
#                              「@site https://…」と書くと、canonical・OGP と sitemap.xml・robots.txt を出力する
#                              「@hook 一言」：表紙のつかみの一言。「@stats 21件:事件で学ぶ | 164問:仕訳の入力問題 | …」：表紙の学習明細書（レシート）の行
#            _src/index.txt  … 表紙ページの本文
#            _src/<id>.txt   … 各章の本文（独自マークアップ）
#  出力:     public/ に index.html / <id>.html / all.html（全章一気読み版）
#            ※公開（Cloudflare Pages）するのは public/ の中身だけ
#
#  ■ 章ファイル先頭のメタデータ
#    @num 第3章   @part 第2部 …   @title 問い（章タイトル）   @subtitle 論点名
#    @lead 紹介文   @goal この章で学ぶこと（複数行可）   @time 25分   @level ★★☆
#
#  ■ 行の記法
#    ## 見出し（自動採番・章内目次に掲載） / ### 小見出し / #### 小小見出し
#    - 箇条書き（2スペース字下げで2階層目） / 1. 番号付き / > 引用 / --- 区切り線
#    **太字**  ==マーカー==  !!赤字!!  [リンク](url)  {{new:バッジ}}  <br>
#    行頭が < の行は生HTMLとしてそのまま出力
#
#  ■ ブロック記法（"::名前 引数" で開き、"::" だけの行で閉じる）
#    コンテナ（入れ子可）:
#      mystery theory danger cfo answer exam next solve scene case
#      example problem quiz summary point formula tgrid note
#      real   … 実際にあった話（出典は中の ::note に書く）
#      choice … cfo の中に「::choice A. 選択肢」を並べると選択式になる（中身はその選択へのフィードバック。
#               選ぶまで解説 ::answer は開かない）
#    データ（入れ子不可）:
#      journal  … 「借方科目 金額 | 貸方科目 金額」（貸借一致を自動検証）
#                 見出しの先頭に【…】を書くと、演習の入力欄の見出しにその文字を使う（例：「::journal 【(1) 期首商品】しーくり」）。
#                 同じ番号の仕訳が複数あるときは、問題文に出てくる当事者名（会社名など）を自動で見出しに足す
#      taccount … 「摘要 金額 | 摘要 金額」、合計行は「= 金額 | 金額」
#      table    … パイプ区切り。1行目が見出し。"!!" 行で2段見出し（"受入*3" = 3列結合）
#                 "|=" で始まる行は強調行。引数の先頭に compact / sum / split:N を付けられる
#      boxes    … 「H 左見出し | 右見出し」「L|R 色 数値 ラベル」（色: a l e x r p s z k d）
#      steps / kpi / timeline … 「項目 | 説明 | 補足」
#      toc      … 目次（表紙用）
#      sort     … ドラッグで分類する演習。「@cats 分類1 | 分類2 …」と「項目 => 正しい分類」を並べる
#      checks   … チェック表の演習。1行目が見出し、2行目以降は「行の名前 | 正解のマスに ✓ | …」
#      sim      … シミュレーター（"::sim fifo|ccc|dep タイトル"、"@expect キー=値" は本文の数値との照合用）
#      mock     … 模擬試験モード（"::mock 制限時間（分）"、各行「大問の見出し | 配点」）
#
#  ■ 演習の自動生成
#    example / problem の answer に journal があれば、仕訳の入力欄（ドラッグ＋金額入力＋答え合わせ）を
#    自動で付ける。付けたくない問題は、問題文に <!-- notry --> の行を入れる。
#    問題文に [[答え]] / [[ア:答え]] / [[答え@15・18]] を書くと穴埋めの入力欄になる（数値は入力、語句は選択式。
#    選択肢は答え＋「<!-- choices: A | B -->」。[[]] は空けておくのが正解の欄。@ の後は復習する章）。
#    本文の勘定科目には、付録A（apx-a.txt）の辞典から用語のポップアップを自動で付ける。
#    ブラウザで動く処理は assets/kb.js にあり、各ページへそのまま埋め込む。
#    ページの URL に ?selftest を付けて開くと、全演習の自己テスト結果が画面上部に表示される。
# ======================================================================
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));
use FindBin qw($Bin);
use JSON::PP;

my $ROOT     = $Bin;
my $SRC      = "$ROOT/_src";
my $OUT      = "$ROOT/public";    # 公開用の出力先（Cloudflare Pages の Build output directory）
mkdir $OUT or die "出力先を作成できません $OUT: $!\n" unless -d $OUT;
my $KBJS     = -e "$ROOT/assets/kb.js" ? slurp("$ROOT/assets/kb.js") : '';    # 演習・シミュレーター・用語・模擬試験
# 本の設定：book.txt の「@キー 値」の行で上書きできる（なければ3級の既定値）
my %CFG      = map { /^@(\w+)\s+(.*)$/ ? ($1 => $2) : () } map { trim($_) } split /\n/, slurp("$SRC/book.txt");
my $BOOK     = $CFG{title}    // 'ケースで学ぶ簿記3級';
my $BOOK_SUB = $CFG{subtitle} // '身近な会社の数字で、日商簿記3級の全範囲を学ぶ';
my $HERO     = $CFG{hero}     // 'ケースで学ぶ<br>簿記3級';    # 表紙の大見出し（<br> で改行）
my $MARK     = $CFG{mark}     // '簿';                        # ヘッダーの1文字ロゴ
my $START    = $CFG{start}    // '序章から読む';              # 表紙の「最初の章へ」ボタン
my $KEY      = $CFG{key}      // 'kb3';                       # localStorage のキーの接頭辞（本ごとに変える）
my $SITE     = $CFG{site}     // '';                          # 公開URL。canonical・OGP・sitemap.xml・robots.txt に使う（なければ出力しない）
$SITE =~ s{/+$}{};
my $SCOPE    = $CFG{scope}    // '出題範囲は日本商工会議所「商工会議所簿記検定試験 出題区分表」（2022年度適用版。2026年度の試験まで適用）に準拠し、2027年4月以降の試験に適用される改定（暫定版）の要点も併記しています。受験前に必ず日本商工会議所の公式情報をご確認ください。';
$KBJS =~ s/'kb3-/'$KEY-/g;

our ($CUR, $DARK, $SECN) = ('', 0, 0);
our %CTX;
my (@WARN, %TOC, %META, %BODY, %RENDERED, %NCHK);    # %NCHK: 検証した件数

# ---------------------------------------------------------------- utils
sub slurp {
    my $f = shift;
    open(my $fh, '<:encoding(UTF-8)', $f) or die "読み込み失敗 $f: $!\n";
    local $/;
    my $s = <$fh>;
    close $fh;
    $s =~ s/\r\n?/\n/g;
    $s =~ s/^\x{FEFF}//;
    return $s;
}

sub spew {
    my ($f, $s) = @_;
    open(my $fh, '>:encoding(UTF-8)', $f) or die "書き込み失敗 $f: $!\n";
    print {$fh} $s;
    close $fh;
}

sub esc {
    my $s = shift // '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub trim { my $s = shift // ''; $s =~ s/^\s+|\s+$//g; return $s; }

# 穴埋めの空欄 [[答え]] / [[ラベル:答え]] / [[答え@15・18]]（@ の後は、間違えたときに復習する章）
# を、検証用に答えの文字列へ戻す
my $BLANK_RE = qr/\[\[(?:([^\]:\s]{1,4}):)?([^\]@]*)(?:@([\d・]+))?\]\]/;
sub unblank {
    my $s = shift // '';
    $s =~ s/$BLANK_RE/$2/g;
    return $s;
}

my %BADGE = (
    new => 'bg-amber-100 text-amber-800 ring-1 ring-amber-300',
    old => 'bg-gray-100 text-gray-600 ring-1 ring-gray-300',
    dr  => 'bg-blue-100 text-blue-800',
    cr  => 'bg-rose-100 text-rose-800',
    a   => 'bg-blue-600 text-white',
    l   => 'bg-rose-500 text-white',
    e   => 'bg-emerald-600 text-white',
    x   => 'bg-amber-500 text-white',
    r   => 'bg-violet-600 text-white',
    tag => 'bg-gray-800 text-white',
);

sub inl {
    my $s = esc(shift);
    $s =~ s{&lt;br&gt;}{<br>}g;
    $s =~ s{$BLANK_RE}{blank_html($1, $2, $3)}ge;    # 穴埋めの空欄 → 入力欄
    $s =~ s{\{\{(\w+):(.+?)\}\}}{
        my $c = $BADGE{$1} // $BADGE{tag};
        qq{<span class="mx-0.5 inline-block whitespace-nowrap rounded px-1.5 py-1 align-[0.1em] text-[11px] font-bold leading-none $c">$2</span>}
    }ge;
    $s =~ s{\^\^(.+?)\^\^}{<span class="text-[11px] font-normal leading-tight text-gray-500">$1</span>}g;    # ^^小さな補足^^
    $s =~ s{\*\*(.+?)\*\*}{<strong class="font-bold">$1</strong>}g;
    $s =~ s{==(.+?)==}{<mark class="mk">$1</mark>}g;
    my $red = $DARK ? 'text-red-400' : 'text-red-600';
    $s =~ s{!!(.+?)!!}{<span class="font-bold $red">$1</span>}g;
    # 「第7章」のような短いリンクは改行させない。出典のような長いリンクは、スマホの幅で折り返す
    $s =~ s{\[([^\]]+?)\]\(([^)\s]+)\)}{
        my ($t, $u) = ($1, $2);
        my $wrap = length($t =~ s/<[^>]*>//gr) <= 10 ? 'whitespace-nowrap' : 'break-words';
        qq{<a href="$u" class="$wrap font-bold underline decoration-shu/50 decoration-1 underline-offset-[5px] transition hover:text-shu hover:decoration-shu">$t</a>}
    }ge;
    return $s;
}

# 金額文字列 → 数値（数値でなければ undef）
sub amt {
    my $s = unblank(shift);
    return undef unless defined $s && $s =~ /\d/;
    return undef if $s =~ /[?？□（(ア-ン]/;
    my $neg = ($s =~ /^\s*[△▲\-−]/) ? -1 : 1;
    (my $d = $s) =~ s/[^\d.]//g;
    return undef if $d eq '';
    return $neg * $d;
}

sub is_num {
    my $s = unblank(shift // '');
    return $s =~ /^\s*[@＠¥￥△▲\-−+(（]*\s*\d[\d,.]*\s*[)）%]*\s*(?:円|万円|億円|千円|kg|g|個|台|本|人|名|か月|ヶ月|年|日|件|回|食|杯|枚|席|口|%|倍|ポイント|pt)?\s*$/;
}

# 「勘定科目 金額」を分解（金額は末尾の数値。穴埋め用の「？」「（ア）」、数値の空欄 [[…]] も可）
sub side {
    my $t = trim(shift);
    return ('', '') if $t eq '';
    if ($t =~ /^(.*\S)\s+(\S+)$/) {
        my ($acct, $v) = ($1, $2);
        return ($acct, $v) if is_num($v) || $v =~ /^(?:[?？□]+|（.*）|\(.*\))$/ || $v =~ /^\[\[(?:[^\]:\s]{1,4}:)?\]\]$/;
    }
    return ($t, '');
}

sub cells {
    my $l = shift;
    $l =~ s/^\s*\|//;
    $l =~ s/\|\s*$//;
    return map { trim($_) } split /\|/, $l, -1;
}

# ---------------------------------------------------------------- parse
my %RAW       = map { $_ => 1 } qw(journal taccount table boxes steps kpi timeline toc sort checks sim mock);
my %CONTAINER = map { $_ => 1 } qw(mystery theory danger cfo choice real answer trap exam next solve scene case example problem quiz summary point formula tgrid note);

sub parse {
    my ($L, $ip, $nested) = @_;
    my @nodes;
    while ($$ip < @$L) {
        my $line = $L->[$$ip];
        if ($line =~ /^::\s*$/) {
            die "[$CUR] " . ($$ip + 1) . "行目: 対応する開始のない '::'\n" unless $nested;
            $$ip++;
            return \@nodes;
        }
        if ($line =~ /^::([a-z]+)\s*(.*?)\s*$/) {
            my ($name, $arg) = ($1, $2);
            my $start = $$ip + 1;
            $$ip++;
            if ($RAW{$name}) {
                my @raw;
                while ($$ip < @$L && $L->[$$ip] !~ /^::\s*$/) { push @raw, $L->[$$ip]; $$ip++; }
                die "[$CUR] ${start}行目: ::$name が閉じられていません\n" if $$ip >= @$L;
                $$ip++;
                push @nodes, { t => 'raw', name => $name, arg => $arg, lines => \@raw, line => $start };
            }
            elsif ($CONTAINER{$name}) {
                my $kids = parse($L, $ip, "::$name（${start}行目）");
                push @nodes, { t => 'box', name => $name, arg => $arg, kids => $kids, line => $start };
            }
            else {
                die "[$CUR] ${start}行目: 不明なブロック ::$name\n";
            }
            next;
        }
        if ($line =~ /^\s*$/) { $$ip++; next; }
        if ($line =~ /^(#{2,4})\s+(.*)$/) {
            push @nodes, { t => 'h', level => length($1), text => $2 };
            $$ip++;
            next;
        }
        if ($line =~ /^-{3,}\s*$/) { push @nodes, { t => 'hr' }; $$ip++; next; }
        if ($line =~ /^\s*- /) {
            my @items;
            while ($$ip < @$L && $L->[$$ip] =~ /^(\s*)- (.*)$/) {
                push @items, [length($1) >= 2 ? 1 : 0, $2];
                $$ip++;
            }
            push @nodes, { t => 'ul', items => \@items };
            next;
        }
        if ($line =~ /^\d+\.\s/) {
            my @items;
            while ($$ip < @$L && $L->[$$ip] =~ /^\d+\.\s+(.*)$/) { push @items, $1; $$ip++; }
            push @nodes, { t => 'ol', items => \@items };
            next;
        }
        if ($line =~ /^>\s?(.*)$/) {
            my @q;
            while ($$ip < @$L && $L->[$$ip] =~ /^>\s?(.*)$/) { push @q, $1; $$ip++; }
            push @nodes, { t => 'quote', lines => \@q };
            next;
        }
        if ($line =~ /^</) { push @nodes, { t => 'html', text => $line }; $$ip++; next; }
        push @nodes, { t => 'p', text => $line };
        $$ip++;
    }
    die "[$CUR] $nested が閉じられていません（:: が不足）\n" if $nested;
    return \@nodes;
}

# ---------------------------------------------------------------- 用語のポップアップ（付録Aの勘定科目辞典から作る）
#   本文の段落・箇条書きに出てくる勘定科目を、見出し（##）ごとに最初の1回だけタップできるようにする。
#   日常語としても使う科目（現金・売上など）は対象外。長い科目名を優先し、熟語の一部（「売掛金元帳」の「売掛金」など）は対象外。
my (%TERM, %TUSED, $TERMRE);
my %NOLINK = map { $_ => 1 } qw(現金 売上 仕入 商品 損益 土地 建物 備品 給料);

sub load_terms {
    my $f = "$SRC/apx-a.txt";
    return unless -e $f;
    my ($cat, $in) = ('', 0);
    for my $l (split /\n/, slurp($f)) {
        if ($l =~ /^::table\s+(.*)$/) {
            my $c = $1;
            $cat = $c =~ /^(資産|負債|純資産|収益|費用)の勘定科目/ ? $1 : $c =~ /^評価勘定/ ? '評価勘定' : $c =~ /^その他の勘定/ ? 'その他' : '';
            $in = $cat ne '';
            next;
        }
        if ($l =~ /^::\s*$/) { $in = 0; next; }
        next unless $in && $l =~ /^\|/;
        my ($name, $desc, $ch) = cells($l);
        next if !defined $desc || $name eq '勘定科目';
        my $badge = $name =~ /\{\{(new|old):/ ? $1 : '';
        $name =~ s/\{\{.*?\}\}//g;
        my $yomi = $name =~ s/<br>\^\^(.*?)\^\^// ? $1 : '';
        $name = trim($name);
        $name =~ s/（.*?）$//;    # 「前払費用（前払保険料など）」→ 前払費用
        my ($lab, $href) = ($ch // '') =~ /\[([^\]]+)\]\(([^)]+)\)/ ? ($1, $2) : ('', '');
        my $id = $href =~ /^([\w-]+)\.html$/ ? $1 : '';
        $lab = "第$lab" if $lab =~ /^\d/;
        my $first = 1;
        for my $n (split /・/, $name) {
            $TERM{$n} = { y => ($first ? $yomi : ''), c => $cat, d => $desc, id => $id, l => $lab, b => $badge };
            $first = 0;
        }
    }
    my @names = sort { length($b) <=> length($a) || $a cmp $b } grep { !$NOLINK{$_} } keys %TERM;
    $TERMRE = join '|', map { quotemeta } @names if @names;
}

sub termify {
    my $h = shift;
    return $h unless $TERMRE && $CTX{terms};
    my $seen = ($CTX{tseen} //= {});
    my ($out, $skip) = ('', 0);
    for my $part (split /(<[^>]*>)/, $h) {
        if ($part =~ /^</) {
            if    ($part =~ m{^<(?:a|button|select|label|textarea)\b}i)    { $skip++; }
            elsif ($part =~ m{^</(?:a|button|select|label|textarea)>}i)    { $skip-- if $skip > 0; }
            $out .= $part;
            next;
        }
        if (!$skip) {
            $part =~ s{(?<![\p{Han}\p{Katakana}ー])($TERMRE)(?=勘定|[^\p{Han}\p{Katakana}ー]|$)}{
                my $t = $1;
                if ($seen->{$t}++) { $t }
                else {
                    $TUSED{$CUR}{$t} = 1;
                    qq{<button type="button" class="kb-term cursor-help underline decoration-gray-400 decoration-dotted decoration-2 underline-offset-[5px] transition hover:text-amber-700 hover:decoration-amber-500" data-term="$t" aria-haspopup="dialog">$t</button>};
                }
            }ge;
        }
        $out .= $part;
    }
    return $out;
}

my %CATBADGE = (
    '資産' => 'bg-blue-100 text-blue-800', '負債' => 'bg-rose-100 text-rose-800', '純資産' => 'bg-emerald-100 text-emerald-800',
    '収益' => 'bg-violet-100 text-violet-800', '費用' => 'bg-amber-100 text-amber-800', '評価勘定' => 'bg-slate-200 text-slate-800', 'その他' => 'bg-gray-100 text-gray-700',
);
my %HOMEPOS = (
    '資産' => '増えたら借方（左）', '費用' => '増えたら借方（左）', '負債' => '増えたら貸方（右）', '純資産' => '増えたら貸方（右）',
    '収益' => '増えたら貸方（右）', '評価勘定' => '残高は貸方（資産から差し引く）', 'その他' => '',
);

sub terms_block {    # ページで使った用語のデータと、ポップアップの枠
    my ($ids, $mode, $cur) = @_;
    my %out;
    for my $id (@$ids) {
        for my $t (keys %{ $TUSED{$id} || {} }) {
            my $e = $TERM{$t};
            $out{$t} = {
                y  => $e->{y}, c => $e->{c}, cc => $CATBADGE{ $e->{c} } // '', hp => $HOMEPOS{ $e->{c} } // '',
                d  => $e->{d}, l => $e->{l},
                b  => ($e->{b} eq 'new' ? '2027年度〜' : $e->{b} eq 'old' ? '2027年度〜範囲外' : ''),
                bc => ($e->{b} ? $BADGE{ $e->{b} } : ''),
                h  => ($e->{id} && $e->{id} ne ($cur // '') ? href_for($e->{id}, $mode) : ''),
            };
        }
    }
    return '' unless %out;
    my $json = JSON::PP->new->canonical(1)->encode(\%out);
    $json =~ s{</}{<\\/}g;
    my $dict = href_for('apx-a', $mode);
    my $safe = join ' ', sort values %CATBADGE;
    return qq{<script type="application/json" id="kb-terms">$json</script>\n}
         . qq{<div id="kb-pop" role="dialog" aria-label="用語の説明" class="no-print absolute z-50 hidden w-[min(20rem,calc(100vw-1.5rem))] rounded-lg border border-gray-200 bg-white p-4 text-left text-gray-800 shadow-xl">}
         . qq{<div class="flex items-start gap-2"><div class="min-w-0 flex-1"><p class="text-[11px] leading-tight text-gray-500" data-f="y"></p><p class="text-lg font-black leading-snug text-gray-900" data-f="n"></p></div>}
         . qq{<button type="button" data-close class="-mr-2 -mt-2 flex h-9 w-9 flex-none items-center justify-center rounded-full text-xl leading-none text-gray-400 hover:bg-gray-100 hover:text-gray-700" aria-label="閉じる">×</button></div>}
         . qq{<div class="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1"><span class="rounded px-1.5 py-0.5 text-[11px] font-bold" data-f="c"></span><span class="text-[11px] font-bold text-gray-500" data-f="hp"></span><span class="hidden rounded px-1.5 py-0.5 text-[11px] font-bold" data-f="b"></span></div>}
         . qq{<p class="mt-2 text-sm leading-relaxed text-gray-700" data-f="d"></p>}
         . qq{<div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm font-bold"><a class="text-amber-700 underline decoration-amber-400 decoration-2 underline-offset-4" data-f="h"></a><a href="$dict" class="text-gray-500 underline decoration-gray-300 underline-offset-4 hover:text-gray-800">勘定科目辞典</a></div>}
         . qq{<span class="hidden $safe $BADGE{new} $BADGE{old}"></span></div>\n};
}

# ---------------------------------------------------------------- render: lines
sub r_h {
    my ($lv, $t) = @_;
    my $c = $DARK ? 'text-white' : 'text-gray-900';
    if ($lv == 2) {
        $SECN++;
        my $id = "$CUR-s$SECN";
        push @{ $TOC{$CUR} }, [$id, $t];
        $CTX{h2}    = $t;     # 演習がどの大問（見出し）に属するか（模擬試験の採点用）
        $CTX{tseen} = {};     # 用語のリンクは見出しごとに最初の1回だけ
        my $n = sprintf('%02d', $SECN);
        # 帳簿の見出し行：太い罫の上に、朱の番号札を掛ける
        return qq{<h2 id="$id" data-sec class="relative mb-7 mt-24 scroll-mt-20 border-t-2 border-gray-900 pt-11 font-serif text-[1.45rem] font-black leading-snug $c [word-break:auto-phrase] sm:text-[1.8rem]">}
             . qq{<span aria-hidden="true" class="absolute -top-[2px] left-0 flex items-stretch font-sans text-[10px] font-bold leading-none tracking-[0.25em]"><span class="flex items-center bg-gray-900 px-2 py-1.5 text-gray-50">SECTION</span><span class="bg-shu px-2 py-1.5 font-serif text-[13px] font-black tracking-normal text-white">$n</span></span>}
             . qq{<span aria-hidden="true" class="absolute right-0 top-2 select-none font-serif text-[11px] font-bold tracking-[0.2em] text-gray-400">$n / __SECTOTAL__</span>}
             . '<span>' . inl($t) . '</span></h2>';
    }
    if ($lv == 3) {
        my $b = $DARK ? 'border-amber-400' : 'border-shu';
        return qq{<h3 class="mb-4 mt-14 flex items-baseline gap-3 font-serif text-lg font-black leading-snug $c sm:text-xl"><span aria-hidden="true" class="h-[0.55em] w-[0.55em] flex-none translate-y-[-0.1em] rotate-45 border-2 $b"></span><span class="min-w-0">} . inl($t) . '</span></h3>';
    }
    return qq{<h4 class="mb-3 mt-9 flex items-center gap-2.5 font-bold leading-snug $c"><span aria-hidden="true" class="h-px w-4 flex-none bg-shu"></span><span class="min-w-0">} . inl($t) . '</span></h4>';
}

sub r_ul {
    my $items = shift;
    my $check = $CTX{check};
    my $html  = $check ? '<ul class="my-5 space-y-3">' : '<ul class="my-5 list-[square] space-y-2 pl-5 marker:text-shu/70">';
    my $sub   = 0;
    for my $i (0 .. $#$items) {
        my ($lv, $t) = @{ $items->[$i] };
        if ($lv == 0 || $i == 0) {
            if ($sub) { $html .= '</ul>'; $sub = 0; }
            $html .= '</li>' if $i > 0;
            if ($check) {
                $html .= '<li class="flex gap-3 leading-[1.8]"><span aria-hidden="true" class="mt-0.5 flex h-6 w-6 flex-none rotate-[-10deg] items-center justify-center rounded-full border-[1.5px] border-shu font-serif text-[10px] font-black leading-none text-shu">済</span><span>' . inl($t) . '</span>';
            }
            else {
                $html .= '<li class="leading-[1.85]">' . inl($t);
            }
        }
        else {
            if (!$sub) { $html .= '<ul class="mt-2 list-[circle] space-y-1 pl-5 marker:text-gray-400">'; $sub = 1; }
            $html .= '<li class="leading-[1.8]">' . inl($t) . '</li>';
        }
    }
    $html .= '</ul>' if $sub;
    $html .= '</li></ul>';
    return $html;
}

# ---------------------------------------------------------------- 物語の会話（吹き出し）
#   原稿の「名前：「せりふ」」は、名前と頭文字の札がついた吹き出しになる。主人公（ひより）は右側に置く。
#   「…」と佐伯は言った。／佐伯は首を振った。「…」のように地の文と混ざった行も、話し手が登場人物だと
#   分かる形のときは、地の文と吹き出しに分ける。
my @CAST   = qw(ひより 一ノ瀬 鴨川 所長 佐伯 坂口 岩井 三好 三國 柏木 森下 村井 中西 北村 大森 島田 谷口 岡崎 浅井 松尾 真壁 西條 早瀬 鳥羽 富岡 片山 小野 木島 父 担当者 投資家 課長 店長 社長);
my $CASTRE = join '|', map { quotemeta } sort { length($b) <=> length($a) } @CAST;
my %SAYCOL = ('ひより' => '#C8462E', '一ノ瀬' => '#2F4A6D', '佐伯' => '#3E7C7A', '鴨川' => '#6D4C6A', '所長' => '#6D4C6A', '柏木' => '#5E7D63', '中西' => '#8A5A44', '父' => '#B8862F');
my @SAYPAL = ('#2F4A6D', '#3E7C7A', '#6D4C6A', '#5E7D63', '#8A5A44', '#946A20', '#545C68');
my $PLAINV = qr/(?:言った|言う|聞いた|聞き返した|尋ねた|たずねた|答えた|続けた|つぶやいた|切り出した|口を開いた)/;

sub say_html {
    my ($who, $say) = @_;
    my $col = $SAYCOL{$who} // $SAYPAL[ hval($who, 7) % @SAYPAL ];
    my $me  = $who eq 'ひより';
    my $bub = $DARK ? 'border-white/45 bg-white/10 text-white' : 'border-gray-900/70 bg-white text-gray-900 shadow-[3px_3px_0_0_rgba(27,36,48,.12)]';
    my $nmc = $DARK ? 'text-white/80' : 'text-gray-600';
    my $ini = esc(substr($who, 0, 1));
    return '<div class="my-3.5 flex items-start gap-2.5 font-sans' . ($me ? ' flex-row-reverse' : '') . '">'
         . qq{<span aria-hidden="true" class="mt-4 flex h-9 w-9 flex-none items-center justify-center rounded-full font-serif text-sm font-black text-white ring-2 ring-white/70" style="background:$col">$ini</span>}
         . '<div class="flex min-w-0 max-w-[84%] flex-col' . ($me ? ' items-end' : ' items-start') . '">'
         . qq{<span class="mb-0.5 px-1 text-[11px] font-bold leading-none $nmc">} . esc($who) . '</span>'
         . termify(qq{<p class="w-fit rounded-[16px] } . ($me ? 'rounded-tr-[3px]' : 'rounded-tl-[3px]') . qq{ border $bub px-4 py-2.5 text-[15px] font-bold leading-[1.75] sm:text-base">} . inl($say) . '</p>')
         . "</div></div>\n";
}

sub story_split {
    my $t = shift;
    my $Q = qr/「((?:(?!」|「).)+)」/;    # かぎ括弧の中に別のかぎ括弧がない、ひと続きのせりふ
    return (['say', $1, $2]) if $t =~ /^([^「」：\s]{1,8})：「(.+)」$/;
    # 「…」と佐伯は言った。（「…」が続くこともある）
    if ($t =~ /^$Q(?:と、?|。と、?)($CASTRE)(?:は|が|も)([^「」]*?。)(?:$Q)?$/) {
        my ($q1, $who, $rest, $q2) = ($1, $2, $3, $4);
        my @p = (['say', $who, $q1]);
        push @p, ['p', "$who\は$rest"] unless $rest =~ /^、?(?:そう)?$PLAINV。$/;
        push @p, ['say', $who, $q2] if defined $q2;
        return @p;
    }
    # 佐伯は首を振った。「…」
    if ($t =~ /^([^「」]*。)$Q$/) {
        my ($narr, $q) = ($1, $2);
        my ($last) = $narr =~ /([^。]*。)$/;    # せりふの直前の一文に「〜は」と書かれた人物を、話し手とみなす
        my @who = ($last =~ /から、?[^。]*(?:聞いた|聞かれた|言われた)/) ? () : ($last =~ /($CASTRE)は/g);
        if (@who) { print STDERR "AUTO $CUR $who[-1] <= ", substr($narr, -28), "
" if $ENV{KB_DEBUG}; return (['p', $narr], ['say', $who[-1], $q]); }
    }
    return ();
}

sub rn {
    my ($nodes, $parent) = @_;
    $parent //= '';
    my $h = '';
    for my $n (@$nodes) {
        my $t = $n->{t};
        if ($t eq 'p' && $parent =~ /^(?:|mystery|scene|solve|cfo|answer|choice)$/ and my @parts = story_split($n->{text})) {
            # 物語の会話は、名前つきの吹き出しにする（地の文と混ざった行は、地の文と吹き出しに分ける）
            $h .= ($_->[0] eq 'say' ? say_html($_->[1], $_->[2]) : termify('<p class="my-5 leading-[1.95]">' . inl($_->[1]) . '</p>') . "\n") for @parts;
            next;
        }
        if    ($t eq 'p')     { $h .= termify('<p class="my-5 leading-[1.95]">' . inl($n->{text}) . '</p>'); }
        elsif ($t eq 'h')     { $h .= r_h($n->{level}, $n->{text}); }
        elsif ($t eq 'hr')    { $h .= '<div role="separator" class="rule-mark"><i></i><i></i><i></i></div>'; }
        elsif ($t eq 'ul')    { $h .= termify(r_ul($n->{items})); }
        elsif ($t eq 'ol')    { $h .= termify('<ol class="my-5 list-decimal space-y-2 pl-6 marker:font-serif marker:font-black marker:text-shu">' . join('', map { '<li class="leading-[1.85]">' . inl($_) . '</li>' } @{ $n->{items} }) . '</ol>'); }
        elsif ($t eq 'quote') { $h .= termify('<blockquote class="relative my-8 border-y border-gray-900/15 py-4 pl-10 pr-2 font-serif text-gray-700 before:absolute before:left-1 before:top-4 before:text-4xl before:font-black before:leading-none before:text-shu/70 before:content-[open-quote]">' . join('', map { '<p class="my-2 leading-[1.9]">' . inl($_) . '</p>' } @{ $n->{lines} }) . '</blockquote>'); }
        elsif ($t eq 'html')  { $h .= $n->{text}; }
        elsif ($t eq 'raw')   { $h .= r_raw($n); }
        elsif ($t eq 'box')   { $h .= r_box($n, $parent); }
        $h .= "\n";
    }
    return $h;
}

sub inner {
    my ($k, $name) = @_;
    return '<div class="[&>*:first-child]:mt-0 [&>*:last-child]:mb-0">' . rn($k, $name) . '</div>';
}

sub label {
    my ($cls, $txt) = @_;
    return qq{<p class="mb-1 text-[11px] font-bold tracking-[0.25em] $cls">$txt</p>};
}

# ---------------------------------------------------------------- render: boxes
sub slip_open {    # 見出しタブつきの枠（ホームの「事件ファイル」と同じ形）。閉じるときは slip_close
    my ($tag, $attrs, $tabbg, $en, $ja, $boxcls, $deco) = @_;
    return qq{<div class="my-10"><p class="inline-flex items-center gap-2.5 px-3.5 py-1.5 text-[10px] font-bold tracking-[0.25em] text-white $tabbg"><span>$en</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.15em]">$ja</span></p>}
         . qq{<$tag$attrs class="relative $boxcls p-5 sm:p-7">} . ($deco // '') . '<div class="relative">';
}
sub slip_close { my $tag = shift; return "</div></$tag></div>"; }
sub stamp {    # 右上に押す丸い印
    my ($txt, $cls) = @_;
    return qq{<span aria-hidden="true" class="absolute right-4 top-4 flex h-11 w-11 rotate-[-10deg] items-center justify-center rounded-full border-2 font-serif text-[13px] font-black leading-none $cls">$txt</span>};
}

sub r_box {
    my ($n, $parent) = @_;
    my ($name, $a, $k) = @$n{qw(name arg kids)};
    local $DARK = ($name eq 'mystery') ? 1 : 0;
    # 用語のポップアップは、物語・公式・確認問題（答えのヒントになる）の中では付けない
    local $CTX{terms} = ($name =~ /^(?:mystery|formula|problem|scene)$/) ? 0 : $CTX{terms};
    my $title = sub {
        my $cls = shift;
        return $a ne '' ? qq{<p class="$cls">} . inl($a) . '</p>' : '';
    };

    if ($name eq 'mystery') {
        return qq{<p class="mb-0 mt-12 inline-flex items-center gap-2.5 bg-gray-900 px-4 py-2 text-[11px] font-bold tracking-[0.3em] text-gray-50"><span aria-hidden="true" class="h-1.5 w-1.5 animate-pulse rounded-full bg-shu"></span>QUESTION ― この章の問い</p><section class="grain-overlay relative mb-10 overflow-hidden bg-gray-900 p-6 text-white sm:p-9">}
             . qq{<div aria-hidden="true" class="pointer-events-none absolute -right-3 -top-10 select-none font-serif text-[10rem] font-black leading-none text-white/5">?</div>}
             . ($a ne '' ? '<h2 class="relative z-10 mb-5 font-serif text-xl font-black leading-snug text-white [word-break:auto-phrase] sm:text-[1.7rem]">' . inl($a) . '</h2>' : '')
             . '<div class="relative z-10">' . inner($k, $name) . '</div></section>';
    }
    if ($name eq 'theory') {    # 定理カード：藍の帯の見出し、薄藍の題字欄、ずらした影
        return qq{<aside class="my-10 border border-blue-700/45 bg-white shadow-[5px_5px_0_0_rgba(47,74,109,.16)]">}
             . qq{<p class="flex items-center gap-2.5 bg-blue-700 px-4 py-2 text-[10px] font-bold tracking-[0.25em] text-white sm:px-6"><span>THEORY</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.15em]">重要理論</span><span aria-hidden="true" class="ml-auto font-serif text-lg font-black leading-none tracking-normal text-white/60">§</span></p>}
             . $title->('border-b border-blue-700/25 bg-blue-50 px-4 py-3.5 font-serif text-lg font-black leading-snug text-blue-950 [word-break:auto-phrase] sm:px-6 sm:text-xl')
             . qq{<div class="px-4 py-5 sm:px-6 sm:py-6">} . inner($k, $name) . '</div></aside>';
    }
    if ($name eq 'danger') {    # 警告票：赤の太枠、上に縞のテープ、左に「！」の札
        return qq{<aside class="my-10 border-2 border-red-700 bg-white">}
             . qq{<span aria-hidden="true" class="block h-2.5" style="background:repeating-linear-gradient(-45deg,#96281C 0 9px,#F6DCD6 9px 18px)"></span>}
             . qq{<div class="flex items-stretch border-b border-red-700/30"><span aria-hidden="true" class="flex w-12 flex-none items-center justify-center bg-red-700 font-serif text-2xl font-black text-white sm:w-14">！</span>}
             . qq{<div class="min-w-0 px-4 py-3"><p class="text-[10px] font-bold tracking-[0.25em] text-red-700">RISK<span aria-hidden="true" class="mx-2 inline-block h-px w-4 bg-red-700/50 align-middle"></span><span class="text-[11px] tracking-[0.15em]">経営の落とし穴</span></p>}
             . $title->('mt-1 font-serif text-lg font-black leading-snug text-red-950 [word-break:auto-phrase] sm:text-xl') . '</div></div>'
             . qq{<div class="bg-red-50/70 px-4 py-5 sm:px-6 sm:py-6">} . inner($k, $name) . '</div></aside>';
    }
    if ($name eq 'cfo') {    # 稟議書：件名の欄と決裁欄のある書式
        my @ch = grep { $_->{t} eq 'box' && $_->{name} eq 'choice' } @$k;
        my $open = sub {
            my ($attrs, $cls) = @_;
            return qq{<section$attrs class="${cls}my-10 border-2 border-gray-900 bg-amber-50">}
                 . qq{<div class="flex items-stretch border-b-2 border-gray-900 bg-white">}
                 . qq{<p class="flex flex-none flex-col justify-center border-r-2 border-gray-900 bg-amber-400 px-3 py-2 text-gray-900"><span class="text-[9px] font-bold tracking-[0.25em]">THINK</span><span class="font-serif text-sm font-black tracking-[0.1em]">考える</span></p>}
                 . qq{<div class="min-w-0 flex-1 px-3 py-2 sm:px-4"><p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[10px] font-bold tracking-[0.2em] text-gray-500"><span>件名<span aria-hidden="true" class="mx-2 inline-block h-px w-4 bg-gray-400 align-middle"></span>考えてみよう</span><span class="border border-gray-500/60 px-1.5 py-px text-[9px] tracking-[0.1em] text-gray-600">試験範囲外</span></p>}
                 . $title->('mt-0.5 font-serif text-base font-black leading-snug text-gray-900 [word-break:auto-phrase] sm:text-lg') . '</div>'
                 . qq{<div aria-hidden="true" class="flex w-14 flex-none flex-col border-l-2 border-gray-900 text-center"><span class="border-b border-gray-900/40 text-[9px] font-bold leading-5 text-gray-600">決裁</span><span class="flex flex-1 items-center justify-center py-1.5"><span class="flex h-8 w-8 rotate-[-12deg] items-center justify-center rounded-full border-2 border-dashed border-shu/60 font-serif text-xs font-black text-shu/70">？</span></span></div>}
                 . qq{</div><p class="flex items-start gap-2.5 border-b border-dashed border-gray-900/30 bg-white/60 px-4 py-2.5 text-xs leading-relaxed text-gray-700 sm:px-6"><span class="mt-px flex-none bg-gray-900 px-2 py-0.5 text-[10px] font-bold tracking-wider text-amber-300">＋α 余力があれば</span><span>試験には出ない発展問題。時間に余裕があるときや2周目に挑戦しよう。飛ばしても、試験対策には影響しない。</span></p>}
                 . qq{<div class="p-4 sm:p-6">};
        };
        if (!@ch) {
            return $open->('', '') . inner($k, $name) . '</div></section>';
        }
        # 選択式：先に自分の判断を選ぶと、その選択へのフィードバックと解説が開く
        my @body = grep { !($_->{t} eq 'box' && ($_->{name} eq 'choice' || $_->{name} eq 'answer')) } @$k;
        my @ans  = grep { $_->{t} eq 'box' && $_->{name} eq 'answer' } @$k;
        my ($opts, $fbs) = ('', '');
        for my $c (@ch) {
            my ($key, $txt) = $c->{arg} =~ /^([A-ZＡ-Ｚ])[\.．:：\s]\s*(.*)$/ ? ($1, $2) : ('?', $c->{arg});
            push @WARN, "[$CUR:$c->{line}] choice の先頭に「A.」のような記号がない" if $key eq '?';
            $opts .= qq{<button type="button" class="kb-opt flex w-full items-stretch border border-gray-900/40 border-b-2 border-b-gray-900/60 bg-white text-left hover:border-gray-900" data-k="$key" aria-pressed="false">}
                   . qq{<span class="flex w-10 flex-none items-center justify-center bg-gray-900 font-serif text-sm font-black text-white">$key</span>}
                   . '<span class="px-3 py-2.5 text-[15px] font-bold leading-snug text-gray-900">' . inl($txt) . '</span></button>';
            $fbs .= qq{<div class="kb-fb mt-3 border border-gray-900/40 border-l-4 border-l-amber-500 bg-white p-4 sm:p-5" data-k="$key">}
                  . qq{<p class="mb-2 text-xs font-bold tracking-wider text-amber-700">「$key」を選んだ場合</p>} . inner($c->{kids}, 'choice') . '</div>';
        }
        $NCHK{think}++ if ($CTX{mode} // '') ne 'all';
        return $open->(' data-think', 'kb-think ')
             . inner(\@body, $name)
             . qq{<p class="mb-2 mt-5 flex items-center gap-3 text-xs font-bold text-gray-700"><span class="flex-none bg-gray-900 px-2 py-1 text-[10px] tracking-[0.2em] text-white">選ぶ</span>あなたならどう考える？　1つ選ぶと、その考え方への講評が開く。</p>}
             . qq{<div class="grid gap-2" role="group" aria-label="選択肢">$opts</div>}
             . $fbs . rn(\@ans, 'cfo')
             . '<span class="hidden !border-amber-500 !bg-amber-100 ring-2 ring-amber-400"></span></div></section>';
    }
    if ($name eq 'choice') {    # cfo の外に置かれた choice（書き方の誤り）
        push @WARN, "[$CUR:$n->{line}] ::choice は ::cfo（考えてみよう）の中でだけ使える";
        return inner($k, $name);
    }
    if ($name eq 'real') {
        return qq{<aside class="relative my-12 border border-t-[3px] border-stone-300 border-t-stone-900 bg-white p-5 shadow-[5px_5px_0_0_rgba(27,36,48,.07)] sm:p-7">}
             . qq{<span aria-hidden="true" class="absolute -top-3.5 left-8 h-6 w-24 -rotate-2 bg-[#B8862F]/35"></span>}
             . qq{<p class="mb-4 flex items-center gap-3 border-b border-stone-900 pb-2 text-[10px] font-bold tracking-[0.25em] text-stone-600"><span>REAL CASE</span><span aria-hidden="true" class="h-px flex-1 bg-stone-300"></span><span class="text-[11px] tracking-[0.15em]">実際にあった話</span></p>}
             . $title->('mb-3 font-serif text-xl font-black leading-snug text-stone-900 [word-break:auto-phrase] sm:text-[1.4rem]')
             . inner($k, $name) . '</aside>';

    }
    if ($name eq 'trap') {    # 赤ペンの添削：例題の最後に置く「間違えやすいポイント」
        return qq{<aside class="relative mt-7 border border-dashed border-shu/60 bg-[#FDF5F1] py-4 pl-5 pr-4 sm:py-5 sm:pl-7 sm:pr-6">}
             . qq{<span aria-hidden="true" class="absolute inset-y-0 left-0 w-1 bg-shu"></span>}
             . qq{<p class="mb-2.5 flex items-center gap-2.5 font-serif text-[15px] font-black leading-none text-shu sm:text-base"><span aria-hidden="true" class="flex h-7 w-7 flex-none rotate-[-8deg] items-center justify-center rounded-full border-2 border-shu text-xs">注</span>間違えやすいポイント</p>}
             . qq{<div class="text-[15px] [&_p]:my-2 [&_p]:leading-[1.85] [&_ul]:my-2">} . inner($k, $name) . '</div></aside>';
    }
    if ($name eq 'answer' && $parent eq 'example') {    # 例題：解答と解説は最初から開いておく
        return qq{<div class="px-4 py-5 sm:px-6 sm:py-6">}
             . inner($k, $name) . '</div>';
    }
    if ($name eq 'answer') {
        my $lab = $a ne '' ? $a : ($parent eq 'cfo' ? '考え方の例を見る' : '解答・解説を見る');
        return qq{<details class="kb-answer group mt-5 border border-gray-900/25 bg-white text-gray-800">}
             . qq{<summary class="flex cursor-pointer select-none items-center justify-between gap-3 px-4 py-3.5 font-bold text-gray-900 transition-colors hover:bg-gray-50"><span class="flex items-center gap-3"><span aria-hidden="true" class="h-3.5 w-[3px] flex-none bg-shu"></span><span>} . inl($lab)
             . qq{</span></span><span aria-hidden="true" class="flex h-6 w-6 flex-none items-center justify-center border border-gray-900/30 text-sm leading-none transition group-open:border-shu group-open:text-shu"><span class="block transition-transform group-open:rotate-45">＋</span></span></summary>}
             . qq{<div class="border-t border-gray-900/15 px-4 py-4 sm:px-5">} . inner($k, $name) . '</div></details>';

    }
    if ($name eq 'exam') {    # 受験票：左に切り取り線つきの半券
        return qq{<aside class="relative my-10 flex border border-emerald-700/45 bg-emerald-50">}
             . qq{<p class="flex w-10 flex-none items-center justify-center border-r-2 border-dashed border-emerald-50 bg-emerald-700 py-4 text-[11px] font-black tracking-[0.3em] text-white [writing-mode:vertical-rl] sm:w-11">試験の急所</p>}
             . qq{<div class="relative min-w-0 flex-1 p-4 sm:p-6">} . ('')
             . label('text-emerald-700', 'EXAM HACK')
             . $title->('mb-3 mt-1 pr-14 font-serif text-lg font-black leading-snug text-emerald-950 [word-break:auto-phrase] sm:text-xl')
             . inner($k, $name) . '</div></aside>';
    }
    if ($name eq 'next') {    # 道しるべ：矢印の札
        return qq{<aside class="my-10 border-t-2 border-violet-600 bg-violet-50/80">}
             . qq{<p class="inline-flex items-center gap-2.5 bg-violet-600 py-1.5 pl-4 pr-8 text-[10px] font-bold tracking-[0.25em] text-white [clip-path:polygon(0_0,calc(100%-14px)_0,100%_50%,calc(100%-14px)_100%,0_100%)] sm:pl-6"><span>NEXT STEP</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.15em]">次の一歩</span></p>}
             . qq{<div class="px-4 pb-5 pt-3 sm:px-6 sm:pb-6 sm:pt-4"><p class="text-[11px] font-bold tracking-[0.1em] text-violet-700">2級・1級・実務へのつながり</p>}
             . $title->('mb-3 mt-1.5 font-serif text-lg font-black leading-snug text-violet-950 [word-break:auto-phrase] sm:text-xl')
             . inner($k, $name) . '</div></aside>';
    }
    if ($name eq 'solve') {
        return qq{<section class="relative my-12 border-2 border-gray-900 bg-white p-6 shadow-[6px_6px_0_0_#1B2430] sm:p-9"><span aria-hidden="true" class="absolute right-4 top-4 rotate-[8deg] border-[3px] border-double border-shu px-2.5 py-0.5 font-serif text-xs font-black tracking-[0.35em] text-shu sm:right-6 sm:top-6 sm:text-sm">解決</span>}
             . label('text-shu', 'ANSWER ― 答え合わせ')
             . $title->('mb-4 pr-16 font-serif text-xl font-black leading-snug text-gray-900 [word-break:auto-phrase] sm:pr-20 sm:text-2xl')
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'scene') {
        return qq{<div class="my-8 border-l-2 border-gray-400 pl-5 font-serif text-gray-700">}
             . label('font-sans text-gray-400', 'SCENE')
             . $title->('mb-2 font-bold text-gray-900')
             . inner($k, $name) . '</div>';
    }
    if ($name eq 'case') {
        return qq{<section class="my-8 overflow-hidden border border-gray-900/20 bg-white">}
             . qq{<div class="flex flex-wrap items-center gap-x-3 gap-y-1 bg-gray-900 px-5 py-3 text-white"><span class="text-[11px] font-bold tracking-[0.3em] text-amber-400">CASE FILE</span><span class="font-bold">} . inl($a) . '</span></div>'
             . qq{<div class="p-5 sm:p-6">} . inner($k, $name) . '</div></section>';
    }
    # 例題・確認問題の枠：表の穴埋めがあるときは、スマホで表が収まるよう余白を詰める
    my $pad = (($name eq 'example' || $name eq 'problem')
               && grep { /\[\[/ } node_texts([ grep { $_->{t} eq 'raw' || ($_->{t} eq 'box' && $_->{name} ne 'answer') } @$k ])) ? 'p-3' : 'p-4';
    if ($name eq 'example') {
        my $isans = sub { $_[0]{t} eq 'box' && $_[0]{name} =~ /^(?:answer|trap)$/ };
        # 設例：解答欄だった表・T字勘定（空欄つき）は、解答に同じものがあるので出さない
        my @pre  = grep { !$isans->($_) && !($_->{t} eq 'raw' && $_->{name} eq 'checks') && ($_->{t} eq 'p' || !(grep { /\[\[/ } node_texts([$_]))) } @$k;
        my @rest = grep { $isans->($_) } @$k;
        local $CTX{reveal} = 1;
        local $CTX{fill}   = { reveal => 1 };
        return qq{<section class="my-10 border border-gray-900/70 bg-white shadow-[5px_5px_0_0_rgba(27,36,48,.08)]">}
             . qq{<p class="flex items-stretch border-b border-gray-900/70"><span class="flex flex-none items-center bg-gray-900 px-3.5 font-serif text-sm font-black tracking-[0.2em] text-white">ケース</span><span class="min-w-0 px-4 py-3 font-bold leading-snug text-gray-900">} . inl($a) . '</span></p>'
             . qq{<div class="border-b border-dashed border-gray-900/30 bg-gray-50/80 px-4 py-4 sm:px-6 sm:py-5"><p class="mb-2 text-[11px] font-bold tracking-[0.2em] text-gray-500">状況</p>}
             . inner(\@pre, $name) . '</div>'
             . rn(\@rest, $name) . '</section>';

    }
    if ($name eq 'problem') {
        $CTX{qn}++;
        my $no = $CTX{qn};
        return qq{<section class="border border-gray-900/25 bg-white">}
             . qq{<p class="flex items-stretch border-b border-gray-900/15"><span class="flex flex-none items-center bg-amber-500 px-3.5 font-serif text-sm font-black tracking-[0.1em] text-white">問$no</span><span class="min-w-0 px-4 py-3 font-bold leading-snug text-gray-900">} . inl($a) . '</span></p>'
             . qq{<div class="$pad sm:p-6">} . with_try($k, $name, $n->{line}) . '</div></section>';

    }
    if ($name eq 'quiz') {
        $CTX{qn} = 0;
        return '<div class="my-8 space-y-5">' . rn($k, $name) . '</div>';
    }
    if ($name eq 'summary') {
        local $CTX{check} = 1;
        return qq{<section class="my-14 border-y-[3px] border-double border-gray-900/70 bg-white/60 p-6 sm:p-8">}
             . label('text-shu', 'SUMMARY')
             . '<p class="mb-4 font-serif text-xl font-black text-gray-900">' . ($a ne '' ? inl($a) : 'この章のまとめ') . '</p>'
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'point') {
        return qq{<aside class="relative my-7 bg-[#FAEFC0] p-4 pb-6 [clip-path:polygon(0_0,100%_0,100%_calc(100%-20px),calc(100%-20px)_100%,0_100%)] sm:p-5 sm:pb-7">}
             . qq{<span aria-hidden="true" class="absolute bottom-0 right-0 h-5 w-5 bg-[#DCC878] [clip-path:polygon(0_0,100%_0,0_100%)]"></span>}
             . label('text-yellow-800', 'POINT')
             . $title->('mb-2 font-bold leading-snug text-gray-900')
             . inner($k, $name) . '</aside>';

    }
    if ($name eq 'formula') {
        my $corner = join '', map { qq{<span aria-hidden="true" class="absolute h-4 w-4 border-blue-700 $_"></span>} }
            'left-0 top-0 border-l-2 border-t-2', 'right-0 top-0 border-r-2 border-t-2', 'bottom-0 left-0 border-b-2 border-l-2', 'bottom-0 right-0 border-b-2 border-r-2';
        return qq{<div class="relative my-10 bg-white px-4 py-7 text-center">$corner}
             . label('text-blue-700', 'FORMULA ― 公式')
             . $title->('mb-2 text-sm font-bold text-gray-500')
             . '<div class="font-serif text-lg font-black leading-relaxed text-gray-900 sm:text-xl [&_p]:my-2">' . inner($k, $name) . '</div></div>';

    }
    if ($name eq 'tgrid') {
        # "::tgrid compact" はスマホでも2列（小さなT字勘定向け）
        my $cls = $a eq 'compact'
            ? 'my-8 grid grid-cols-2 gap-2.5 sm:gap-4 [&>figure]:my-0 [&>figure]:p-2 sm:[&>figure]:p-4 [&_table]:min-w-0 [&_td]:px-1 sm:[&_td]:px-2'
            : 'my-8 grid grid-cols-1 gap-4 sm:grid-cols-2 [&>figure]:my-0';
        return qq{<div class="$cls">} . rn($k, $name) . '</div>';
    }
    if ($name eq 'note') {
        return qq{<div class="my-4 text-sm leading-relaxed text-gray-500 [&_p]:my-1.5 [&_p]:leading-relaxed">} . rn($k, $name) . '</div>';
    }
    die "[$CUR] 未実装のブロック $name\n";
}

# ---------------------------------------------------------------- render: data blocks
sub r_raw {
    my $n = shift;
    my %f = (
        journal  => \&r_journal,
        taccount => \&r_taccount,
        table    => \&r_table,
        boxes    => \&r_boxes,
        steps    => \&r_steps,
        kpi      => \&r_kpi,
        timeline => \&r_timeline,
        toc      => \&r_toc,
        sort     => \&r_sort,
        checks   => \&r_checks,
        sim      => \&r_sim,
        mock     => \&r_mock,
    );
    return $f{ $n->{name} }->($n->{arg}, $n->{lines}, $n->{line});
}

# ---------------------------------------------------------------- render: interactive exercises
# ::sort … ドラッグで分類する問題（"@cats 分類1 | 分類2"、"項目 => 正しい分類"）
# 例題・確認問題の解答に仕訳があれば、仕訳の入力欄を自動で付ける（問題文に <!-- notry --> で無効化）
my %CATSTYLE = (
    '資産'   => ['border-blue-300 bg-blue-50',       'text-blue-700'],
    '負債'   => ['border-rose-300 bg-rose-50',       'text-rose-700'],
    '純資産' => ['border-emerald-300 bg-emerald-50', 'text-emerald-700'],
    '収益'   => ['border-violet-300 bg-violet-50',   'text-violet-700'],
    '費用'   => ['border-amber-300 bg-amber-50',     'text-amber-700'],
);
my $KB_SAFE = '<span class="hidden ring-2 ring-indigo-500 ring-indigo-400 ring-offset-1 !border-emerald-500 !bg-emerald-50 !border-red-500 !bg-red-50 !bg-emerald-100 !bg-red-100 text-emerald-600 text-red-600 text-gray-500 shadow-lg"></span>';
my $KB_CHIP = 'kb-chip touch-none select-none max-w-full border border-gray-900/30 border-b-2 border-b-gray-900/45 bg-white px-2.5 py-1.5 text-left text-sm font-bold leading-snug text-gray-800 transition hover:-translate-y-px hover:border-indigo-500';
my $KB_BTN  = 'px-3.5 py-2 text-sm font-bold tracking-wide transition';

sub hval {
    my ($s, $seed) = @_;
    my $h = ($seed * 2654435761) % 4294967296;
    $h = ($h * 31 + ord($_)) % 4294967296 for split //, $s;
    return $h;
}

sub dshuffle {    # 決定的なシャッフル（ビルドのたびに並びが変わらない）
    my ($seed, @a) = @_;
    return sort { hval($a, $seed) <=> hval($b, $seed) || $a cmp $b } @a;
}

# 演習に付ける属性：所属する大問（見出し）と、解説で参照している章（模擬試験の採点・復習案内に使う）
sub kb_attrs {
    my $a = '';
    $a .= ' data-sec="' . esc($CTX{h2}) . '"' if defined $CTX{h2} && $CTX{h2} ne '';
    $a .= ' data-ch="' . esc($CTX{refch}) . '"' if $CTX{refch};
    return $a;
}

sub kb_buttons {
    return qq{<div class="mt-3 flex flex-wrap items-center gap-2">}
         . qq{<button type="button" class="kb-check $KB_BTN bg-gray-900 text-white hover:bg-shu">答え合わせ</button>}
         . qq{<button type="button" class="kb-reveal $KB_BTN border border-gray-300 bg-white text-gray-700 hover:bg-gray-50">正解を表示</button>}
         . qq{<button type="button" class="kb-reset $KB_BTN text-gray-500 hover:text-gray-800">リセット</button>}
         . qq{<span class="kb-result text-sm font-bold" aria-live="polite"></span></div>};
}

sub r_sort {
    my ($arg, $lines, $ln) = @_;
    my (@cats, @items);
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        if ($l =~ /^\@cats\s+(.*)$/) { @cats = map { trim($_) } split /\|/, $1; next; }
        if ($l =~ /^(.*?\S)\s*=>\s*(\S.*?)\s*$/) { push @items, [$1, $2]; next; }
        push @WARN, "[$CUR:$ln] sort: 解釈できない行「$l」";
    }
    if ($CTX{reveal}) {
        my $h = '';
        for my $c (@cats) {
            my ($box, $lab) = @{ $CATSTYLE{$c} // ['border-slate-300 bg-slate-50', 'text-slate-600'] };
            my @in = grep { $_->[1] eq $c } @items;
            $h .= qq{<div class="border-l-[3px] $box px-3 py-2.5"><p class="mb-1.5 text-xs font-bold $lab">} . inl($c) . '</p><ul class="space-y-1 text-sm leading-snug text-gray-800">'
                . join('', map { '<li class="flex gap-2"><span aria-hidden="true" class="flex-none text-gray-400">・</span><span>' . inl($_->[0]) . '</span></li>' } @in) . '</ul></div>';
        }
        return qq{<div class="my-5 grid gap-2 sm:grid-cols-} . (@cats >= 3 ? 3 : 2) . qq{">$h</div><span class="hidden sm:grid-cols-2 sm:grid-cols-3"></span>};
    }
    my %okcat = map { $_ => 1 } @cats;
    for my $it (@items) {
        push @WARN, "[$CUR:$ln] sort: 分類先にない答え「$it->[1]」" unless $okcat{ $it->[1] };
    }
    $NCHK{sort}++ if ($CTX{mode} // '') ne 'all';
    my %ans = map { $_->[0] => $_->[1] } @items;
    my $i = 0;
    my $chips = join '', map {
        $i++;
        qq{<button type="button" class="$KB_CHIP" data-i="$i" data-ans="} . esc($ans{$_}) . '">' . inl($_) . '</button>';
    } dshuffle($ln, map { $_->[0] } @items);
    my $zones = join '', map {
        my ($box, $lab) = @{ $CATSTYLE{$_} // ['border-slate-300 bg-slate-50', 'text-slate-600'] };
        my $unused = /使わない/ ? ' data-unused="1"' : '';    # 「使わない語句」は採点の対象外
        qq{<div class="kb-zone min-h-[4.5rem] rounded-md border-2 border-dashed $box p-2 transition" data-zone="} . esc($_) . qq{"$unused role="button" tabindex="0">}
          . qq{<p class="mb-1.5 text-xs font-bold $lab">} . inl($_) . '</p><div class="kb-items flex flex-wrap gap-1.5"></div></div>';
    } @cats;
    my $cols = (@cats <= 2 || @cats == 4) ? 'grid-cols-2' : 'grid-cols-2 sm:grid-cols-3';
    return qq{<div class="kb-sort my-5 kb-sheet px-3 pb-3 sm:px-4 sm:pb-4" data-kb="sort"} . kb_attrs() . qq{>$KB_SAFE}
         . qq{<p class="kb-sheet-tab -ml-3 bg-[#2F4A6D] px-3 py-1.5 text-[10px] font-bold leading-none tracking-[0.25em] text-white sm:-ml-4"><span>TRY</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.12em]">ドラッグして分類</span></p>}
         . qq{<p class="mb-3 text-xs leading-relaxed text-gray-600">} . ($arg ne '' ? inl($arg) . '<br>' : '') . 'ドラッグで分類先へ移すか、タップしてから分類先をタップしよう。</p>'
         . qq{<div class="kb-pool flex min-h-[3rem] flex-wrap gap-1.5 rounded-md border-2 border-dashed border-indigo-200 bg-white p-2" data-zone="pool" role="button" tabindex="0">$chips</div>}
         . qq{<div class="mt-3 grid $cols gap-2">$zones</div>}
         . kb_buttons() . '</div>';
}

# 仕訳の入力欄に並べる「まぎらわしい選択肢」
my @CONF = (
    [qw(現金 当座預金 普通預金 小口現金 定期預金)],
    [qw(売掛金 未収入金 クレジット売掛金 受取手形 電子記録債権 受取商品券)],
    [qw(買掛金 未払金 支払手形 電子記録債務)],
    [qw(前払金 前払費用 仮払金 立替金)],
    [qw(前受金 前受収益 仮受金 預り金)],
    [qw(貸付金 手形貸付金 役員貸付金 従業員貸付金)],
    [qw(借入金 手形借入金 役員借入金 当座借越)],
    [qw(仕入 売上原価 繰越商品 発送費)],
    [qw(売上 受取手数料 雑益 償却債権取立益)],
    [qw(支払手数料 支払利息 雑損 雑費)],
    [qw(租税公課 仮払法人税等 未払法人税等 通信費)],
    [qw(給料 法定福利費 所得税預り金 社会保険料預り金 住民税預り金 従業員預り金)],
    [qw(減価償却費 減価償却累計額 固定資産売却損 固定資産売却益 修繕費)],
    [qw(備品 建物 車両運搬具 土地)],
    [qw(貸倒損失 貸倒引当金 貸倒引当金繰入 貸倒引当金戻入)],
    [qw(仮受消費税 仮払消費税 未払消費税)],
    [qw(資本金 繰越利益剰余金 利益準備金 未払配当金)],
    [qw(旅費交通費 消耗品費 通信費 雑費)],
    [qw(支払家賃 支払地代 保険料 修繕費)],
    [qw(受取家賃 受取地代 受取利息)],
);
my @DEFPOOL = qw(現金 普通預金 売掛金 買掛金 未払金 仮払金 仮受金 雑損 支払手数料 雑益);

sub distractors {
    my ($seed, $n, @ans) = @_;
    my %a = map { $_ => 1 } @ans;
    my %cand;
    for my $acc (@ans) {
        for my $g (@CONF) {
            next unless grep { index($acc, $_) >= 0 } @$g;
            $cand{$_} = 1 for grep { !$a{$_} } @$g;
        }
    }
    my @pick = dshuffle($seed, keys %cand);
    @pick = @pick[0 .. $n - 1] if @pick > $n;
    for my $d (dshuffle($seed + 1, @DEFPOOL)) {
        last if @pick >= $n;
        push @pick, $d unless $a{$d} || grep { $_ eq $d } @pick;
    }
    return @pick;
}

sub jlabel {    # 仕訳の見出しのうち、答えのヒントにならない部分だけを使う
    my ($cap, $i) = @_;
    return $1 if trim($cap // '') =~ /^【(.+?)】/;    # 【…】で明示した見出しを優先する（答えのヒントにならない語だけを書く）
    my ($f) = split /[\s：:（、。]/, trim($cap // '');
    $f //= '';
    return $f if $f =~ /^(?:\(\d+\)|[①-⑳]|\d+\.|\d+月\d+日|翌期\d+月\d+日|期首|期中|期末|決算日|翌期首|.{1,5}時)$/;
    return "仕訳$i";
}

sub jr_widget {
    my ($kids, $seed) = @_;
    return '' if grep { $_->{t} eq 'html' && $_->{text} =~ /notry/ } @$kids;
    my @js;
    for my $ans (grep { $_->{t} eq 'box' && $_->{name} eq 'answer' } @$kids) {
        for my $jn (grep { $_->{t} eq 'raw' && $_->{name} eq 'journal' } @{ $ans->{kids} }) {
            my (@d, @c);
            my $bad = 0;
            for my $l (@{ $jn->{lines} }) {
                next if $l =~ /^\s*$/;
                if ($l !~ /\|/) { $bad = 1; last; }
                my ($L, $R) = split /\s*\|\s*/, $l, 2;
                for my $pair ([[side($L)], \@d], [[side($R // '')], \@c]) {
                    my ($e, $arr) = @$pair;
                    next if $e->[0] eq '' && $e->[1] eq '';
                    my $v = amt($e->[1]);
                    if ($e->[0] eq '' || !defined $v) { $bad = 1; next; }
                    push @$arr, [$e->[0], 0 + $v];
                }
            }
            next if $bad || !@d || !@c;
            push @js, { l => jlabel($jn->{arg}, scalar(@js) + 1), a => $jn->{arg}, d => \@d, c => \@c };
        }
    }
    # 同じ番号の仕訳が複数ある（例：(1) おかわり堂 と (1) 洛北ミート）ときは、番号の後ろの
    # 当事者の名前（「（」や空白の前まで）を見出しに足して区別する。
    # 答えのヒントにならないよう、問題文にも出てくる語（会社名など）に限る
    my $qtext = join ' ', map {
          $_->{t} eq 'p'  ? $_->{text}
        : $_->{t} eq 'ul' ? (map { $_->[1] } @{ $_->{items} })
        : $_->{t} eq 'ol' ? @{ $_->{items} }
        : ()
    } @$kids;
    my %nlab;
    $nlab{ $_->{l} }++ for @js;
    for my $j (@js) {
        next unless $nlab{ $j->{l} } > 1;
        my $rest = trim($j->{a} // '');
        $rest =~ s/^\Q$j->{l}\E\s*//;
        my ($who) = split /[\s：:（、。]/, $rest;
        $j->{l} .= " $who" if defined $who && $who ne '' && length($who) <= 12 && index($qtext, $who) >= 0;
    }
    return '' if !@js || @js > 8;
    $NCHK{try}++ if ($CTX{mode} // '') ne 'all';
    my (%seen, @acc);
    for my $j (@js) {
        for my $e (@{ $j->{d} }, @{ $j->{c} }) { push @acc, $e->[0] unless $seen{ $e->[0] }++; }
    }
    my $nd   = @acc <= 2 ? 5 : @acc <= 4 ? 4 : 3;
    my $chips = join '', map { qq{<button type="button" class="$KB_CHIP" data-acct="} . esc($_) . '">' . esc($_) . '</button>' }
                dshuffle($seed, @acc, distractors($seed, $nd, @acc));
    my ($entries, $k) = ('', 0);
    for my $j (@js) {
        my $rows = (@{ $j->{d} } > @{ $j->{c} } ? scalar @{ $j->{d} } : scalar @{ $j->{c} }) + 1;
        $rows = 2 if $rows < 2;
        $rows = 5 if $rows > 5;
        my $col = sub {
            my ($s, $label, $cls) = @_;
            my $h = qq{<div><p class="mb-1 text-[11px] font-bold $cls">$label</p>};
            $h .= qq{<div class="kb-row mb-1 flex items-stretch gap-1.5" data-side="$s">}
                . qq{<button type="button" class="kb-slot min-w-0 flex-1 truncate rounded border border-dashed border-gray-300 bg-gray-50 px-2 py-1.5 text-left text-sm text-gray-400" data-acct="">勘定科目</button>}
                . qq{<input type="text" inputmode="numeric" autocomplete="off" aria-label="${label}の金額" placeholder="金額" class="kb-amt w-28 flex-none rounded border border-gray-300 bg-white px-2 py-1.5 text-right text-base tabular-nums sm:text-sm">}
                . '</div>' for 1 .. $rows;
            return $h . '</div>';
        };
        $entries .= qq{<div class="kb-entry mt-3 rounded-md border border-gray-200 bg-white p-2.5" data-j="$k">}
                  . qq{<div class="mb-1.5 flex items-center justify-between gap-2"><span class="text-xs font-bold text-gray-500">} . esc($j->{l}) . qq{</span><span class="kb-jres text-xs font-bold"></span></div>}
                  . qq{<div class="grid grid-cols-1 gap-2 sm:grid-cols-2">} . $col->('d', '借方', 'text-blue-700') . $col->('c', '貸方', 'text-rose-700') . '</div></div>';
        $k++;
    }
    my $data = esc(JSON::PP->new->canonical(1)->encode([ map { { d => $_->{d}, c => $_->{c} } } @js ]));
    return qq{<div class="kb-jr my-5 kb-sheet px-3 pb-3 sm:px-4 sm:pb-4" data-kb="journal" data-answer="$data"} . kb_attrs() . qq{>$KB_SAFE}
         . qq{<p class="kb-sheet-tab -ml-3 bg-[#2F4A6D] px-3 py-1.5 text-[10px] font-bold leading-none tracking-[0.25em] text-white sm:-ml-4"><span>TRY</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.12em]">仕訳を入力して答え合わせ</span></p>}
         . qq{<p class="mb-2 text-xs leading-relaxed text-gray-600">勘定科目をドラッグで記入欄へ（またはタップしてから記入欄をタップ）。金額も入力しよう。記入済みの欄をタップすると消せる。</p>}
         . qq{<div class="kb-pool flex flex-wrap gap-1.5" data-zone="pool">$chips</div>}
         . $entries . kb_buttons() . '</div>';
}

sub node_texts {    # ノード列に含まれる文字列をすべて集める（空欄・参照章の抽出用）
    my ($nodes) = @_;
    my @t;
    for my $n (@$nodes) {
        my $t = $n->{t};
        if    ($t eq 'p' || $t eq 'h') { push @t, $n->{text}; }
        elsif ($t eq 'ul')    { push @t, map { $_->[1] } @{ $n->{items} }; }
        elsif ($t eq 'ol')    { push @t, @{ $n->{items} }; }
        elsif ($t eq 'quote') { push @t, @{ $n->{lines} }; }
        elsif ($t eq 'raw')   { push @t, $n->{arg}, @{ $n->{lines} }; }
        elsif ($t eq 'box')   { push @t, $n->{arg}, node_texts($n->{kids}); }
    }
    return @t;
}

sub refch {    # 解説の「（第5・9・14章）」から、参照している章のIDを取り出す
    my %seen;
    my @ids;
    for my $s (node_texts(shift)) {
        while ($s =~ /第(\d+(?:・\d+)*)章/g) {
            for my $num (split /・/, $1) {
                my $id = sprintf('ch%02d', $num);
                push @ids, $id if $META{$id} && !$seen{$id}++;
            }
        }
    }
    return join ' ', @ids;
}

# ---- 穴埋め：問題文に [[答え]] / [[ア:答え]] を書くと入力欄になる
#   数値の答え → 金額の入力欄、文字の答え → 選択式（選択肢は同じ問題の答え＋「<!-- choices: A | B -->」）
#   [[]] は「何も書かないのが正解」の欄（精算表・試算表で、記入する場所そのものを問う）
#   同じラベルの空欄は、1か所に入力すると他の同じラベルの欄にも反映される
my $KB_BLANK = 'kb-blank rounded border border-indigo-300 bg-white px-1.5 py-0.5 text-base font-bold text-gray-900 shadow-inner focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200';
my $KB_PICK  = 'kb-blank kb-pick inline-flex max-w-full items-center whitespace-nowrap rounded border border-indigo-300 bg-white px-1.5 py-1 font-bold leading-tight text-gray-900 shadow-inner hover:border-indigo-500 focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200';

sub fill_setup {
    my ($pre, $seed) = @_;
    my @bl;
    for my $s (node_texts($pre)) {
        while ($s =~ /$BLANK_RE/g) { push @bl, trim($2); }
    }
    return undef unless @bl;
    my @choices;
    for my $n (@$pre) {
        next unless $n->{t} eq 'html' && $n->{text} =~ /<!--\s*choices:\s*(.*?)\s*-->/;
        push @choices, map { trim($_) } split /\|/, $1;
    }
    my (%o, @opt);
    my $w = 0;
    for my $a (@bl) {
        next if $a eq '';
        if (is_num($a)) { my $e = blank_em($a); $w = $e if $e > $w; next; }
        push @opt, $a unless $o{$a}++;
    }
    push @opt, grep { !$o{$_}++ } @choices;
    return { opts => [dshuffle($seed, @opt)], w => ($w || blank_em('1,000,000')) };
}

sub blank_em {    # 数値の入力欄の幅（em）：太字の数字は約0.56em、カンマ・小数点は約0.32em、余白と枠で約1em
    my $a = shift // '';
    my $d = () = $a =~ /\d/g;
    my $o = () = $a =~ /[,.]/g;
    my $em = 0.56 * $d + 0.32 * $o + 1.05;
    return $em < 2.8 ? 2.8 : $em;
}

sub blank_html {    # inl() から呼ばれる（$lab・$ans はエスケープ済みの文字列。$ch は「15・18」のような復習する章）
    my ($lab, $ans, $ch) = @_;
    $lab //= '';
    $ans = trim($ans // '');
    my $f = $CTX{fill};
    return '<span class="font-bold text-gray-400">？</span>' if $f && $f->{reveal};
    if (!$f) {
        push @WARN, "[$CUR] 空欄 [[$ans]] は、例題・確認問題の問題文の中でだけ使える";
        return $ans;
    }
    my $la   = $lab ne '' ? qq{ data-label="$lab"} : '';
    my $aria = '空欄' . ($lab ne '' ? "（$lab）" : '');
    if (defined $ch && $ch ne '') {
        my @ids = map { sprintf('ch%02d', $_) } grep { /^\d+$/ } split /・/, $ch;
        push @WARN, "[$CUR] 空欄 [[$ans\@$ch]] の章が存在しない" if grep { !$META{$_} } @ids;
        $la .= ' data-ch="' . join(' ', @ids) . '"';
    }
    if ($ans eq '' || is_num($ans)) {
        my $v   = $ans eq '' ? '' : amt($ans);
        my $em = sprintf('%.2f', $CTX{bw} || $f->{w});    # 幅は表の列ごと（なければ問題ごと）の最大にそろえる
        return qq{<input type="text" inputmode="decimal" autocomplete="off" spellcheck="false" class="$KB_BLANK text-right tabular-nums" style="width:${em}em" data-ans="$v"$la placeholder="$lab" aria-label="$aria">};
    }
    # 文字の答え：押すと選択肢の一覧が開くボタン（標準のセレクトは最長の選択肢の幅になり、表からはみ出すため）
    return qq{<button type="button" class="$KB_PICK" data-ans="$ans"$la data-value="" aria-haspopup="listbox" aria-expanded="false" aria-label="$aria">}
         . qq{<span class="kb-pv text-indigo-300">} . ($lab ne '' ? $lab : '選択') . qq{</span><span aria-hidden="true" class="ml-1 text-[9px] text-indigo-400">▼</span></button>};
}

sub fill_footer {
    return qq{<div class="kb-sheet mt-5 px-3 pb-3 sm:px-4">}
         . qq{<p class="kb-sheet-tab -ml-3 bg-[#2F4A6D] px-3 py-1.5 text-[10px] font-bold leading-none tracking-[0.25em] text-white sm:-ml-4"><span>TRY</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.12em]">空欄を埋めて答え合わせ</span></p>}
         . kb_buttons()
         . qq{<span class="hidden absolute z-50 max-h-[50vh] w-max min-w-[9rem] max-w-[calc(100vw-1.5rem)] overflow-y-auto rounded-lg border border-gray-200 bg-white p-1 shadow-xl block w-full rounded-md px-3 py-2.5 text-left text-[15px] text-sm font-bold text-gray-800 text-gray-400 hover:bg-indigo-50 focus:bg-indigo-50 focus:outline-none bg-indigo-50 text-indigo-700 text-indigo-300"></span>}
         . '</div>';
}

sub with_try {    # 問題文（空欄があれば入力式）→ 仕訳の入力欄 → 解答（折りたたみ）の順に並べる
    my ($k, $name, $seed) = @_;
    my @pre = grep { !($_->{t} eq 'box' && $_->{name} eq 'answer') } @$k;
    my @ans = grep { $_->{t} eq 'box' && $_->{name} eq 'answer' } @$k;
    local $CTX{refch} = refch(\@ans);
    my $jw = jr_widget($k, $seed);
    my $fs = fill_setup(\@pre, $seed);
    return inner($k, $name) if !$fs && $jw eq '';
    my $body;
    if ($fs) {
        local $CTX{fill} = $fs;
        $NCHK{fill}++ if ($CTX{mode} // '') ne 'all';
        my $opts = esc(JSON::PP->new->encode($fs->{opts}));
        $body = qq{<div class="kb-fill" data-kb="fill" data-opts="$opts"} . kb_attrs() . qq{>$KB_SAFE<div class="[&>*:first-child]:mt-0">} . rn(\@pre, $name) . '</div>' . fill_footer() . '</div>';
    }
    else {
        $body = rn(\@pre, $name);
    }
    return '<div class="[&>*:first-child]:mt-0 [&>*:last-child]:mb-0">' . $body . $jw . rn(\@ans, $name) . '</div>';
}

# ---- 補助簿の選択など、「当てはまる欄にチェック」する表
#   1行目が見出し（左上 | 列1 | 列2 …）、2行目以降は「行の名前 | 正解なら✓ | …」
sub r_checks {
    my ($arg, $lines, $ln) = @_;
    my (@head, @rows);
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        my @c = cells($l);
        if (!@head) { @head = @c; next; }
        push @WARN, "[$CUR:$ln] checks: 列数が見出しと一致しない「$l」" if @c != @head;
        push @rows, \@c;
    }
    $NCHK{checks}++ if ($CTX{mode} // '') ne 'all';
    my $thc = 'bg-gray-800 px-1.5 py-2 text-xs font-bold text-white';
    my $th  = join '', map { qq{<th scope="col" class="$thc whitespace-nowrap border-l border-gray-600 text-center">} . inl($head[$_]) . '</th>' } 1 .. $#head;
    my $body = '';
    for my $r (@rows) {
        $body .= '<tr class="even:bg-slate-50"><th scope="row" class="border-t border-gray-200 px-3 py-1 text-left text-sm font-bold leading-snug text-gray-800">' . inl($r->[0]) . '</th>';
        for my $j (1 .. $#head) {
            my $want = (($r->[$j] // '') =~ /\S/) ? 1 : 0;
            my $al = esc("$r->[0]（$head[$j]）");
            $body .= qq{<td class="kb-cell border-l border-t border-gray-200 p-0 text-center"><label class="flex h-11 min-w-[2.75rem] cursor-pointer items-center justify-center">}
                   . qq{<input type="checkbox" class="kb-ck h-5 w-5 cursor-pointer accent-indigo-600" data-col="$j" data-ans="$want" aria-label="$al"></label></td>};
        }
        $body .= '</tr>';
    }
    my $foot = '<tr><td class="border-t-2 border-gray-300 px-3 py-1.5 text-[11px] font-bold text-gray-400">判定</td>'
             . join('', map { qq{<td class="kb-colres border-l border-t-2 border-gray-200 border-t-gray-300 py-1.5 text-center text-sm font-black" data-col="$_"></td>} } 1 .. $#head) . '</tr>';
    return qq{<div class="kb-checks my-5 kb-sheet px-3 pb-3 sm:px-4 sm:pb-4" data-kb="checks"} . kb_attrs() . qq{>$KB_SAFE}
         . qq{<p class="kb-sheet-tab -ml-3 bg-[#2F4A6D] px-3 py-1.5 text-[10px] font-bold leading-none tracking-[0.25em] text-white sm:-ml-4"><span>TRY</span><span aria-hidden="true" class="h-px w-4 bg-white/50"></span><span class="text-[11px] tracking-[0.12em]">チェックして答え合わせ</span></p>}
         . qq{<p class="mb-3 text-xs leading-relaxed text-gray-600">} . ($arg ne '' ? inl($arg) : '当てはまる欄をすべてチェックしよう。') . '</p>'
         . qq{<div class="overflow-x-auto rounded-md border border-gray-300 bg-white"><table class="w-full border-collapse"><thead><tr><th scope="col" class="$thc text-left">} . inl($head[0] // '') . qq{</th>$th</tr></thead><tbody>$body</tbody><tfoot>$foot</tfoot></table></div>}
         . kb_buttons() . '</div>';
}

# ---- シミュレーター（::sim 種類 タイトル ／ "@expect キー=値" は自己テストで照合する本文の数値）
my %SIMCOL = (blue => '#2a78d6', orange => '#eb6834', aqua => '#1baf7a', ink => '#52514e');    # 色覚の検証済み（dataviz の参照パレット）

sub sim_range {
    my ($key, $label, $min, $max, $step, $val, $unit) = @_;
    return qq{<label class="block"><span class="flex items-baseline justify-between gap-2 text-sm"><span class="font-bold leading-snug text-gray-700">$label</span>}
         . qq{<span class="flex-none font-black tabular-nums text-gray-900"><output data-show="$key">$val</output><span class="ml-0.5 text-xs font-bold text-gray-500">$unit</span></span></span>}
         . qq{<input type="range" data-in="$key" min="$min" max="$max" step="$step" value="$val" class="mt-1.5 w-full cursor-pointer accent-teal-600"></label>};
}

sub sim_field {    # 数値の入力欄・選択欄
    my ($key, $label, $ctl) = @_;
    return qq{<label class="block text-sm"><span class="mb-1 block font-bold leading-snug text-gray-700">$label</span>$ctl</label>};
}

sub sim_select {
    my ($key, $val, @opts) = @_;    # @opts: [値, 表示]
    return qq{<select data-in="$key" class="w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-base">}
         . join('', map { qq{<option value="$_->[0]"} . ($_->[0] eq $val ? ' selected' : '') . ">$_->[1]</option>" } @opts) . '</select>';
}

sub sim_text {
    my ($key, $val, $unit) = @_;
    return qq{<span class="flex items-center gap-1.5"><input type="text" inputmode="decimal" data-in="$key" value="$val" autocomplete="off" class="w-full min-w-0 rounded border border-gray-300 bg-white px-2 py-1.5 text-right text-base tabular-nums"><span class="flex-none text-xs font-bold text-gray-500">$unit</span></span>};
}

sub sim_legend {
    return '<div class="flex flex-wrap gap-x-4 gap-y-1 text-xs font-bold text-gray-600">'
         . join('', map { qq{<span class="flex items-center gap-1.5"><span class="inline-block h-2.5 w-2.5 rounded-sm" style="background:$SIMCOL{$_->[0]}"></span>$_->[1]</span>} } @_) . '</div>';
}

my $SIM_TD  = 'border-t border-gray-200 px-2 py-1.5 text-right tabular-nums text-gray-900';
my $SIM_TH  = 'border-t border-gray-200 px-2 py-1.5 text-left font-bold text-gray-700';
my $SIM_HD  = 'bg-gray-800 px-2 py-1.5 text-xs font-bold text-white';
my $SIM_TIP = '<div class="kb-tip pointer-events-none absolute z-10 hidden whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-xs font-bold text-white shadow-lg"></div>';

sub sim_fifo {    # 第6章：仕入値の動きと、先入先出法・移動平均法の利益
    my $rows = join '', map {
        my ($lab, $k, $em) = @$_;
        my $tr = $em ? ' class="bg-amber-50 font-bold"' : '';
        qq{<tr$tr><th scope="row" class="$SIM_TH">$lab</th><td class="$SIM_TD" data-out="fifo.$k"></td><td class="$SIM_TD" data-out="avg.$k"></td><td class="$SIM_TD text-gray-600" data-out="diff.$k"></td></tr>};
    } (['売上高', 'sales'], ['売上原価', 'cogs'], ['売上総利益', 'gp', 1], ['月末在庫', 'end'], ['売上原価＋月末在庫', 'total']);
    my $bar = sub {
        my ($m, $lab) = @_;
        return qq{<div class="mt-3 first:mt-0"><p class="mb-1 text-xs font-bold text-gray-700">$lab</p><div class="flex h-7 w-full gap-[2px]">}
             . qq{<div class="flex min-w-0 items-center overflow-visible rounded-[4px] px-2 text-xs font-bold text-white transition-all" style="background:$SIMCOL{orange}" data-seg="$m.cogs" tabindex="0"></div>}
             . qq{<div class="flex min-w-0 items-center rounded-[4px] px-2 text-xs font-bold text-white transition-all" style="background:$SIMCOL{blue}" data-seg="$m.end" tabindex="0"></div></div></div>};
    };
    return qq{<p class="mb-3 text-xs leading-relaxed text-gray-600">本章の10月の取引（月初在庫200kg、仕入れ300kg×2回、販売400kg・250kg、売価は1kgあたり1,800円）はそのままに、仕入値の動きだけを変えてみよう。</p>}
         . qq{<div class="rounded-md border border-gray-200 bg-white p-3">} . sim_range('d', '仕入れ1回ごとの値動き（1kgあたり）', -300, 300, 50, 200, '円')
         . qq{<p class="mt-2 text-xs leading-relaxed text-gray-500" data-out="prices"></p></div>}
         . qq{<div class="mt-3 overflow-x-auto rounded-md border border-gray-200 bg-white"><table class="w-full min-w-[20rem] border-collapse text-sm"><thead><tr><th class="$SIM_HD text-left">単位：円</th><th class="$SIM_HD text-right">先入先出法</th><th class="$SIM_HD text-right">移動平均法</th><th class="$SIM_HD text-right">差</th></tr></thead><tbody>$rows</tbody></table></div>}
         . qq{<div class="kb-chart relative mt-3 rounded-md border border-gray-200 bg-white p-3">$SIM_TIP<p class="mb-2 text-xs font-bold text-gray-500">売ることができた肉の原価（月初在庫＋仕入れ）の切り分け</p>}
         . $bar->('fifo', '先入先出法') . $bar->('avg', '移動平均法')
         . '<div class="mt-3">' . sim_legend([orange => '売上原価（売れた分）'], [blue => '月末在庫（残った分）']) . '</div></div>'
         . qq{<p class="mt-3 text-sm leading-relaxed text-gray-800" data-out="msg"></p>};
}

sub sim_ccc {    # 第7章：CCCと運転資金
    my $inputs = '<div class="grid gap-4 sm:grid-cols-2">'
        . sim_range('sales', '月商', 1000, 30000, 500, 15000, '万円')
        . sim_range('cr', '原価率（売上に占める仕入の割合）', 50, 95, 1, 80, '%')
        . sim_range('rec', '売掛金の回収日数（売ってから入金まで）', 0, 120, 1, 45, '日')
        . sim_range('inv', '在庫の保有日数（仕入れてから売るまで）', 0, 60, 1, 10, '日')
        . sim_range('pay', '買掛金の支払日数（仕入れてから支払いまで）', 0, 120, 1, 20, '日')
        . sim_range('g', '来期の売上の伸び', 0, 100, 5, 50, '%')
        . '</div>';
    my $kpi = sub {
        my ($lab, $k, $unit) = @_;
        return qq{<div class="rounded-lg border border-gray-200 bg-white p-3"><p class="text-[11px] font-bold leading-snug text-gray-500">$lab</p><p class="mt-1 text-xl font-black leading-tight text-gray-900"><span data-out="$k"></span><span class="ml-0.5 text-xs font-bold text-gray-500">$unit</span></p></div>};
    };
    my $rows = join '', map {
        my ($lab, $k, $note, $em) = @$_;
        my $tr = $em ? ' class="bg-amber-50 font-bold"' : '';
        qq{<tr$tr><th scope="row" class="$SIM_TH">$lab<span class="block text-[11px] font-normal text-gray-500">$note</span></th><td class="$SIM_TD align-top" data-out="$k"></td></tr>};
    } (['売掛金', 'ar', '月商×回収日数÷30'], ['在庫', 'stock', '月商×原価率×保有日数÷30'], ['買掛金（差し引く）', 'ap', '月商×原価率×支払日数÷30'], ['運転資金（立て替えているお金）', 'wc', '売掛金＋在庫－買掛金', 1]);
    my $lane = sub {
        my ($lab, $inner) = @_;
        return qq{<div class="flex items-center gap-2"><p class="w-[4.5rem] flex-none text-[11px] font-bold leading-tight text-gray-600">$lab</p><div class="relative h-6 flex-1">$inner</div></div>};
    };
    my $seg = sub {
        my ($k, $col) = @_;
        return qq{<div class="absolute inset-y-0 rounded-[4px] transition-all" style="background:$SIMCOL{$col}" data-seg="$k" tabindex="0"></div>};
    };
    return qq{<p class="mb-3 text-xs leading-relaxed text-gray-600">初期値は洛北ミートの現在の数字（月商1億5,000万円、回収45日・在庫10日・支払20日、原価率80%）。1か月＝30日として計算する。</p>}
         . qq{<div class="rounded-md border border-gray-200 bg-white p-3">$inputs</div>}
         . '<div class="mt-3 grid grid-cols-2 gap-2.5 sm:grid-cols-3">' . $kpi->('CCC（立て替えている日数）', 'ccc', '日') . $kpi->('運転資金', 'wc2', '万円') . '<div class="col-span-2 sm:col-span-1">' . $kpi->('売上が伸びると増える運転資金', 'grow', '万円') . '</div></div>'
         . qq{<div class="kb-chart relative mt-3 rounded-md border border-gray-200 bg-white p-3">$SIM_TIP<p class="mb-3 text-xs font-bold text-gray-500">仕入れた日を0日目とした、お金の出入り</p><div class="space-y-2">}
         . $lane->('仕入→販売→入金', $seg->('stock', 'aqua') . $seg->('ar', 'blue'))
         . $lane->('仕入→支払', $seg->('ap', 'orange'))
         . $lane->('立て替え', $seg->('gap', 'ink'))
         . qq{</div><div class="relative ml-[5rem] mt-1 h-4 border-t border-[#c3c2b7] text-[10px] tabular-nums text-[#898781]" data-out="axis"></div>}
         . '<div class="mt-2">' . sim_legend([aqua => '在庫'], [blue => '売掛金'], [orange => '買掛金'], [ink => '立て替え期間（CCC）']) . '</div></div>'
         . qq{<div class="mt-3 overflow-x-auto rounded-md border border-gray-200 bg-white"><table class="w-full border-collapse text-sm"><thead><tr><th class="$SIM_HD text-left">内訳</th><th class="$SIM_HD text-right">金額（万円）</th></tr></thead><tbody>$rows</tbody></table></div>}
         . qq{<p class="mt-3 text-sm leading-relaxed text-gray-800" data-out="msg"></p>}
         . qq{<span class="hidden absolute top-0.5 -translate-x-1/2 whitespace-nowrap"></span>};
}

sub sim_dep {    # 第12章：定額法と定率法
    my $years = sim_select('n', '5', map { [$_, "${_}年"] } 2 .. 10);
    my $months = sim_select('m', '12', map { [$_, "${_}か月"] } reverse 1 .. 12);
    my $inputs = '<div class="grid grid-cols-2 gap-3 sm:grid-cols-3">'
        . '<div class="col-span-2 sm:col-span-1">' . sim_field('cost', '取得原価', sim_text('cost', '1,000,000', '円')) . '</div>'
        . sim_field('n', '耐用年数', $years)
        . sim_field('m', '1年目の使用月数', $months)
        . sim_field('res', '残存価額（定額法）', sim_select('res', '0', ['0', 'ゼロ'], ['10', '取得原価の10%']))
        . sim_field('rate', '償却率（定率法）', sim_text('rate', '40', '%'))
        . '</div><p class="mt-2 text-[11px] leading-relaxed text-gray-500">償却率は、耐用年数を変えると「1÷耐用年数×2」（200%定率法の考え方）に自動で合わせる。問題で指示された率に書き換えてもよい。</p>';
    return qq{<p class="mb-3 text-xs leading-relaxed text-gray-600">初期値は本章のトレッドミル（取得原価1,000,000円・償却率40%）。耐用年数5年・残存価額ゼロの定額法と比べてみよう。</p>}
         . qq{<div class="rounded-md border border-gray-200 bg-white p-3">$inputs</div>}
         . qq{<div class="kb-chart relative mt-3 rounded-md border border-gray-200 bg-white p-3">$SIM_TIP<div class="mb-2 flex flex-wrap items-baseline justify-between gap-2"><p class="text-xs font-bold text-gray-500">各年の減価償却費</p>} . sim_legend([blue => '定額法'], [orange => '定率法']) . '</div>'
         . qq{<div class="relative h-44" data-out="chart"></div><div class="relative mt-1 h-4 text-[10px] tabular-nums text-[#898781]" data-out="xaxis"></div></div>}
         . qq{<div class="mt-3 overflow-x-auto rounded-md border border-gray-200 bg-white"><table class="w-full border-collapse text-xs sm:text-sm"><thead><tr><th rowspan="2" class="$SIM_HD text-left align-bottom">年</th><th colspan="2" class="$SIM_HD border-l border-gray-600 text-center">定額法</th><th colspan="2" class="$SIM_HD border-l border-gray-600 text-center">定率法</th></tr>}
         . qq{<tr><th class="$SIM_HD border-l border-gray-600 text-right">償却費</th><th class="$SIM_HD text-right">期末の帳簿価額</th><th class="$SIM_HD border-l border-gray-600 text-right">償却費</th><th class="$SIM_HD text-right">期末の帳簿価額</th></tr></thead><tbody data-out="rows"></tbody></table></div>}
         . qq{<p class="mt-3 text-sm leading-relaxed text-gray-800" data-out="msg"></p>}
         . qq{<span class="hidden $SIM_TD $SIM_TH bg-amber-50 font-bold border-l text-gray-600 px-1.5 sm:px-2 whitespace-nowrap"></span>};
}

sub r_sim {
    my ($arg, $lines, $ln) = @_;
    my ($type, $title) = $arg =~ /^(\w+)\s*(.*)$/ ? ($1, $2) : ('', '');
    my %exp;
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        if ($l =~ /^\@expect\s+(.*)$/) {
            for my $kv (split /\s+/, $1) {
                my ($k, $v) = split /=/, $kv, 2;
                $exp{$k} = 0 + $v;
            }
            next;
        }
        push @WARN, "[$CUR:$ln] sim: 解釈できない行「$l」";
    }
    my %R = (fifo => \&sim_fifo, ccc => \&sim_ccc, dep => \&sim_dep);
    if (!$R{$type}) { push @WARN, "[$CUR:$ln] sim: 不明な種類「$type」"; return ''; }
    push @WARN, "[$CUR:$ln] sim: \@expect がない（本文の数値との照合ができない）" unless %exp;
    $NCHK{sim}++ if ($CTX{mode} // '') ne 'all';
    my $ex = esc(JSON::PP->new->canonical(1)->encode(\%exp));
    return qq{<figure class="kb-sim my-8 rounded-lg border border-teal-200 bg-teal-50/50 p-4 sm:p-5" data-sim="$type" data-expect="$ex">}
         . qq{<p class="mb-1 text-[11px] font-bold tracking-[0.25em] text-teal-700">SIMULATOR ― 数字を動かしてみよう</p>}
         . ($title ne '' ? '<p class="mb-3 font-bold leading-snug text-gray-900">' . inl($title) . '</p>' : '')
         . $R{$type}->() . '</figure>';
}

# ---- 模擬試験モード（::mock 制限時間（分） ／ "大問の見出し | 配点"）
#   見出し（##）がその文字列で始まる大問の演習を、まとめて採点する。
#   大問の得点＝配点×正解した設問の数÷設問の数（仕訳は1問、空欄は1つ（同じラベルはまとめて1つ）、分類は空欄1つ、チェック表は1列が1設問）
sub r_mock {
    my ($arg, $lines, $ln) = @_;
    my $min = ($arg =~ /(\d+)/) ? $1 : 60;
    my @secs;
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        my ($k, $p) = map { trim($_) } split /\|/, $l;
        push @secs, { k => $k, p => 0 + ($p // 0) };
    }
    my $tot = 0;
    $tot += $_->{p} for @secs;
    push @WARN, "[$CUR:$ln] mock: 配点の合計が100点ではない（${tot}点）" if $tot != 100;
    my %chl = map { $_ => "$META{$_}{num} $META{$_}{subtitle}" } grep { /^ch\d\d$/ } @{ $CTX{ids} };
    my $cfg = esc(JSON::PP->new->canonical(1)->encode({ min => 0 + $min, pass => 70, secs => \@secs, ch => \%chl }));
    my $rows = join '', map {
        my $k = esc($_->{k});
        qq{<tr data-s="$k"><th scope="row" class="whitespace-nowrap border-t border-gray-200 py-2 pr-3 text-left font-bold text-gray-800">$k</th>}
      . qq{<td class="whitespace-nowrap border-t border-gray-200 py-2 pr-3 text-right font-black tabular-nums text-gray-900" data-r="pts"></td>}
      . qq{<td class="w-full border-t border-gray-200 py-2"><div class="h-2 rounded-full bg-gray-200"><div class="h-2 rounded-full bg-gray-700" data-r="bar" style="width:0%"></div></div><p class="mt-1 text-[11px] text-gray-500" data-r="det"></p></td></tr>};
    } @secs;
    my $btn = 'rounded-md px-3 py-1.5 text-sm font-bold transition';
    return qq{<section class="kb-mock my-8 rounded-lg border-2 border-gray-900 bg-white p-5 shadow-[6px_6px_0_0_#111827] sm:p-6" data-mock="$cfg">}
         . label('text-amber-600', 'EXAM MODE ― 模擬試験モード')
         . qq{<p class="mb-3 font-serif text-xl font-black leading-snug text-gray-900">${min}分で解いて、その場で採点する</p>}
         . qq{<p class="text-[15px] leading-relaxed text-gray-700">開始すると画面の下に残り時間が出て、各問題の「答え合わせ」と解答・解説が隠れる。第1問は仕訳の入力欄に、第2問・第3問は空欄と分類の欄に答えを入れ、最後に「採点する」を押そう。時間切れになると、その時点の解答で自動的に採点する。</p>}
         . qq{<div class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2"><button type="button" class="kb-mock-start rounded-md bg-gray-900 px-5 py-3 font-black text-white transition hover:bg-gray-700">試験を開始する（${min}分）</button><span class="kb-mock-last text-xs font-bold text-gray-500"></span></div>}
         . qq{<div class="kb-mock-result mt-6 hidden border-t-2 border-gray-900 pt-5" tabindex="-1">}
         . label('text-gray-400', 'RESULT ― 採点結果')
         . qq{<div class="flex flex-wrap items-center gap-x-4 gap-y-2"><p class="font-black text-gray-900"><span class="text-5xl" data-r="total">0</span><span class="ml-1 text-base text-gray-500">/ 100点</span></p><span class="rounded-full px-3 py-1 text-sm font-black" data-r="verdict"></span></div>}
         . qq{<div class="relative mt-4 h-2.5 rounded-full bg-gray-200"><div class="h-2.5 rounded-full transition-all" data-r="meter" style="width:0%"></div><div class="absolute -bottom-1 -top-1 w-0.5 bg-gray-900" style="left:70%"></div></div>}
         . qq{<p class="mt-1.5 text-right text-[11px] font-bold text-gray-500" style="padding-right:calc(30% - 2.5rem)">合格ライン70点</p>}
         . qq{<table class="mt-3 w-full border-collapse text-sm"><tbody>$rows</tbody></table>}
         . qq{<p class="mt-3 text-sm text-gray-600" data-r="time"></p>}
         . qq{<div class="mt-4 rounded-lg bg-amber-50 p-4" data-r="review"><p class="mb-2 text-sm font-bold text-gray-900">間違えた問題の章を復習しよう（誤りの多い順）</p><div class="grid gap-2" data-r="links"></div></div>}
         . qq{<p class="mt-4 text-xs leading-relaxed text-gray-500">各問題の入力欄に、正誤の色がついている。解答・解説を開いて、赤い欄を確認しよう。</p>}
         . qq{<div class="mt-4 flex flex-wrap gap-2"><button type="button" class="kb-mock-start $btn bg-gray-900 text-white hover:bg-gray-700">もう一度解く</button></div>}
         . qq{<span class="hidden bg-emerald-600 bg-red-600 bg-amber-500 bg-emerald-100 text-emerald-800 bg-red-100 text-red-800 flex flex-none items-center justify-between gap-3 rounded-md border border-amber-300 bg-white px-3 py-2 text-sm text-xs font-bold text-gray-500 text-gray-800 hover:border-amber-500 text-amber-700 text-red-400"></span>}
         . '</div></section>'
         . qq{<div id="kb-timer" class="no-print fixed inset-x-0 bottom-0 z-40 hidden border-t border-gray-700 bg-gray-900/95 text-white backdrop-blur" role="timer" aria-live="off">}
         . qq{<div class="mx-auto flex max-w-3xl items-center gap-2 px-4 py-2.5 sm:gap-3 sm:px-6"><span class="hidden text-[11px] font-bold tracking-widest text-amber-400 sm:inline">残り時間</span>}
         . qq{<span class="text-2xl font-black tabular-nums" data-t>${min}:00</span>}
         . qq{<span class="ml-auto flex items-center gap-1.5 sm:gap-2"><button type="button" class="kb-mock-pause $btn border border-white/30 hover:bg-white/10">一時停止</button>}
         . qq{<button type="button" class="kb-mock-finish $btn bg-amber-400 font-black text-gray-900 hover:bg-amber-300">採点する</button>}
         . qq{<button type="button" class="kb-mock-quit $btn text-gray-300 hover:text-white">中止</button></span></div></div>};
}

sub caption_journal {
    my $arg = shift;
    return '' if $arg eq '';
    $arg =~ s/^【(.+?)】\s*/$1　/;    # 【入力欄の見出し】は、本文ではカッコを外して表示する
    return qq{<figcaption class="flex items-stretch border border-b-0 border-gray-900/70 bg-gray-50 text-sm leading-relaxed text-gray-800"><span class="flex flex-none items-center bg-gray-900 px-2.5 font-serif text-[11px] font-black tracking-[0.2em] text-white">仕訳</span><span class="min-w-0 px-3 py-1.5">} . inl($arg) . '</span></figcaption>';
}

sub r_journal {
    my ($arg, $lines, $ln) = @_;
    my ($dsum, $csum, $numeric, $rows) = (0, 0, 1, '');
    for my $l (@$lines) {
        next if $l =~ /^\s*$/;
        if ($l !~ /\|/) {
            $rows .= qq{<tr><td colspan="4" class="border-t border-dotted border-gray-900/25 px-3 py-3 text-center font-serif font-black tracking-[0.2em] text-gray-600">} . inl(trim($l)) . '</td></tr>';
            next;
        }
        my ($L, $R) = split /\s*\|\s*/, $l, 2;
        $R //= '';
        my ($da, $dv) = side($L);
        my ($ca, $cv) = side($R);
        for my $pair ([$dv, \$dsum], [$cv, \$csum]) {
            my ($v, $ref) = @$pair;
            next if $v eq '';
            my $x = amt($v);
            if (defined $x) { $$ref += $x } else { $numeric = 0 }
        }
        $rows .= '<tr>'
               . '<td class="border-t border-dotted border-gray-900/25 px-2 sm:px-3 py-2.5 align-top font-bold text-gray-900">' . inl($da) . '</td>'
               . '<td class="whitespace-nowrap border-r-[3px] border-t border-double border-dotted border-gray-900/25 border-r-gray-900/60 px-2 sm:px-3 py-2.5 text-right align-top tabular-nums text-gray-900 [border-right-style:double]">' . inl($dv) . '</td>'
               . '<td class="border-t border-dotted border-gray-900/25 px-2 sm:px-3 py-2.5 align-top font-bold text-gray-900">' . inl($ca) . '</td>'
               . '<td class="whitespace-nowrap border-t border-dotted border-gray-900/25 px-2 sm:px-3 py-2.5 text-right align-top tabular-nums text-gray-900">' . inl($cv) . '</td></tr>';
    }
    $NCHK{journal}++ if $numeric && ($CTX{mode} // '') ne 'all';
    if ($numeric && abs($dsum - $csum) > 0.001) {
        push @WARN, "[$CUR:$ln] 仕訳の貸借不一致「$arg」 借方 $dsum ≠ 貸方 $csum";
    }
    return qq{<figure class="my-7">} . caption_journal($arg)
         . qq{<div class="overflow-x-auto border border-gray-900/70 bg-white shadow-[4px_4px_0_0_rgba(27,36,48,.07)]"><table class="w-full min-w-[19rem] border-collapse text-sm"><thead><tr>}
         . qq{<th class="border-t-[3px] border-blue-700 bg-blue-50/70 px-2 py-1.5 text-left text-[11px] font-bold tracking-[0.15em] text-blue-800 sm:px-3">借方科目</th>}
         . qq{<th class="border-r-[3px] border-t-[3px] border-blue-700 border-r-gray-900/60 bg-blue-50/70 px-2 py-1.5 text-right text-[11px] font-bold tracking-[0.15em] text-blue-800 [border-right-style:double] sm:px-3">金額</th>}
         . qq{<th class="border-t-[3px] border-rose-500 bg-rose-50/70 px-2 py-1.5 text-left text-[11px] font-bold tracking-[0.15em] text-rose-800 sm:px-3">貸方科目</th>}
         . qq{<th class="border-t-[3px] border-rose-500 bg-rose-50/70 px-2 py-1.5 text-right text-[11px] font-bold tracking-[0.15em] text-rose-800 sm:px-3">金額</th>}
         . qq{</tr></thead><tbody>$rows</tbody></table></div></figure>};
}

sub r_taccount {
    my ($arg, $lines, $ln) = @_;
    my (@items, $tot);    # 記入順を保持（締切線の後の「前期繰越」＝開始記入も正しい位置に描く）
    my ($ls, $rs, $lnum, $rnum) = (0, 0, 1, 1);
    for my $l (@$lines) {
        next if $l =~ /^\s*$/;
        if ($l =~ /^=\s*(.*)$/) {
            my ($x, $y) = split /\s*\|\s*/, $1, 2;
            $tot = [trim($x // ''), trim($y // '')];
            push @items, ['T', @$tot];
            next;
        }
        my ($x, $y) = split /\s*\|\s*/, $l, 2;
        $y //= '';
        my @L = side($x);
        my @R = side($y);
        if (!$tot) {    # 合計の検証は締切線より上の記入だけで行う
            if ($L[1] ne '') { my $v = amt($L[1]); defined $v ? ($ls += $v) : ($lnum = 0); }
            if ($R[1] ne '') { my $v = amt($R[1]); defined $v ? ($rs += $v) : ($rnum = 0); }
        }
        push @items, ['R', @L, @R];
    }
    if ($tot) {
        $NCHK{taccount}++ if ($CTX{mode} // '') ne 'all';
        my ($tl, $tr) = (amt($tot->[0]), amt($tot->[1]));
        push @WARN, "[$CUR:$ln] T勘定「$arg」借方合計 $ls ≠ $tot->[0]" if $lnum && defined $tl && abs($tl - $ls) > 0.001;
        push @WARN, "[$CUR:$ln] T勘定「$arg」貸方合計 $rs ≠ $tot->[1]" if $rnum && defined $tr && abs($tr - $rs) > 0.001;
    }
    my $blank = grep { /\[\[/ } @$lines;    # 穴埋めの空欄があるときは、スマホでも収まるよう余白と文字を詰める
    my $bw = 0;
    for my $l (@$lines) {
        while ($l =~ /$BLANK_RE/g) { my $a = trim($2); $bw = blank_em($a) if is_num($a) && blank_em($a) > $bw; }
    }
    local $CTX{bw} = $bw || undef;
    my $px  = $blank ? 'px-0.5 sm:px-2' : 'px-2';
    my $td  = $blank ? "whitespace-nowrap $px py-1.5 align-top text-gray-700" : "$px py-1.5 align-top text-gray-700 [word-break:keep-all]";
    my $tdn = "whitespace-nowrap $px py-1.5 text-right align-top tabular-nums text-gray-900";
    my $tc  = "whitespace-nowrap border-b-[3px] border-t border-double border-gray-500 $px py-1.5 text-right font-bold tabular-nums text-gray-900";
    my $tx  = sub {    # 摘要：日付はスマホでは小さく上の行に分ける
        my $s = shift // '';
        return inl($s) unless $s =~ m{^(\d{1,2}/\d{1,2})\s+(.*)$};
        return qq{<span class="block text-[11px] leading-tight tabular-nums text-gray-400 sm:mr-1 sm:inline sm:text-xs">$1</span>} . inl($2);
    };
    my $body = '';
    for my $it (@items) {
        my ($k, @c) = @$it;
        if ($k eq 'T') {
            $body .= '<tr><td></td>'
                   . qq{<td class="$tc border-r-2 border-r-gray-900">} . inl($c[0]) . '</td><td></td>'
                   . qq{<td class="$tc">} . inl($c[1]) . '</td></tr>';
            next;
        }
        $body .= '<tr class="even:bg-slate-50">'
               . qq{<td class="$td">} . $tx->($c[0]) . '</td>'
               . qq{<td class="$tdn border-r-2 border-gray-900">} . inl($c[1]) . '</td>'
               . qq{<td class="$td">} . $tx->($c[2]) . '</td>'
               . qq{<td class="$tdn">} . inl($c[3]) . '</td></tr>';
    }
    my ($fp, $fs) = $blank ? ('p-2', 'text-xs sm:text-sm') : ('p-3', 'text-sm');
    return qq{<figure class="relative my-7 border border-gray-900/25 bg-white $fp pt-4 shadow-[4px_4px_0_0_rgba(27,36,48,.07)] sm:p-4 sm:pt-5"><span aria-hidden="true" class="absolute left-0 top-0 bg-gray-900 px-1.5 py-0.5 font-serif text-[9px] font-black leading-none tracking-[0.15em] text-white">T</span><div class="overflow-x-auto"><table class="w-full min-w-[17rem] border-collapse $fs">}
         . qq{<thead><tr><th colspan="4" class="border-b-[3px] border-gray-900 pb-1.5 text-center font-serif text-base font-black tracking-[0.1em] text-gray-900">} . inl($arg) . '</th></tr>'
         . qq{<tr class="text-[10px] font-bold tracking-wider"><th colspan="2" class="border-r-2 border-gray-900 px-2 pt-1 text-left text-blue-700">借方</th><th colspan="2" class="px-2 pt-1 text-right text-rose-700">貸方</th></tr></thead>}
         . "<tbody>$body</tbody></table></div></figure>";
}

sub r_table {
    my ($arg, $lines, $ln) = @_;
    my ($compact, $sumchk, $split) = (0, 0, 0);
    # compact: 帳簿など列の多い表 / sum: 最終の強調行＝縦計を検証
    # split:N: 左N列と残りの列を別の表にする（勘定式の財務諸表。スマホでは上下、PCでは左右に並ぶ）
    while ($arg =~ s/^(compact|sum|split:(\d+))\s+//) {
        my ($flag, $n) = ($1, $2);
        $compact = 1  if $flag eq 'compact';
        $sumchk  = 1  if $flag eq 'sum';
        $split   = $n if defined $n;
    }
    my $pad = $compact ? "px-1.5 py-1.5 text-xs whitespace-nowrap" : $split ? "px-1.5 py-1.5 text-xs sm:px-2.5 sm:text-sm" : "px-2 py-2 sm:px-3";
    my (@group, @head, @rows);
    for my $l (@$lines) {
        next if $l =~ /^\s*$/;
        next if $l =~ /^\|?\s*:?-{3,}/;
        if ($l =~ /^!!\s*(.*)$/) { @group = cells($1); next; }
        my $emph = ($l =~ s/^\|=/|/) ? 1 : 0;
        my @c = cells($l);
        if (!@head) { @head = @c; next; }
        push @rows, [$emph, @c];
    }
    my $ncol = scalar @head;
    if (@group) {    # 2段見出し: 列数は結合を展開して数える
        $ncol = 0;
        $ncol += ($_ =~ /\*(\d+)$/) ? $1 : 1 for @group;
    }
    for my $r (@rows) {
        my $nc = scalar(@$r) - 1;
        push @WARN, "[$CUR:$ln] 表「$arg」列数不一致（見出し $ncol 列 / 行 $nc 列）: " . join('|', @$r[1 .. $#$r]) if $nc != $ncol;
    }
    # 縦計の検証（最後の強調行が、それより上の通常行の合計と一致するか）
    if ($sumchk) {
        $NCHK{table}++ if ($CTX{mode} // '') ne 'all';
        my ($last) = grep { $rows[$_][0] } reverse 0 .. $#rows;
        if (!defined $last) {
            push @WARN, "[$CUR:$ln] 表「$arg」sum 指定だが合計行（|=）がない";
        }
        else {
            for my $c (1 .. $#{ $rows[$last] }) {
                next unless is_num($rows[$last][$c]);
                my $t = amt($rows[$last][$c]);
                next unless defined $t;
                my $s = 0;
                for my $i (0 .. $last - 1) {
                    next if $rows[$i][0];
                    my $v = amt($rows[$i][$c] // '');
                    $s += $v if defined $v;
                }
                push @WARN, "[$CUR:$ln] 表「$arg」第${c}列の縦計 $s ≠ 合計行 $t" if abs($s - $t) > 0.001;
            }
        }
    }
    # 数値列の判定
    my @numcol;
    for my $c (0 .. $ncol - 1) {
        my ($nn, $ne) = (0, 0);
        for my $r (@rows) {
            my $v = $r->[$c + 1] // '';
            next if unblank($v) eq '';
            $ne++;
            $nn++ if is_num($v);
        }
        $numcol[$c] = ($ne && $nn / $ne >= 0.6) ? 1 : 0;
    }
    # 穴埋めの入力欄の幅は列ごとにそろえる（欄の幅が答えの桁数のヒントにならないように）
    my @bw;
    for my $r (@rows) {
        for my $c (1 .. $#$r) {
            my $s = $r->[$c] // '';
            while ($s =~ /$BLANK_RE/g) {
                my $a = trim($2);
                $bw[$c - 1] = blank_em($a) if is_num($a) && blank_em($a) > ($bw[$c - 1] // 0);
            }
        }
    }
    my $cell = sub {    # 1つのセル（$i は列番号）
        my ($v, $i, $extra) = @_;
        local $CTX{bw} = $bw[$i];
        my $nm  = is_num($v) || ($numcol[$i] && ($v =~ /^\s*[-―－]\s*$/ || ($v =~ /\[\[/ && unblank($v) eq '')));
        my $cls = $nm ? 'whitespace-nowrap text-right tabular-nums' : 'min-w-[3.5em] text-left';
        return qq{<td class="border-t border-gray-900/10 $pad align-top text-gray-800 $cls$extra">} . inl($v) . '</td>';
    };
    if ($split && $split < $ncol && !@group) {
        my $thc = "border-b border-gray-900 bg-gray-100 $pad text-[11px] font-bold tracking-wider text-gray-900";
        my $html = '';
        for my $half ([0, $split - 1], [$split, $ncol - 1]) {
            my ($a, $b) = @$half;
            my $th = join '', map { qq{<th class="$thc whitespace-nowrap } . ($numcol[$_] ? 'text-right' : 'text-left') . '">' . inl($head[$_]) . '</th>' } $a .. $b;
            my $tb = '';
            for my $r (@rows) {
                my ($emph, @c) = @$r;
                my $empty = !grep { ($c[$_] // '') ne '' } $a .. $b;    # 行をそろえるための空行は、スマホでは隠す
                my $trc = ($emph ? 'bg-amber-50 font-bold' : 'even:bg-slate-50') . ' md:h-11' . ($empty ? ' max-md:hidden' : '');
                $tb .= qq{<tr class="$trc">} . join('', map { $cell->($c[$_] // '', $_, $numcol[$_] ? '' : ' [word-break:auto-phrase]') } $a .. $b) . '</tr>';
            }
            $html .= qq{<div class="ledger overflow-x-auto border-b border-t-2 border-gray-900 bg-white"><table class="w-full border-collapse text-sm"><thead><tr>$th</tr></thead><tbody>$tb</tbody></table></div>};
        }
        my $cap = $arg ne '' ? '<figcaption class="mb-2 flex items-baseline gap-2.5 text-sm font-bold leading-snug text-gray-900"><span aria-hidden="true" class="h-3 w-[3px] flex-none translate-y-0.5 bg-shu"></span><span class="min-w-0">' . inl($arg) . '</span></figcaption>' : '';
        my $fr  = 'md:grid-cols-[' . $split . 'fr_' . ($ncol - $split) . 'fr]';    # PC（768px以上）では左右に並べ、幅を列数に比例させる
        return qq{<figure class="my-6">$cap<div class="grid gap-3 $fr md:items-start md:gap-2">$html</div></figure>};
    }
    my $thc = "border-gray-900/25 bg-gray-100 $pad text-[11px] font-bold tracking-wider text-gray-900 [tr:last-child>&]:border-b [tr:last-child>&]:border-b-gray-900";
    my $thead = '';
    if (@group) {
        $thead .= '<tr>';
        for my $g (@group) {
            if ($g =~ /^(.*?)\*(\d+)$/) {
                $thead .= qq{<th colspan="$2" class="$thc border-b border-l text-center">} . inl($1) . '</th>';
            }
            else {
                $thead .= qq{<th rowspan="2" class="$thc border-l text-left align-bottom">} . inl($g) . '</th>';
            }
        }
        $thead .= '</tr>';
    }
    $thead .= '<tr>';
    for my $i (0 .. $#head) {
        my $al = @group ? 'text-center' : ($numcol[$i] ? 'text-right' : 'text-left');
        my $bl = @group ? ' border-l' : '';
        $thead .= qq{<th class="$thc$bl whitespace-nowrap $al">} . inl($head[$i]) . '</th>';
    }
    $thead .= '</tr>';
    my $tbody = '';
    for my $r (@rows) {
        my ($emph, @c) = @$r;
        my $trc = $emph ? ($r == $rows[-1] ? 'total bg-amber-50 font-bold' : 'bg-amber-50 font-bold') : 'even:bg-slate-50';
        $tbody .= qq{<tr class="$trc">};
        for my $i (0 .. $#c) {
            $tbody .= $cell->($c[$i], $i, @group && $i > 0 ? ' border-l border-gray-200' : '');
        }
        $tbody .= '</tr>';
    }
    my $cap = $arg ne '' ? '<figcaption class="mb-2 flex items-baseline gap-2.5 text-sm font-bold leading-snug text-gray-900"><span aria-hidden="true" class="h-3 w-[3px] flex-none translate-y-0.5 bg-shu"></span><span class="min-w-0">' . inl($arg) . '</span></figcaption>' : '';
    my $hint = $compact ? '<p class="mt-1.5 text-right text-[11px] text-gray-400 sm:hidden">表は横にスクロールできます →</p>' : '';
    return qq{<figure class="my-6">$cap<div class="ledger overflow-x-auto border-b border-t-2 border-gray-900 bg-white"><table class="w-full border-collapse text-sm"><thead>$thead</thead><tbody>$tbody</tbody></table></div>$hint</figure>};
}

my %BOXCOLOR = (
    a => 'bg-blue-600 text-white',
    l => 'bg-rose-500 text-white',
    e => 'bg-emerald-600 text-white',
    x => 'bg-amber-500 text-white',
    r => 'bg-violet-600 text-white',
    p => 'bg-emerald-300 text-emerald-950',
    s => 'bg-slate-400 text-white',
    z => 'border-2 border-dashed border-gray-400 bg-white text-gray-500',
    k => 'bg-gray-900 text-white',
    d => 'bg-red-600 text-white',
);

sub r_boxes {
    my ($arg, $lines, $ln) = @_;
    my (@L, @R, $H);
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        if ($l =~ /^H\s+(.*)$/) { $H = [map { trim($_) } split /\|/, $1, 2]; next; }
        if ($l =~ /^([LR])\s+([a-z])\s+([\d.]+)\s+(.*)$/) {
            push @{ $1 eq 'L' ? \@L : \@R }, [$2, $3, $4];
            next;
        }
        push @WARN, "[$CUR:$ln] boxes: 解釈できない行「$l」";
    }
    my ($sl, $sr) = (0, 0);
    $sl += $_->[1] for @L;
    $sr += $_->[1] for @R;
    my $max = $sl > $sr ? $sl : $sr;
    $max ||= 1;
    my $col = sub {
        return join '', map {
            my ($c, $v, $t) = @$_;
            my $h = int($v / $max * 250);
            $h = 46 if $h < 46;
            my $cc = $BOXCOLOR{$c} // $BOXCOLOR{s};
            qq{<div class="flex flex-col items-center justify-center px-2 text-center text-xs font-bold leading-snug sm:text-sm $cc" style="height:${h}px">} . inl($t) . '</div>';
        } @_;
    };
    my $hd = $H ? qq{<div class="mb-1.5 grid grid-cols-2 gap-1.5 text-center text-[11px] font-bold text-gray-500"><div>} . inl($H->[0]) . '</div><div>' . inl($H->[1] // '') . '</div></div>' : '';
    return qq{<figure class="my-9"><div class="mx-auto max-w-md border border-gray-900/20 bg-white p-3 shadow-[4px_4px_0_0_rgba(27,36,48,.07)] sm:p-4">$hd<div class="grid grid-cols-2 items-start gap-1.5"><div class="flex flex-col gap-1.5">}
         . $col->(@L) . '</div><div class="flex flex-col gap-1.5">' . $col->(@R) . '</div></div></div>'
         . ($arg ne '' ? '<figcaption class="mt-3 text-center text-sm text-gray-500">' . inl($arg) . '</figcaption>' : '')
         . '</figure>';
}

sub r_steps {
    my ($arg, $lines) = @_;
    my ($n, $li) = (0, '');
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        my ($t, $d) = map { trim($_) } split /\|/, $l, 2;
        $n++;
        # 誌面風：罫線で区切り、朱の明朝の番号（01、02…）を左に置く
        $li .= qq{<li class="flex gap-4 border-b border-[#1B2430]/12 py-4 sm:gap-6">}
             . sprintf(qq{<span class="w-8 flex-none pt-0.5 font-serif text-xl font-black leading-none text-[#C8462E] sm:w-10 sm:text-2xl">%02d</span>}, $n)
             . '<div class="min-w-0"><p class="font-bold leading-snug text-[#1B2430]">' . inl($t) . '</p>'
             . (defined $d && $d ne '' ? '<p class="mt-1 text-sm leading-relaxed text-[#3D4551]">' . inl($d) . '</p>' : '')
             . '</div></li>';
    }
    my $cap = $arg ne '' ? '<p class="py-3 text-sm font-bold text-[#1B2430]">' . inl($arg) . '</p>' : '';
    return qq{<div class="my-8 border-t-2 border-[#1B2430]">$cap<ol class="border-t border-[#1B2430]/12">$li</ol></div>};
}

sub r_kpi {
    my ($arg, $lines) = @_;
    my $tiles = '';
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        my ($k, $v, $nt) = map { trim($_) } split /\|/, $l, 3;
        $tiles .= '<div class="border border-gray-900/15 border-t-2 border-t-gray-900 bg-white px-3.5 py-3">'
                . '<p class="text-[11px] font-bold leading-snug text-gray-500">' . inl($k) . '</p>'
                . '<p class="mt-1 font-serif text-lg font-black leading-tight tabular-nums text-gray-900 sm:text-xl">' . inl($v // '') . '</p>'
                . (defined $nt && $nt ne '' ? '<p class="mt-1 text-[11px] leading-snug text-gray-500">' . inl($nt) . '</p>' : '')
                . '</div>';
    }
    my $cap = $arg ne '' ? '<p class="mb-2 text-sm font-bold text-gray-700">' . inl($arg) . '</p>' : '';
    return qq{<div class="my-6">$cap<div class="grid grid-cols-2 gap-2.5 sm:grid-cols-3">$tiles</div></div>};
}

sub r_timeline {
    my ($arg, $lines) = @_;
    my $li = '';
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        my ($d, $t, $x) = map { trim($_) } split /\|/, $l, 3;
        my $dot = 'border-2 border-shu bg-white';
        if ($d =~ s/^!//) { $dot = 'bg-shu'; }
        $li .= '<li class="relative pl-6">'
             . qq{<span class="absolute -left-[7px] top-1 h-[13px] w-[13px] rounded-full $dot"></span>}
             . '<p class="text-[11px] font-bold tracking-[0.2em] text-shu">' . inl($d) . '</p>'
             . '<p class="font-bold leading-snug text-gray-900">' . inl($t // '') . '</p>'
             . (defined $x && $x ne '' ? '<p class="mt-0.5 text-sm leading-relaxed text-gray-600">' . inl($x) . '</p>' : '')
             . '</li>';
    }
    my $cap = $arg ne '' ? '<p class="mb-6 font-serif font-black text-gray-900">' . inl($arg) . '</p>' : '';
    return qq{<div class="my-10 border border-gray-900/20 bg-white p-5 sm:p-7">$cap<ol class="ml-1.5 space-y-6 border-l border-gray-900/25">$li</ol></div>};
}

# ---------------------------------------------------------------- toc / nav
sub href_for {
    my ($id, $mode) = @_;
    return $mode eq 'all' ? "#$id" : "$id.html";
}

sub r_toc {
    my ($arg) = @_;
    my $compact = ($arg // '') eq 'compact';    # 表紙用：章番号と論点名だけの1行リスト
    my $html = qq{<div id="toc" class="scroll-mt-20">};
    my $part = "\0";
    my $open = 0;
    if ($compact) {    # 表紙用：部ごとに開閉できる目次（見出しに章の範囲を出す）
        my @groups;
        for my $id (@{ $CTX{ids} }) {
            my $p = $META{$id}{part} // '';
            push @groups, [$p, []] if !@groups || $groups[-1][0] ne $p;
            push @{ $groups[-1][1] }, $id;
        }
        # 部ごとの色：落ち着いた和の色（墨・藍・青磁・山吹・朱・葡萄・若竹・弁柄・墨・鼠）
        my @PAL = ('#1B2430', '#2F4A6D', '#3E7C7A', '#B8862F', '#C8462E', '#6D4C6A', '#5E7D63', '#8A5A44', '#1B2430', '#6A707A');
        my $gi  = 0;
        $html .= '<div class="border-t border-[#1B2430] lg:grid lg:grid-cols-2 lg:items-start lg:gap-x-10">';
        for my $g (@groups) {
            my $col = $PAL[$gi++ % @PAL];
            my ($p, $ids) = @$g;
            my ($n1, $n2) = map { $META{$_}{num} // '' } $ids->[0], $ids->[-1];
            my $range = $n1 eq $n2 ? $n1 : "$n1〜$n2";
            # 部ごとの行：上に朱の小さなラベル（第1部など）、明朝の部名、下に章の範囲
            my ($badge, $name, $sub);
            if ($p =~ /^(第\S+部)\s+(.+)$/) { ($badge, $name, $sub) = ($1, $2, "$range（" . scalar(@$ids) . '章）'); }
            elsif (@$ids == 1)            { ($badge, $name, $sub) = ($p, $META{ $ids->[0] }{subtitle} // $range, $range); }
            else                          { ($badge, $name, $sub) = ($p, $range, scalar(@$ids) . '本'); }
            $html .= '<details class="group border-b border-[#1B2430]/15">'
                   . qq{<summary class="flex cursor-pointer select-none items-stretch gap-4 pr-1 transition hover:bg-white/60 sm:gap-5">}
                   . qq{<span class="flex w-9 flex-none items-center justify-center py-3 text-[11px] font-black tracking-[0.2em] text-white [writing-mode:vertical-rl] sm:w-10" style="background:$col">} . esc($badge) . '</span>'
                   . qq{<span class="min-w-0 flex-1 self-center py-4 sm:py-5">}
                   . '<span class="block font-serif text-lg font-black leading-snug text-[#1B2430] sm:text-[1.35rem]">' . esc($name) . '</span>'
                   . '<span class="mt-1 block text-xs font-bold text-[#6A707A]">' . esc($sub) . '</span></span>'
                   . '<span aria-hidden="true" class="flex h-8 w-8 flex-none items-center justify-center self-center border border-[#1B2430]/25 text-base leading-none text-[#1B2430] transition group-open:border-[#C8462E] group-open:text-[#C8462E]"><span class="block transition-transform group-open:rotate-45">＋</span></span></summary>'
                   . qq{<ol class="mb-5 ml-9 border-l-2 bg-white/70 sm:ml-10" style="border-color:$col">};
            for my $id (@$ids) {
                my $m    = $META{$id};
                my $href = href_for($id, $CTX{mode} // 'page');
                $html .= qq{<li class="border-b border-[#1B2430]/8 last:border-b-0"><a href="$href" class="group/item flex items-baseline gap-3 px-4 py-3 transition hover:bg-[#F6F3EC]">}
                       . '<span class="w-14 flex-none text-xs font-bold text-[#6A707A]">' . esc($m->{num}) . '</span>'
                       . '<span class="min-w-0 flex-1 text-[15px] font-bold leading-snug text-[#1B2430] [word-break:auto-phrase] group-hover/item:text-[#C8462E]">' . esc($m->{subtitle}) . '</span>'
                       . '<span aria-hidden="true" class="flex-none text-[#1B2430]/30 transition group-hover/item:translate-x-0.5 group-hover/item:text-[#C8462E]">→</span></a></li>';
            }
            $html .= '</ol></details>';
        }
        $html .= '</div>';
        return $html . '</div>';
    }
    for my $id (@{ $CTX{ids} }) {
        my $m = $META{$id};
        my $p = $m->{part} // '';
        if ($p ne $part) {
            $html .= '</div></section>' if $open;
            $part = $p;
            $html .= '<section class="mt-10"><h3 class="mb-3 text-xs font-bold tracking-[0.25em] text-gray-500">' . esc($p) . '</h3><div class="grid gap-3">';
            $open = 1;
        }
        my $href = href_for($id, $CTX{mode} // 'page');
        $html .= qq{<a href="$href" class="group block rounded-lg border border-gray-200 bg-white p-4 shadow-sm transition hover:border-gray-900 hover:shadow-md sm:p-5">}
               . '<div class="flex flex-wrap items-center gap-2 text-xs font-bold"><span class="rounded bg-gray-900 px-2 py-0.5 text-white">' . esc($m->{num}) . '</span><span class="text-gray-500">' . esc($m->{subtitle}) . '</span>'
               . ($m->{time} ? '<span class="ml-auto font-medium text-gray-400">' . esc($m->{time}) . '</span>' : '') . '</div>'
               . '<p class="mt-2 font-serif text-lg font-black leading-snug text-gray-900 group-hover:underline group-hover:decoration-amber-400 group-hover:decoration-2 group-hover:underline-offset-4">' . esc($m->{title}) . '</p>'
               . ($m->{lead} ? '<p class="mt-1.5 text-sm leading-relaxed text-gray-500">' . inl($m->{lead}) . '</p>' : '')
               . '</a>';
    }
    $html .= ($compact ? '</ol></section>' : '</div></section>') if $open;
    return $html . '</div>';
}

sub nav_list {
    my ($cur, $mode) = @_;
    my ($html, $part) = ('', "\0");
    for my $id (@{ $CTX{ids} }) {
        my $m = $META{$id};
        my $p = $m->{part} // '';
        if ($p ne $part) {
            $part = $p;
            $html .= '<p class="px-3 pb-1 pt-3 text-[10px] font-bold tracking-[0.2em] text-gray-400">' . esc($p) . '</p>' if $p ne '';
        }
        my $active = ($id eq ($cur // '')) ? 'bg-gray-900 text-white [&>span:first-child]:text-amber-400' : 'text-gray-700 hover:bg-gray-50';
        my $href = href_for($id, $mode);
        $html .= qq{<a href="$href" class="flex gap-2 rounded-md px-3 py-2 text-sm $active"><span class="w-14 flex-none font-bold text-gray-400">} . esc($m->{num}) . '</span><span class="font-medium">' . esc($m->{subtitle}) . '</span></a>';
    }
    return $html;
}

# ---------------------------------------------------------------- page shell
sub head_html {
    my ($title, $desc, $path, $noindex) = @_;
    my $h = <<'HTML';
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="theme-color" content="#1B2430">
<title>__TITLE__</title>
<meta name="description" content="__DESC__">
__SEO__<link rel="icon" type="image/png" sizes="32x32" href="icons/icon-32.png">
<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">
<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = {
    theme: {
      extend: {
        colors: {
          gray: { 50: '#F6F3EC', 100: '#EFEBE2', 200: '#E3DED3', 300: '#CCC7BC', 400: '#989CA3', 500: '#6A707A', 600: '#545C68', 700: '#3D4551', 800: '#2A3340', 900: '#1B2430', 950: '#121922' },
          amber: { 50: '#FAF4E4', 100: '#F3E6C4', 200: '#E8D29A', 300: '#DDBB66', 400: '#D9A441', 500: '#A87724', 600: '#946A20', 700: '#7A571A', 800: '#5F4414', 900: '#47330F', 950: '#2E2109' },
          shu: '#C8462E', ai: '#2F4A6D', seiji: '#3E7C7A', yamabuki: '#B8862F', budo: '#6D4C6A', sumi: '#1B2430', kami: '#F6F3EC',
          // 既定の青・赤・緑・紫を、表紙と同じ和の色（藍・朱・青磁・葡萄）に置き換える
          blue:    { 50: '#EEF2F6', 100: '#DDE5EE', 200: '#BCCBDC', 300: '#93A9C3', 400: '#6485A8', 500: '#456A91', 600: '#37577E', 700: '#2F4A6D', 800: '#263C59', 900: '#1E2F46', 950: '#141F2F' },
          indigo:  { 50: '#EEF2F6', 100: '#DDE5EE', 200: '#BCCBDC', 300: '#93A9C3', 400: '#6485A8', 500: '#456A91', 600: '#2F4A6D', 700: '#263C59', 800: '#1E2F46', 900: '#18263A', 950: '#141F2F' },
          rose:    { 50: '#FAF0EC', 100: '#F4DED6', 200: '#E9BFB2', 300: '#DC9A88', 400: '#D0745E', 500: '#C8462E', 600: '#AE3B26', 700: '#8F301F', 800: '#70271A', 900: '#541E14', 950: '#33110B' },
          red:     { 50: '#FBEFEC', 100: '#F6DCD6', 200: '#EDBAB0', 300: '#E09384', 400: '#E0664E', 500: '#C4402F', 600: '#B03224', 700: '#96281C', 800: '#7A2118', 900: '#5E1A13', 950: '#3A0F0B' },
          emerald: { 50: '#EDF5F2', 100: '#D8EAE5', 200: '#B3D5CD', 300: '#86BAB0', 400: '#5A9C92', 500: '#43857E', 600: '#3A7570', 700: '#2C5E5A', 800: '#244C49', 900: '#1C3B39', 950: '#102524' },
          violet:  { 50: '#F5F0F4', 100: '#E9DEE7', 200: '#D4BFD1', 300: '#BA9AB5', 400: '#9C7497', 500: '#83597E', 600: '#6D4C6A', 700: '#5B3F58', 800: '#483246', 900: '#372635', 950: '#221721' },
          slate:   { 50: '#FAF8F3', 100: '#F1EEE6', 200: '#E3DED3', 300: '#CCC7BC', 400: '#989CA3', 500: '#6A707A', 600: '#545C68', 800: '#2A3340' },
          yellow:  { 200: '#F1DFA0', 800: '#6E5417' },
        },
        borderRadius: { sm: '1px', DEFAULT: '2px', md: '2px', lg: '2px', xl: '3px', '2xl': '4px' },
        fontFamily: {
          sans: ['"Noto Sans JP"', '"Hiragino Kaku Gothic ProN"', '"Hiragino Sans"', 'Meiryo', 'sans-serif'],
          serif: ['"Noto Serif JP"', '"Hiragino Mincho ProN"', '"Yu Mincho"', 'serif'],
        },
      },
    },
  };
</script>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;500;700;900&family=Noto+Serif+JP:wght@700;900&display=swap" rel="stylesheet">
<style>
  html { -webkit-text-size-adjust: 100%; scroll-behavior: smooth; }
  html, body { overflow-x: clip; }  /* 画面いっぱいの帯（w-screen）で横スクロールが出ないように */
  summary { list-style: none; }
  .kb-ghost { position: fixed; left: 0; top: 0; z-index: 60; pointer-events: none; transform: translate(-50%, -50%); opacity: .95; }
  /* 模擬試験モード中は、解答・答え合わせを隠す */
  body.kb-exam .kb-answer, body.kb-exam .kb-check, body.kb-exam .kb-reveal, body.kb-exam .kb-jres, body.kb-exam .kb-result { display: none !important; }
  body.kb-exam { padding-bottom: 4.5rem; }
  .kb-blank::placeholder { color: #93A9C3; font-weight: 700; }
  body { text-rendering: optimizeLegibility; }
  main p, main li { text-wrap: pretty; }

  /* ── 章ページの部品 ── */
  /* 蛍光ペン：文字の下半分にだけ引く */
  .mk { background: linear-gradient(transparent 58%, rgba(217,164,65,.42) 58%, rgba(217,164,65,.42) 92%, transparent 92%); padding: 0 .1em; color: inherit; font-weight: 700; -webkit-box-decoration-break: clone; box-decoration-break: clone; }
  /* 章の扉：帳簿の罫線 */
  .tobira { background-image: repeating-linear-gradient(to bottom, transparent 0, transparent 35px, rgba(47,74,109,.07) 35px, rgba(47,74,109,.07) 36px); }
  /* 答案用紙：演習の入力欄は方眼紙にのせる */
  .kb-sheet { position: relative; border: 1px solid rgba(47,74,109,.35); border-top: 3px solid #2F4A6D; background-color: #fff;
    background-image: linear-gradient(rgba(47,74,109,.055) 1px, transparent 1px), linear-gradient(90deg, rgba(47,74,109,.055) 1px, transparent 1px); background-size: 18px 18px; background-position: -1px -1px; }
  .kb-sheet-tab { display: inline-flex; align-items: center; gap: .6em; margin-top: -1px; margin-bottom: .6rem; }
  /* 帳簿の表：合計行は上に細線・下に二重線 */
  .ledger tr.total > td { border-top: 1px solid #1B2430; border-bottom: 3px double #1B2430; background: #FAF4E4; font-weight: 700; }
  /* 区切り：ひし形を3つ */
  .rule-mark { display: flex; align-items: center; justify-content: center; gap: .9rem; margin: 4rem 0; }
  .rule-mark::before, .rule-mark::after { content: ''; height: 1px; flex: 1; background: rgba(27,36,48,.15); }
  .rule-mark i { display: block; width: 5px; height: 5px; rotate: 45deg; background: #C8462E; }
  .rule-mark i:nth-child(2) { background: #1B2430; }
  /* 脇の目次（広い画面） */
  #rail a { transition: color .2s, border-color .2s; }
  #rail a.on { color: #1B2430; border-color: #C8462E; font-weight: 700; }
  #rail a.on .rn { color: #C8462E; }
  details.kb-answer[open] > summary { background: #F6F3EC; }
  @keyframes stamp-in { 0% { opacity: 0; scale: 1.6; } 60% { opacity: 1; scale: .94; } 100% { opacity: 1; scale: 1; } }
  .stamp-in { animation: stamp-in .5s cubic-bezier(.22,1,.36,1) both; animation-delay: .35s; }
  @media (prefers-reduced-motion: reduce) { .stamp-in { animation: none; } }
  summary::-webkit-details-marker { display: none; }
  table { font-variant-numeric: tabular-nums; }

  /* ── 表紙まわりの動きと質感 ── */
  /* 出現の動きは translate で行う（transform を使うと、傾けた部品の rotate を打ち消してしまう） */
  @keyframes fade-up { from { opacity: 0; translate: 0 1.5rem; } to { opacity: 1; translate: 0 0; } }
  @keyframes fade-in { from { opacity: 0; } to { opacity: 1; } }
  @keyframes ink-spread { from { transform: scale(.6); opacity: 0; } to { transform: scale(1); opacity: 1; } }
  [data-anim] { opacity: 0; }
  [data-anim].anim-on { opacity: 1; animation: fade-up .9s cubic-bezier(.22,1,.36,1) both; }

  /* にじんだ朱の円（表紙の背景） */
  .hero-ink-circle {
    position: absolute; border-radius: 50%; pointer-events: none;
    background: radial-gradient(circle, rgba(200,70,46,.07) 0%, transparent 70%);
    animation: ink-spread 1.6s cubic-bezier(.22,1,.36,1) both;
  }

  /* 紺の地にのせる、紙のざらつき */
  .grain-overlay::before {
    content: ''; position: absolute; inset: 0; z-index: 0; pointer-events: none; opacity: .5;
    background: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='200' height='200'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.8' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 .09 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  }

  /* フッターの和紋様 */
  .footer-pattern {
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E%3Cpath d='M0 20a20 20 0 0 1 20-20 20 20 0 0 1 20 20 20 20 0 0 1-20 20 20 20 0 0 1-20-20' fill='none' stroke='%23F6F3EC' stroke-width='.3' opacity='.06'/%3E%3C/svg%3E");
  }

  #progress { background: linear-gradient(90deg, #C8462E, #B8862F) !important; }
  ::selection { background: rgba(200,70,46,.2); }

  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    [data-anim] { opacity: 1 !important; animation: none !important; }
    .hero-ink-circle { animation: none; }
  }


  @media print {
    .no-print { display: none !important; }
    body { background: #fff !important; }
    section, aside, figure, details { break-inside: avoid; }
    [data-anim] { opacity: 1 !important; animation: none !important; }
  }
</style>
<noscript><style>[data-anim] { opacity: 1 !important; }</style></noscript>
</head>
HTML
    my ($t, $d) = (esc($title), esc($desc));
    # 検索エンジン・SNS向けの情報（@site が設定されているときだけ出力する）
    my $seo = $noindex ? qq{<meta name="robots" content="noindex, follow">\n} : '';
    if ($SITE ne '' && defined $path) {
        my $url = esc($path eq '' ? "$SITE/" : "$SITE/$path");
        $seo .= qq{<link rel="canonical" href="$url">\n} unless $noindex;
        $seo .= qq{<meta property="og:type" content="} . ($path eq '' ? 'website' : 'article') . qq{">\n}
              . qq{<meta property="og:site_name" content="} . esc($BOOK) . qq{">\n}
              . qq{<meta property="og:title" content="$t">\n}
              . qq{<meta property="og:description" content="$d">\n}
              . qq{<meta property="og:url" content="$url">\n}
              . qq{<meta property="og:image" content="} . esc("$SITE/icons/icon-192.png") . qq{">\n}
              . qq{<meta property="og:locale" content="ja_JP">\n}
              . qq{<meta name="twitter:card" content="summary">\n};
    }
    $h =~ s/__TITLE__/$t/;
    $h =~ s/__DESC__/$d/;
    $h =~ s/__SEO__/$seo/;
    return $h;
}

sub site_header {
    my ($cur, $mode) = @_;
    my $label = ($cur && $META{$cur}) ? esc($META{$cur}{num}) : '';
    my $home  = $mode eq 'all' ? '#top' : 'index.html';
    return qq{<header class="no-print sticky top-0 z-40 border-b border-[#1B2430]/8 bg-[#F6F3EC]/85 backdrop-blur-xl backdrop-saturate-150">}
         . qq{<div class="mx-auto flex h-14 } . ($CTX{wide} ? 'max-w-6xl lg:px-8' : 'max-w-3xl') . qq{ items-center justify-between gap-3 px-4 sm:px-6">}
         . qq{<a href="$home" class="group flex min-w-0 items-center gap-2.5 transition-opacity hover:opacity-75"><span class="flex h-8 w-8 flex-none items-center justify-center bg-[#1B2430] font-serif text-sm font-black text-[#F6F3EC] shadow-sm transition-transform group-hover:scale-105">$MARK</span><span class="truncate text-sm font-black tracking-tight text-gray-900 sm:text-base">$BOOK</span></a>}
         . qq{<div class="flex flex-none items-center gap-2">}
         . ($label ? qq{<span class="hidden border-l border-gray-900/20 pl-3 font-serif text-xs font-black text-shu sm:inline">$label</span>} : '')
         . qq{<details data-dropdown class="relative"><summary class="flex cursor-pointer select-none items-center gap-2.5 border border-gray-900/30 bg-white/70 px-3 py-1.5 text-sm font-bold text-gray-900 transition-colors hover:border-gray-900 hover:bg-white">目次<span aria-hidden="true" class="flex flex-col gap-[3px]"><span class="block h-px w-3.5 bg-gray-900"></span><span class="block h-px w-3.5 bg-shu"></span><span class="block h-px w-3.5 bg-gray-900"></span></span></summary>}
         . qq{<nav class="absolute right-0 mt-2 max-h-[75vh] w-[min(22rem,calc(100vw-2rem))] overflow-y-auto border border-gray-900 bg-white p-2 shadow-[6px_6px_0_0_rgba(27,36,48,.15)]">}
         . ($mode eq 'all'
              ? qq{<a href="index.html" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">章ごとのページ版へ</a><a href="index.html#guide" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">このサイトの使い方</a>}
              : qq{<a href="index.html" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">表紙・目次</a><a href="index.html#guide" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">このサイトの使い方</a><a href="all.html" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">全章一気読み版（1ファイル）</a>})
         . nav_list($cur, $mode)
         . qq{</nav></details></div></div></header>\n};
}

sub footer_html {
    my $w = $CTX{wide} ? 'max-w-6xl lg:px-8' : 'max-w-3xl';
    (my $h = <<"HTML") =~ s/__FOOTW__/$w/;
<footer class="footer-pattern relative mt-28 border-t border-[#1B2430]/20 bg-[#1B2430]">
  <div class="mx-auto __FOOTW__ px-4 py-16 sm:px-6">
    <div class="flex flex-col gap-8 sm:flex-row sm:items-start sm:justify-between">
      <div class="space-y-3">
        <div class="flex items-center gap-3">
          <span class="flex h-8 w-8 flex-none items-center justify-center bg-[#C8462E] font-serif text-sm font-black text-white shadow-sm">$MARK</span>
          <p class="font-serif text-lg font-black tracking-wide text-[#F6F3EC]">$BOOK</p>
        </div>
        <p class="text-sm font-medium text-[#F6F3EC]/80">$BOOK_SUB</p>
      </div>
      <div class="flex flex-wrap items-center gap-6 text-xs font-bold text-[#F6F3EC]/70">
        <a href="#top" class="transition hover:text-white">↑ ページ先頭へ</a>
        <a href="index.html#guide" class="transition hover:text-white">使い方ガイド</a>
        <a href="all.html" class="transition hover:text-white">全章一気読み版</a>
        <a href="apx-a.html" class="transition hover:text-white">付録A 勘定科目辞典</a>
      </div>
    </div>
    <div class="mt-12 border-t border-white/10 pt-8 space-y-3 text-xs leading-relaxed text-[#F6F3EC]/50">
      <p>物語に登場する企業・人物・数値は、学習のために設計した架空のものです。実在の企業・団体・商品とは関係ありません。「実際にあった話」で紹介する事例と統計は、公開されている報道・統計資料にもとづき、出典を併記しています。</p>
      <p>$SCOPE</p>
      <p class="pt-4 text-center font-mono text-[11px] text-[#F6F3EC]/40">© $BOOK All rights reserved.</p>
    </div>
  </div>
</footer>
HTML
    return $h;
}

sub script_html {    # 進捗バー・目次・「続きから」＋ 演習などのスクリプト（assets/kb.js をそのまま埋め込む）
    return (<<'HTML' =~ s/'kb3-/'$KEY-/gr) . "<script>\n$KBJS</script>\n";
<script>
(() => {
  // スクロール連動アニメーション (IntersectionObserver)
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add('anim-on');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });
    document.querySelectorAll('[data-anim]').forEach((el) => observer.observe(el));
  } else {
    document.querySelectorAll('[data-anim]').forEach((el) => el.classList.add('anim-on'));
  }

  const bar = document.getElementById('progress');
  const update = () => {
    const d = document.documentElement;
    const max = d.scrollHeight - d.clientHeight;
    bar.style.width = (max > 0 ? (d.scrollTop / max) * 100 : 0) + '%';
  };
  addEventListener('scroll', update, { passive: true });
  update();
  document.addEventListener('click', (e) => {
    document.querySelectorAll('details[data-dropdown][open]').forEach((d) => {
      if (!d.contains(e.target) || e.target.closest('nav a')) d.removeAttribute('open');
    });
  });
  // 脇の目次：読んでいる節に印をつける
  const rail = document.getElementById('rail');
  if (rail) {
    const links = [...rail.querySelectorAll('a')];
    const secs = links.map((a) => document.getElementById(a.hash.slice(1)));
    const mark = () => {
      let k = -1;
      secs.forEach((s, i) => { if (s && s.getBoundingClientRect().top < 160) k = i; });
      links.forEach((a, i) => a.classList.toggle('on', i === k));
    };
    addEventListener('scroll', mark, { passive: true });
    mark();
  }
  addEventListener('beforeprint', () => document.querySelectorAll('main details').forEach((d) => (d.open = true)));
  // 「続きから読む」: 章ページを開いたら記録し、表紙で再開ボタンを出す（保存できない環境では何もしない）
  try {
    const page = document.body.dataset.page;
    if (page) localStorage.setItem('kb3-last', JSON.stringify({ id: page, label: document.body.dataset.label || '' }));
    const cont = document.getElementById('cta-continue');
    const last = JSON.parse(localStorage.getItem('kb3-last') || 'null');
    if (cont && last && last.id) {
      cont.href = last.id + '.html';
      cont.querySelector('[data-label]').textContent = last.label;
      cont.classList.remove('hidden');
      cont.classList.add('flex', 'sm:inline-flex');
      // 続きがあるときは「続きから読む」を主役にし、最初から読むボタンは濃い文字の枠ボタンにする（明るい背景でも読める色）
      const start = document.getElementById('cta-start');
      if (start) start.className = 'group inline-flex w-full items-center justify-between gap-6 border border-[#1B2430]/40 bg-white/70 px-6 py-4 font-bold text-[#1B2430] transition hover:border-[#C8462E] hover:text-[#C8462E] sm:w-auto';
    }
  } catch (e) {}
})();

</script>
HTML
}

sub page_html {
    my (%o) = @_;
    my $rec = $o{record} ? ' data-page="' . esc($o{cur}) . '" data-label="' . esc($o{record}) . '"' : '';
    return head_html($o{title}, $o{desc}, $o{path}, $o{noindex})
         . qq{<body id="top"$rec class="bg-[#F6F3EC] font-sans text-[16px] text-gray-800 antialiased sm:text-[17px]">\n}
         . qq{<div id="progress" class="no-print fixed left-0 top-0 z-50 h-1 w-0 bg-[#C8462E]"></div>\n}
         . site_header($o{cur}, $o{mode})
         . ($o{top} // '')
         . qq{<main class="mx-auto } . ($CTX{wide} ? 'max-w-6xl lg:px-8' : 'max-w-3xl') . qq{ px-4 pb-10 sm:px-6">\n$o{main}\n</main>\n}
         . footer_html()
         . script_html()
         . "</body>\n</html>\n";
}

# ---------------------------------------------------------------- chapter assembly
sub chapter_hero {
    my $id = shift;
    my $m  = $META{$id};
    # 章の扉：画面いっぱいの帳簿の罫線の上に、朱の余白線・大きな章番号・伝票の欄（読了目安など）を置く
    my $num  = $m->{num} // '';
    my $big  = $num =~ /(\d+)/ ? sprintf('%02d', $1) : $num =~ /^付録\s*(\S+)/ ? $1 : $num =~ /^(\S)/ ? $1 : '';
    my $h  = qq{<header class="tobira relative left-1/2 w-screen -translate-x-1/2 overflow-hidden border-b border-gray-900/15">}
           . qq{<div aria-hidden="true" class="pointer-events-none absolute inset-y-0 left-2 flex gap-[3px] sm:left-8 lg:left-[calc(50%-27rem)]"><span class="w-px bg-shu/30"></span><span class="w-px bg-shu/30"></span></div>}
           . qq{<div class="relative mx-auto max-w-3xl px-6 pb-10 pt-10 sm:px-8 sm:pb-14 sm:pt-16">}
           . qq{<span aria-hidden="true" class="pointer-events-none absolute -top-3 right-3 select-none font-serif text-[8.5rem] font-black leading-none tracking-tighter text-gray-900/[0.06] sm:right-6 sm:text-[13rem]">} . esc($big) . '</span>';
    $h .= '<p class="relative flex items-center gap-3 text-[11px] font-bold tracking-[0.25em] text-gray-500"><span class="flex-none bg-shu px-2.5 py-1 font-serif text-sm font-black tracking-[0.1em] text-white">' . esc($num) . '</span>'
        . '<span aria-hidden="true" class="h-px w-8 flex-none bg-gray-900/30"></span><span class="min-w-0">' . esc($m->{part} // '') . '</span></p>';
    $h .= '<p class="relative mt-9 text-sm font-bold leading-relaxed text-gray-600 sm:mt-12">' . esc($m->{subtitle}) . '</p>';
    $h .= '<h1 class="relative mt-3 font-serif text-[1.85rem] font-black leading-[1.4] text-gray-900 text-balance [word-break:auto-phrase] sm:text-[2.75rem] sm:leading-[1.32]">' . join('', map { '<span class="inline-block">' . esc($_) . '</span>' } grep { length } split /(?<=[。、？！])/, $m->{title}) . '</h1>';
    $h .= '<p class="relative mt-7 max-w-2xl border-l-2 border-shu pl-4 leading-[1.95] text-gray-700">' . inl($m->{lead}) . '</p>' if $m->{lead};
    my @chips;
    push @chips, ['読了目安', esc($m->{time})]  if $m->{time};
    push @chips, ['難易度',   '<span class="tracking-[0.15em] text-shu">' . esc($m->{level}) . '</span>'] if $m->{level};
    push @chips, ['範囲',     esc($m->{scope})] if $m->{scope};
    $h .= '<dl class="relative mt-9 inline-flex max-w-full flex-wrap border border-gray-900/70 bg-white text-xs shadow-[4px_4px_0_0_rgba(27,36,48,.07)]">' . join('', map { qq{<div class="flex min-w-[6.5rem] flex-col border-gray-900/25 [&:not(:first-child)]:border-l"><dt class="border-b border-gray-900/25 bg-gray-100 px-3 py-1 text-[10px] font-bold tracking-[0.2em] text-gray-600">$_->[0]</dt><dd class="px-3 py-2 text-sm font-bold text-gray-900">$_->[1]</dd></div>} } @chips) . '</dl>' if @chips;
    $h .= '</div></header>';
    if (@{ $m->{goals} }) {
        my $gi = 0;
        $h .= qq{<section class="mt-10 border-y-[3px] border-double border-gray-900/70 bg-white/60 p-5 sm:p-7">}
            . label('text-shu', 'GOALS')
            . '<p class="mb-4 font-serif text-lg font-black text-gray-900">この章で学ぶこと</p><ol class="divide-y divide-gray-900/10">'
            . join('', map { $gi++; '<li class="flex gap-4 py-2.5 text-[15px] leading-relaxed"><span class="flex-none pt-0.5 text-xs font-black tabular-nums text-shu">' . sprintf('%02d', $gi) . '</span><span>' . inl($_) . '</span></li>' } @{ $m->{goals} })
            . '</ol></section>';
    }
    if ($TOC{$id} && @{ $TOC{$id} }) {
        my $toclabel = $id eq 'guide' ? 'このページの目次' : 'この章の目次';
        $h .= qq{<details class="group mt-4 border border-gray-900/20 bg-white/60 open:bg-white"><summary class="flex cursor-pointer select-none items-center justify-between px-5 py-3.5 font-serif text-sm font-black text-gray-900">$toclabel<span aria-hidden="true" class="flex h-6 w-6 flex-none items-center justify-center border border-gray-900/30 text-sm leading-none transition group-open:border-shu group-open:text-shu"><span class="block transition-transform group-open:rotate-45">＋</span></span></summary><ol class="space-y-1.5 border-t border-gray-100 px-5 py-4 text-sm">};
        my $i = 0;
        for my $s (@{ $TOC{$id} }) {
            $i++;
            $h .= sprintf('<li><a href="#%s" class="flex gap-3 text-gray-700 hover:text-shu"><span class="w-6 flex-none font-bold text-shu">%02d</span><span>%s</span></a></li>', $s->[0], $i, inl($s->[1]));
        }
        $h .= '</ol></details>';
    }
    return $h;
}

sub chapter_nav {
    my $idx = shift;
    my @ids = @{ $CTX{ids} };
    my $h = '<p aria-hidden="true" class="no-print mt-24 flex items-center gap-3 text-[10px] font-bold tracking-[0.3em] text-gray-500"><span class="h-1.5 w-6 bg-shu/60"></span>CONTINUE<span class="h-px flex-1 bg-gray-900/15"></span>次の事件へ</p>'
          . '<nav class="no-print mt-4 grid gap-3 sm:grid-cols-2">';
    if ($idx > 0) {
        my $p = $META{ $ids[$idx - 1] };
        $h .= qq{<a href="$ids[$idx-1].html" class="group border border-gray-900/25 bg-white/60 p-5 transition-colors hover:border-gray-900 hover:bg-white"><p class="text-[11px] font-bold tracking-[0.2em] text-gray-500">← 前へ　} . esc($p->{num}) . '</p><p class="mt-2 font-serif font-black leading-snug text-gray-900">' . esc($p->{subtitle}) . '</p></a>';
    }
    if ($idx < $#ids) {
        my $n = $META{ $ids[$idx + 1] };
        $h .= qq{<a href="$ids[$idx+1].html" class="group bg-gray-900 p-5 text-right transition-colors duration-300 hover:bg-shu sm:col-start-2"><p class="text-[11px] font-bold tracking-[0.2em] text-amber-400 group-hover:text-white">次へ　} . esc($n->{num}) . ' →</p><p class="mt-2 font-serif font-black leading-snug text-white">' . esc($n->{subtitle}) . '</p></a>';
    }
    else {
        $h .= qq{<a href="index.html" class="group bg-gray-900 p-5 text-right transition-colors duration-300 hover:bg-shu sm:col-start-2"><p class="text-[11px] font-bold tracking-[0.2em] text-amber-400 group-hover:text-white">表紙へ戻る →</p><p class="mt-2 font-serif font-black leading-snug text-white">目次・全体像</p></a>};
    }
    return $h . '</nav>';
}

sub read_source {
    my ($id) = @_;
    my @lines = split /\n/, slurp("$SRC/$id.txt"), -1;
    my %m = (id => $id, goals => []);
    while (@lines && $lines[0] =~ /^@(\w+)\s*(.*)$/) {
        my ($k, $v) = ($1, $2);
        shift @lines;
        if   ($k eq 'goal') { push @{ $m{goals} }, $v }
        else                { $m{$k} = $v }
    }
    $META{$id} = \%m;
    $BODY{$id} = \@lines;
}

sub render_body {
    my $id = shift;
    local $CUR  = $id;
    local $SECN = 0;
    local $CTX{h2}    = '';
    local $CTX{tseen} = {};
    # 用語のポップアップ：辞典そのもの・仕訳道場・模擬試験（ヒントになる）・表紙では付けない
    local $CTX{terms} = ($TERMRE && $id !~ /^(?:index|apx-a|apx-c|apx-d)$/) ? 1 : 0;
    $TOC{$id}   = [];
    $TUSED{$id} = {};
    my $i = 0;
    my $nodes = parse($BODY{$id}, \$i, 0);
    my $r   = rn($nodes, '');
    my $tot = sprintf('%02d', $SECN);
    $r =~ s/__SECTOTAL__/$tot/g;
    return $r;
}

# ---------------------------------------------------------------- main
my @ALL = grep { /\S/ && !/^#/ && !/^@/ } map { trim($_) } split /\n/, slurp("$SRC/book.txt");
my @IDS = grep { -e "$SRC/$_.txt" } @ALL;
print "未作成（スキップ）: ", join(', ', grep { !-e "$SRC/$_.txt" } @ALL), "\n" if @IDS < @ALL;
$CTX{ids} = \@IDS;
read_source($_) for @IDS;
read_source('index');
load_terms();

$RENDERED{$_} = render_body($_) for @IDS;

my $count = 0;
for my $i (0 .. $#IDS) {
    my $id = $IDS[$i];
    my $m  = $META{$id};
    local $CTX{mode} = 'page';
    # 脇の目次（広い画面だけ）：本文の左に節の一覧を固定し、読んでいる節に朱の印をつける
    my $rail = '';
    if (@{ $TOC{$id} || [] } >= 2) {
        my $k = 0;
        $rail = qq{<nav id="rail" aria-label="この章の目次" class="no-print fixed left-[calc(50%-41.5rem)] top-24 hidden max-h-[calc(100vh-8rem)] w-[14.5rem] overflow-y-auto min-[1380px]:block">}
              . qq{<p class="mb-3 flex items-center gap-2 text-[10px] font-bold tracking-[0.25em] text-gray-500"><span class="font-serif text-xs font-black tracking-normal text-shu">} . esc($m->{num}) . qq{</span><span aria-hidden="true" class="h-px flex-1 bg-gray-900/20"></span>INDEX</p><ol>}
              . join('', map { $k++; sprintf('<li><a href="#%s" class="flex gap-2.5 border-l-2 border-gray-900/10 py-1.5 pl-3 text-[12px] leading-snug text-gray-500 hover:text-gray-900"><span class="rn flex-none font-serif font-black tabular-nums text-gray-400">%02d</span><span class="min-w-0">%s</span></a></li>', $_->[0], $k, inl($_->[1])) } @{ $TOC{$id} })
              . '</ol></nav>';
    }
    my $main = chapter_hero($id) . "\n" . $RENDERED{$id} . "\n" . chapter_nav($i) . $rail . terms_block([$id], 'page', $id);
    spew("$OUT/$id.html", page_html(
        title => "$m->{num} $m->{subtitle} | $BOOK",
        desc  => "$m->{title} ― $m->{subtitle}。$BOOK_SUB",
        cur    => $id,
        mode   => 'page',
        main   => $main,
        record => "$m->{num} $m->{subtitle}",
        path   => $id,
    ));
    $count++;
}

# 本書の使い方（章の並びには含めない独立ページ）
if (-e "$SRC/guide.txt") {
    read_source('guide');
    local $CTX{mode} = 'page';
    my $body = render_body('guide');
    my $cta  = qq{<nav class="no-print mt-16"><a href="$IDS[0].html" class="group block rounded-lg border border-gray-900 bg-gray-900 p-5 text-center transition hover:bg-gray-800">}
             . qq{<p class="text-xs font-bold text-amber-400">準備ができたら</p><p class="mt-1 text-lg font-black text-white group-hover:underline">$START →</p></a></nav>};
    spew("$OUT/guide.html", page_html(
        title => "本書の使い方 | $BOOK",
        desc  => $META{guide}{lead} // $BOOK_SUB,
        cur   => '',
        mode  => 'page',
        main  => chapter_hero('guide') . "\n" . $body . "\n" . $cta . terms_block(['guide'], 'page', ''),
        path  => 'guide',
    ));
    $count++;
}

# 表紙
sub cover_top {    # 表紙：書名・つかみ・開始ボタンと、学習明細書（レシート）
    my $mode  = shift;
    my $start = $mode eq 'all' ? "#$IDS[0]" : "$IDS[0].html";
    # 配色：紙 #F6F3EC／墨 #1B2430／本文 #3D4551／補足 #6A707A／朱 #C8462E／山吹 #B8862F
    my $cont  = $mode eq 'all' ? '' : qq{<a id="cta-continue" href="$start" class="hidden w-full items-center justify-between gap-3 bg-[#1B2430] px-6 py-4 font-bold text-[#F6F3EC] transition hover:bg-[#C8462E] sm:w-auto"><span class="min-w-0 text-left"><span class="block whitespace-nowrap">続きから読む</span><span data-label class="mt-0.5 block text-xs font-normal leading-snug text-[#F6F3EC]/70"></span></span><span aria-hidden="true">→</span></a>};
    my $hook  = $CFG{hook} ? qq{<p class="max-w-xl border-l-2 border-[#C8462E] pl-4 font-serif text-base leading-relaxed text-[#C8462E] text-balance [word-break:auto-phrase] sm:text-xl">} . esc($CFG{hook}) . '</p>' : '';

    # 学習明細書（レシート）：book.txt の「@stats 21:事件で学ぶ | …」を明細の行にする
    my @stats = map { [split /\s*:\s*/, $_, 2] } grep { /:/ } split /\s*\|\s*/, ($CFG{stats} // '');
    my $lines = join '', map {
        qq{<div class="flex items-baseline gap-2 py-1.5"><span class="flex-none">} . esc($_->[1]) . qq{</span><span aria-hidden="true" class="mb-1 flex-1 border-b border-dotted border-[#1B2430]/35"></span><span class="flex-none text-base font-bold tabular-nums">} . esc($_->[0]) . '</span></div>'
    } @stats;
    my $zig = 'background:linear-gradient(-45deg,transparent 7px,#fff 0) 0 0/14px 14px repeat-x,linear-gradient(45deg,transparent 7px,#fff 0) 0 0/14px 14px repeat-x';
    my $bar = 'background:repeating-linear-gradient(90deg,#1B2430 0 2px,transparent 2px 4px,#1B2430 4px 5px,transparent 5px 8px,#1B2430 8px 11px,transparent 11px 13px)';
    my $receipt = @stats ? qq{<div data-anim class="relative mx-auto mt-16 w-full max-w-[22rem] rotate-[1.5deg] transition-transform duration-500 hover:rotate-0 lg:mt-0" style="animation-delay:.5s">}
        . qq{<span aria-hidden="true" class="absolute -top-3 left-1/2 z-10 h-7 w-28 -translate-x-1/2 -rotate-3 bg-[#B8862F]/35"></span>}
        . qq{<div class="bg-white px-6 pb-6 pt-8 font-mono text-[13px] text-[#1B2430] shadow-2xl shadow-[#1B2430]/10 ring-1 ring-[#1B2430]/10">}
        . qq{<p class="text-center font-sans text-[10px] font-bold tracking-[0.3em] text-[#6A707A]">KAMOGAWA ACCOUNTING OFFICE</p>}
        . qq{<p class="mt-2 text-center font-serif text-xl font-black tracking-[0.2em]">学習明細書</p>}
        . qq{<p class="mt-1 text-center text-[11px] text-[#6A707A]">日商簿記3級 ― 全21章・付録4本</p>}
        . qq{<div class="mt-5 border-y border-dashed border-[#1B2430]/40 py-3">$lines</div>}
        . qq{<div class="flex items-baseline justify-between pt-4 font-sans"><span class="text-sm font-black">合計</span><span class="font-serif text-lg font-black">3級の出題範囲 <span class="text-[#C8462E]">100%</span></span></div>}
        . qq{<div aria-hidden="true" class="mx-auto mt-6 h-10 w-48" style="$bar"></div>}
        . qq{<p class="mt-2 text-center text-[11px] text-[#6A707A]">合格まで、責任をもってお預かりします</p>}
        . qq{</div>}
        . qq{<div aria-hidden="true" class="h-[7px] w-full" style="$zig"></div>}
        . qq{<div aria-hidden="true" class="absolute -left-3 bottom-10 flex h-[5.5rem] w-[5.5rem] rotate-[-14deg] sm:-left-7 items-center justify-center rounded-full border-2 border-[#C8462E]/80 font-serif text-[13px] font-black leading-tight text-[#C8462E]/85"><span class="text-center">全範囲<br>収録</span></div>}
        . '</div>' : '';

    my $ruled = 'background-image:url("data:image/svg+xml,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%27160%27 height=%27160%27%3E%3Cfilter id=%27n%27%3E%3CfeTurbulence type=%27fractalNoise%27 baseFrequency=%27.9%27 numOctaves=%272%27 stitchTiles=%27stitch%27/%3E%3CfeColorMatrix values=%270 0 0 0 0.11 0 0 0 0 0.14 0 0 0 0 0.19 0 0 0 .05 0%27/%3E%3C/filter%3E%3Crect width=%27100%25%27 height=%27100%25%27 filter=%27url(%23n)%27/%3E%3C/svg%3E"),repeating-linear-gradient(to bottom,transparent 0,transparent 39px,rgba(47,74,109,.06) 39px,rgba(47,74,109,.06) 40px)';
    return qq{<section class="relative overflow-hidden border-b border-[#1B2430]/10 bg-[#F6F3EC] text-[#1B2430]" style='$ruled'>}
         . qq{<div aria-hidden="true" class="hero-ink-circle" style="width:35vw;height:35vw;right:-8vw;top:-5vw;animation-delay:.3s"></div>}
         . qq{<div aria-hidden="true" class="hero-ink-circle" style="width:25vw;height:25vw;left:-5vw;bottom:-8vw;background:radial-gradient(circle,rgba(62,124,122,.05) 0%,transparent 70%);animation-delay:.6s"></div>}
         . qq{<div aria-hidden="true" class="pointer-events-none absolute inset-y-0 left-2 flex gap-[3px] sm:left-8 lg:left-[calc(50%-37rem)]"><span class="w-px bg-[#C8462E]/30"></span><span class="w-px bg-[#C8462E]/30"></span></div>}
         . qq{<div class="relative z-10 mx-auto flex max-w-3xl flex-col px-6 pb-14 pt-10 sm:px-8 sm:pb-20 sm:pt-14 lg:min-h-[calc(100vh-3.5rem)] lg:max-w-6xl lg:justify-center lg:py-16">}
         . qq{<p data-anim class="flex items-center gap-3 text-[10px] font-bold tracking-[0.4em] text-[#6A707A] sm:text-[11px]" style="animation-delay:.1s"><span class="inline-block h-1.5 w-6 bg-[#C8462E]/60"></span><span>CASE BOOK</span><span class="h-px flex-1 bg-[#1B2430]/15"></span><span>日商簿記 3級</span><span class="inline-block h-1.5 w-6 bg-[#3E7C7A]/60"></span></p>}
         . qq{<div class="mt-8 sm:mt-12 lg:mt-14 lg:grid lg:grid-cols-12 lg:items-center lg:gap-10">}
         . qq{<div class="lg:col-span-7">}
         . ($hook ? qq{<div data-anim style="animation-delay:.2s">$hook</div>} : '')
         . qq{<h1 data-anim class="mt-6 font-serif text-[2.9rem] font-black leading-[1.05] tracking-tight sm:mt-8 sm:text-[5rem] lg:text-[5.4rem] xl:text-[6rem]" style="animation-delay:.35s"><span class="inline-block">ケースで学ぶ</span><br><span class="inline-block bg-[linear-gradient(transparent_70%,rgba(200,70,46,.22)_70%,rgba(200,70,46,.22)_92%,transparent_92%)]">簿記3級</span></h1>}
         . qq{<p data-anim class="mt-6 max-w-lg text-sm font-bold leading-relaxed text-[#3D4551] text-balance [word-break:auto-phrase] sm:mt-8 sm:text-base" style="animation-delay:.5s">$BOOK_SUB</p>}
         . qq{<div data-anim class="mt-9 flex flex-col gap-3 sm:mt-12 sm:flex-row sm:flex-wrap sm:items-center sm:gap-x-7" style="animation-delay:.65s">$cont}
         . qq{<a id="cta-start" href="$start" class="group inline-flex w-full items-center justify-between gap-10 bg-[#1B2430] px-7 py-[1.1rem] font-bold tracking-wide text-[#F6F3EC] transition-colors duration-300 hover:bg-[#C8462E] sm:w-auto">$START<span aria-hidden="true" class="transition group-hover:translate-x-1">→</span></a>}
         . qq{<a href="#guide" class="self-start bg-gradient-to-r from-[#C8462E] to-[#C8462E] bg-[length:0%_1px] bg-left-bottom bg-no-repeat pb-1 text-sm font-bold text-[#1B2430] transition-[background-size,color] duration-300 hover:bg-[length:100%_1px] hover:text-[#C8462E] sm:self-auto">このサイトの使い方 ↓</a></div>}
         . qq{</div>}
         . qq{<div class="lg:col-span-5">$receipt</div>}
         . qq{</div></div></section>\n};
}

{
    local $CTX{mode} = 'page';
    local $CTX{wide} = 1;    # 表紙はPCで横幅を広く使う
    my $body = render_body('index');
    spew("$OUT/index.html", page_html(
        title => "$BOOK ― $BOOK_SUB",
        desc  => $META{index}{lead} // $BOOK_SUB,
        cur   => '',
        mode  => 'page',
        top   => cover_top('page'),
        main  => $body,
        path  => '',
    ));
    $count++;
}

# 全章一気読み版
{
    local $CTX{mode} = 'all';
    my $toc  = render_body('index');
    my $main = $toc;
    for my $id (@IDS) {
        $main .= qq{<article id="$id" class="scroll-mt-14 mt-28 border-t-[3px] border-double border-gray-900/70 pt-2">} . chapter_hero($id) . "\n" . $RENDERED{$id} . '</article>';
    }
    $main .= terms_block(\@IDS, 'all', '');
    spew("$OUT/all.html", page_html(
        title => "【全章一気読み版】$BOOK ― $BOOK_SUB",
        desc  => $META{index}{lead} // $BOOK_SUB,
        cur   => '',
        mode  => 'all',
        top   => cover_top('all'),
        main  => $main,
        path  => 'all',
        noindex => 1,    # 各章と内容が重複するので、検索結果には各章のページを出す
    ));
    $count++;
}

# 検索エンジン向け：sitemap.xml と robots.txt（@site が設定されているときだけ）
if ($SITE ne '') {
    my @paths = ('', (-e "$SRC/guide.txt" ? 'guide' : ()), @IDS);    # all.html は noindex なので載せない
    my $xml = qq{<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n};
    $xml .= '  <url><loc>' . esc($_ eq '' ? "$SITE/" : "$SITE/$_") . "</loc></url>\n" for @paths;
    $xml .= "</urlset>\n";
    spew("$OUT/sitemap.xml", $xml);
    spew("$OUT/robots.txt", "User-agent: *\nAllow: /\n\nSitemap: $SITE/sitemap.xml\n");
    $count += 2;
}

print "生成: $count ファイル\n";
if (@WARN) {
    print "\n⚠ 警告 " . scalar(@WARN) . " 件\n";
    print "  $_\n" for @WARN;
    exit 1;
}
printf "検証OK: 仕訳 %d 件の貸借一致・T字勘定 %d 件の合計・帳簿/試算表など %d 表の縦計・全表の列数\n",
    $NCHK{journal} // 0, $NCHK{taccount} // 0, $NCHK{table} // 0;
printf "演習: 仕訳入力 %d・穴埋め %d・分類 %d・チェック表 %d・シミュレーター %d・THINK選択式 %d ／ 用語リンク %d 語（辞典 %d 語）\n",
    $NCHK{try} // 0, $NCHK{fill} // 0, $NCHK{sort} // 0, $NCHK{checks} // 0, $NCHK{sim} // 0, $NCHK{think} // 0,
    scalar(keys %{ { map { %{ $TUSED{$_} } } keys %TUSED } }), scalar(keys %TERM);
