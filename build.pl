#!/usr/bin/env perl
# ======================================================================
#  ケースで学ぶ簿記3級 ― 静的サイトジェネレーター（Perl 5 / 追加モジュール不要）
#
#  使い方:   perl build.pl          （Git Bash などから実行）
#  入力:     _src/book.txt   … 章の並び（1行1ID）
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
#    データ（入れ子不可）:
#      journal  … 「借方科目 金額 | 貸方科目 金額」（貸借一致を自動検証）
#      taccount … 「摘要 金額 | 摘要 金額」、合計行は「= 金額 | 金額」
#      table    … パイプ区切り。1行目が見出し。"!!" 行で2段見出し（"受入*3" = 3列結合）
#                 "|=" で始まる行は強調行
#      boxes    … 「H 左見出し | 右見出し」「L|R 色 数値 ラベル」（色: a l e x r p s z k d）
#      steps / kpi / timeline … 「項目 | 説明 | 補足」
#      toc      … 目次（表紙用）
# ======================================================================
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));
use FindBin qw($Bin);

my $ROOT     = $Bin;
my $SRC      = "$ROOT/_src";
my $OUT      = "$ROOT/public";    # 公開用の出力先（Cloudflare Pages の Build output directory）
mkdir $OUT or die "出力先を作成できません $OUT: $!\n" unless -d $OUT;
my $BOOK     = 'ケースで学ぶ簿記3級';
my $BOOK_SUB = '身近な会社の数字で、日商簿記3級の全範囲を学ぶ';

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
    $s =~ s{\{\{(\w+):(.+?)\}\}}{
        my $c = $BADGE{$1} // $BADGE{tag};
        qq{<span class="mx-0.5 inline-block whitespace-nowrap rounded px-1.5 py-1 align-[0.1em] text-[11px] font-bold leading-none $c">$2</span>}
    }ge;
    $s =~ s{\^\^(.+?)\^\^}{<span class="text-[11px] font-normal leading-tight text-gray-500">$1</span>}g;    # ^^小さな補足^^
    $s =~ s{\*\*(.+?)\*\*}{<strong class="font-bold">$1</strong>}g;
    $s =~ s{==(.+?)==}{<mark class="rounded-sm bg-yellow-200 px-0.5 text-gray-900">$1</mark>}g;
    my $red = $DARK ? 'text-red-400' : 'text-red-600';
    $s =~ s{!!(.+?)!!}{<span class="font-bold $red">$1</span>}g;
    $s =~ s{\[([^\]]+?)\]\(([^)\s]+)\)}{<a href="$2" class="whitespace-nowrap font-bold underline decoration-amber-400 decoration-2 underline-offset-4 hover:text-amber-700">$1</a>}g;
    return $s;
}

# 金額文字列 → 数値（数値でなければ undef）
sub amt {
    my $s = shift;
    return undef unless defined $s && $s =~ /\d/;
    return undef if $s =~ /[?？□（(ア-ン]/;
    my $neg = ($s =~ /^\s*[△▲\-−]/) ? -1 : 1;
    (my $d = $s) =~ s/[^\d.]//g;
    return undef if $d eq '';
    return $neg * $d;
}

sub is_num {
    my $s = shift // '';
    return $s =~ /^\s*[@＠¥￥△▲\-−+(（]*\s*\d[\d,.]*\s*[)）%]*\s*(?:円|万円|億円|千円|kg|g|個|台|本|人|名|か月|ヶ月|年|日|件|回|食|杯|枚|席|口|%|倍|ポイント|pt)?\s*$/;
}

# 「勘定科目 金額」を分解（金額は末尾の数値。穴埋め用の「？」「（ア）」も可）
sub side {
    my $t = trim(shift);
    return ('', '') if $t eq '';
    if ($t =~ /^(.*\S)\s+(\S+)$/) {
        my ($acct, $v) = ($1, $2);
        return ($acct, $v) if is_num($v) || $v =~ /^(?:[?？□]+|（.*）|\(.*\))$/;
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
my %RAW       = map { $_ => 1 } qw(journal taccount table boxes steps kpi timeline toc);
my %CONTAINER = map { $_ => 1 } qw(mystery theory danger cfo answer exam next solve scene case example problem quiz summary point formula tgrid note);

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

# ---------------------------------------------------------------- render: lines
sub r_h {
    my ($lv, $t) = @_;
    my $c = $DARK ? 'text-white' : 'text-gray-900';
    if ($lv == 2) {
        $SECN++;
        my $id = "$CUR-s$SECN";
        push @{ $TOC{$CUR} }, [$id, $t];
        my $n = sprintf('%02d', $SECN);
        return qq{<h2 id="$id" class="mb-6 mt-16 flex scroll-mt-20 items-baseline gap-3 font-serif text-[1.4rem] font-black leading-snug $c sm:text-[1.65rem]">}
             . qq{<span class="flex-none font-sans text-sm font-black tracking-widest text-amber-600">$n</span><span>} . inl($t) . '</span></h2>';
    }
    if ($lv == 3) {
        my $b = $DARK ? 'border-amber-400' : 'border-gray-900';
        return qq{<h3 class="mb-4 mt-10 border-l-4 $b pl-3 text-lg font-bold leading-snug $c">} . inl($t) . '</h3>';
    }
    return qq{<h4 class="mb-3 mt-8 font-bold leading-snug $c">} . inl($t) . '</h4>';
}

sub r_ul {
    my $items = shift;
    my $check = $CTX{check};
    my $html  = $check ? '<ul class="my-5 space-y-3">' : '<ul class="my-5 list-disc space-y-2 pl-6 marker:text-gray-400">';
    my $sub   = 0;
    for my $i (0 .. $#$items) {
        my ($lv, $t) = @{ $items->[$i] };
        if ($lv == 0 || $i == 0) {
            if ($sub) { $html .= '</ul>'; $sub = 0; }
            $html .= '</li>' if $i > 0;
            if ($check) {
                $html .= '<li class="flex gap-3 leading-[1.8]"><span class="mt-1 flex h-5 w-5 flex-none items-center justify-center rounded-full bg-emerald-500 text-[11px] font-black text-white">✓</span><span>' . inl($t) . '</span>';
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

sub rn {
    my ($nodes, $parent) = @_;
    $parent //= '';
    my $h = '';
    for my $n (@$nodes) {
        my $t = $n->{t};
        if    ($t eq 'p')     { $h .= '<p class="my-5 leading-[1.95]">' . inl($n->{text}) . '</p>'; }
        elsif ($t eq 'h')     { $h .= r_h($n->{level}, $n->{text}); }
        elsif ($t eq 'hr')    { $h .= '<hr class="my-14 h-px border-0 bg-gradient-to-r from-transparent via-gray-300 to-transparent">'; }
        elsif ($t eq 'ul')    { $h .= r_ul($n->{items}); }
        elsif ($t eq 'ol')    { $h .= '<ol class="my-5 list-decimal space-y-2 pl-6 marker:font-bold marker:text-gray-400">' . join('', map { '<li class="leading-[1.85]">' . inl($_) . '</li>' } @{ $n->{items} }) . '</ol>'; }
        elsif ($t eq 'quote') { $h .= '<blockquote class="my-6 border-l-4 border-gray-300 pl-4 font-serif text-gray-600">' . join('', map { '<p class="my-2 leading-[1.9]">' . inl($_) . '</p>' } @{ $n->{lines} }) . '</blockquote>'; }
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
sub r_box {
    my ($n, $parent) = @_;
    my ($name, $a, $k) = @$n{qw(name arg kids)};
    local $DARK = ($name eq 'mystery') ? 1 : 0;
    my $title = sub {
        my $cls = shift;
        return $a ne '' ? qq{<p class="$cls">} . inl($a) . '</p>' : '';
    };

    if ($name eq 'mystery') {
        return qq{<section class="relative my-10 overflow-hidden bg-gray-900 text-white p-6 rounded-lg shadow-lg sm:p-8">}
             . qq{<div aria-hidden="true" class="pointer-events-none absolute -right-3 -top-10 select-none font-serif text-[10rem] font-black leading-none text-white/5">?</div>}
             . qq{<p class="relative mb-4 flex items-center gap-2 text-[11px] font-bold tracking-[0.3em] text-amber-400"><span class="inline-block h-2 w-2 animate-pulse rounded-full bg-amber-400"></span>QUESTION ― この章の問い</p>}
             . ($a ne '' ? '<h2 class="relative mb-5 font-serif text-xl font-black leading-snug text-white sm:text-2xl">' . inl($a) . '</h2>' : '')
             . '<div class="relative">' . inner($k, $name) . '</div></section>';
    }
    if ($name eq 'theory') {
        return qq{<aside class="my-8 rounded-r-lg border-l-4 border-blue-500 bg-blue-50 p-5 sm:p-6">}
             . label('text-blue-600', 'ACCOUNTING THEORY ― 重要理論')
             . $title->('mb-3 text-lg font-bold leading-snug text-blue-950')
             . inner($k, $name) . '</aside>';
    }
    if ($name eq 'danger') {
        return qq{<aside class="my-8 rounded-lg border border-t-4 border-red-200 border-t-red-600 bg-red-50 p-5 sm:p-6">}
             . label('text-red-700', '⚠ RISK ― 経営の落とし穴')
             . $title->('mb-3 text-lg font-bold leading-snug text-red-950')
             . inner($k, $name) . '</aside>';
    }
    if ($name eq 'cfo') {
        return qq{<section class="my-8 rounded-lg border-2 border-amber-300 bg-amber-50 p-5 sm:p-6">}
             . label('text-amber-700', 'THINK ― 判断してみよう')
             . $title->('mb-3 text-lg font-bold leading-snug text-amber-950')
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'answer') {
        my $lab = $a ne '' ? $a : ($parent eq 'cfo' ? '考え方の例を見る' : '解答・解説を見る');
        return qq{<details class="group mt-5 rounded-lg border border-gray-300 bg-white text-gray-800 shadow-sm">}
             . qq{<summary class="flex cursor-pointer select-none items-center justify-between gap-3 rounded-lg px-4 py-3 font-bold text-gray-900 hover:bg-gray-50"><span>} . inl($lab)
             . qq{</span><span class="flex-none text-xs text-gray-400 transition-transform group-open:rotate-180">▼</span></summary>}
             . qq{<div class="border-t border-gray-200 px-4 py-4 sm:px-5">} . inner($k, $name) . '</div></details>';
    }
    if ($name eq 'exam') {
        return qq{<aside class="my-8 rounded-lg border border-emerald-200 bg-emerald-50 p-5 sm:p-6">}
             . label('text-emerald-700', 'EXAM HACK ― 試験の急所')
             . $title->('mb-3 text-lg font-bold leading-snug text-emerald-950')
             . inner($k, $name) . '</aside>';
    }
    if ($name eq 'next') {
        return qq{<aside class="my-8 rounded-lg border border-violet-200 bg-violet-50 p-5 sm:p-6">}
             . label('text-violet-700', 'NEXT STEP ― 2級・1級・実務へのつながり')
             . $title->('mb-3 text-lg font-bold leading-snug text-violet-950')
             . inner($k, $name) . '</aside>';
    }
    if ($name eq 'solve') {
        return qq{<section class="my-12 rounded-lg border-2 border-gray-900 bg-white p-6 shadow-[6px_6px_0_0_#111827] sm:p-8">}
             . label('text-amber-600', 'ANSWER ― 答え合わせ')
             . $title->('mb-4 font-serif text-xl font-black leading-snug text-gray-900 sm:text-2xl')
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'scene') {
        return qq{<div class="my-8 border-l-2 border-gray-400 pl-5 font-serif text-gray-700">}
             . label('font-sans text-gray-400', 'SCENE')
             . $title->('mb-2 font-bold text-gray-900')
             . inner($k, $name) . '</div>';
    }
    if ($name eq 'case') {
        return qq{<section class="my-8 overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm">}
             . qq{<div class="flex flex-wrap items-center gap-x-3 gap-y-1 bg-gray-900 px-5 py-3 text-white"><span class="text-[11px] font-bold tracking-[0.3em] text-amber-400">CASE FILE</span><span class="font-bold">} . inl($a) . '</span></div>'
             . qq{<div class="p-5 sm:p-6">} . inner($k, $name) . '</div></section>';
    }
    if ($name eq 'example') {
        return qq{<section class="my-8 rounded-lg border border-gray-300 bg-white p-5 shadow-sm sm:p-6">}
             . qq{<p class="mb-3 flex flex-wrap items-baseline gap-2"><span class="rounded bg-gray-900 px-2 py-0.5 text-xs font-bold text-white">例題</span><span class="font-bold leading-snug text-gray-900">} . inl($a) . '</span></p>'
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'problem') {
        $CTX{qn}++;
        my $no = $CTX{qn};
        return qq{<section class="rounded-lg border border-gray-300 bg-white p-5 shadow-sm sm:p-6">}
             . qq{<p class="mb-3 flex flex-wrap items-baseline gap-2"><span class="rounded bg-amber-500 px-2 py-0.5 text-xs font-black text-white">問$no</span><span class="font-bold leading-snug text-gray-900">} . inl($a) . '</span></p>'
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'quiz') {
        $CTX{qn} = 0;
        return '<div class="my-8 space-y-5">' . rn($k, $name) . '</div>';
    }
    if ($name eq 'summary') {
        local $CTX{check} = 1;
        return qq{<section class="my-14 rounded-lg border-t-4 border-gray-900 bg-white p-6 shadow-sm sm:p-8">}
             . label('text-gray-400', 'SUMMARY')
             . '<p class="mb-4 font-serif text-xl font-black text-gray-900">' . ($a ne '' ? inl($a) : 'この章のまとめ') . '</p>'
             . inner($k, $name) . '</section>';
    }
    if ($name eq 'point') {
        return qq{<aside class="my-6 rounded-lg border border-yellow-300 bg-yellow-50 p-4 sm:p-5">}
             . label('text-yellow-700', 'POINT')
             . $title->('mb-2 font-bold leading-snug text-gray-900')
             . inner($k, $name) . '</aside>';
    }
    if ($name eq 'formula') {
        return qq{<div class="my-8 rounded-lg border-2 border-dashed border-blue-300 bg-white px-4 py-5 text-center">}
             . label('text-blue-500', 'FORMULA ― 公式')
             . $title->('mb-2 text-sm font-bold text-gray-500')
             . '<div class="text-lg font-black leading-relaxed text-gray-900 sm:text-xl [&_p]:my-2">' . inner($k, $name) . '</div></div>';
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
    );
    return $f{ $n->{name} }->($n->{arg}, $n->{lines}, $n->{line});
}

sub caption_journal {
    my $arg = shift;
    return '' if $arg eq '';
    return qq{<figcaption class="mb-2 flex items-start gap-2 text-sm leading-relaxed text-gray-700"><span class="mt-0.5 flex-none rounded bg-gray-800 px-1.5 py-0.5 text-[10px] font-bold tracking-wider text-white">仕訳</span><span>} . inl($arg) . '</span></figcaption>';
}

sub r_journal {
    my ($arg, $lines, $ln) = @_;
    my ($dsum, $csum, $numeric, $rows) = (0, 0, 1, '');
    for my $l (@$lines) {
        next if $l =~ /^\s*$/;
        if ($l !~ /\|/) {
            $rows .= qq{<tr><td colspan="4" class="px-3 py-3 text-center font-bold text-gray-700">} . inl(trim($l)) . '</td></tr>';
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
        $rows .= '<tr class="even:bg-slate-50">'
               . '<td class="border-t border-gray-200 px-2 sm:px-3 py-2 align-top font-medium text-gray-900">' . inl($da) . '</td>'
               . '<td class="whitespace-nowrap border-r-2 border-t border-gray-200 border-r-gray-300 px-2 sm:px-3 py-2 text-right align-top tabular-nums text-gray-900">' . inl($dv) . '</td>'
               . '<td class="border-t border-gray-200 px-2 sm:px-3 py-2 align-top font-medium text-gray-900">' . inl($ca) . '</td>'
               . '<td class="whitespace-nowrap border-t border-gray-200 px-2 sm:px-3 py-2 text-right align-top tabular-nums text-gray-900">' . inl($cv) . '</td></tr>';
    }
    $NCHK{journal}++ if $numeric && ($CTX{mode} // '') ne 'all';
    if ($numeric && abs($dsum - $csum) > 0.001) {
        push @WARN, "[$CUR:$ln] 仕訳の貸借不一致「$arg」 借方 $dsum ≠ 貸方 $csum";
    }
    return qq{<figure class="my-6">} . caption_journal($arg)
         . qq{<div class="overflow-x-auto rounded-lg border border-gray-300 bg-white shadow-sm"><table class="w-full min-w-[19rem] border-collapse text-sm"><thead><tr>}
         . qq{<th class="bg-blue-50 px-3 py-2 text-left text-xs font-bold text-blue-800">借方科目</th>}
         . qq{<th class="border-r-2 border-r-gray-300 bg-blue-50 px-3 py-2 text-right text-xs font-bold text-blue-800">金額</th>}
         . qq{<th class="bg-rose-50 px-3 py-2 text-left text-xs font-bold text-rose-800">貸方科目</th>}
         . qq{<th class="bg-rose-50 px-3 py-2 text-right text-xs font-bold text-rose-800">金額</th>}
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
    my $td  = 'px-2 py-1.5 align-top text-gray-700';
    my $tdn = 'whitespace-nowrap px-2 py-1.5 text-right align-top tabular-nums text-gray-900';
    my $tc  = 'whitespace-nowrap border-b-[3px] border-t border-double border-gray-500 px-2 py-1.5 text-right font-bold tabular-nums text-gray-900';
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
               . qq{<td class="$td">} . inl($c[0]) . '</td>'
               . qq{<td class="$tdn border-r-2 border-gray-900">} . inl($c[1]) . '</td>'
               . qq{<td class="$td">} . inl($c[2]) . '</td>'
               . qq{<td class="$tdn">} . inl($c[3]) . '</td></tr>';
    }
    return qq{<figure class="my-6 rounded-lg border border-gray-300 bg-white p-3 shadow-sm sm:p-4"><div class="overflow-x-auto"><table class="w-full min-w-[17rem] border-collapse text-sm">}
         . qq{<thead><tr><th colspan="4" class="border-b-2 border-gray-900 pb-1.5 text-center text-base font-black text-gray-900">} . inl($arg) . '</th></tr>'
         . qq{<tr class="text-[10px] font-bold tracking-wider"><th colspan="2" class="border-r-2 border-gray-900 px-2 pt-1 text-left text-blue-700">借方</th><th colspan="2" class="px-2 pt-1 text-right text-rose-700">貸方</th></tr></thead>}
         . "<tbody>$body</tbody></table></div></figure>";
}

sub r_table {
    my ($arg, $lines, $ln) = @_;
    my ($compact, $sumchk) = (0, 0);
    while ($arg =~ s/^(compact|sum)\s+//) {    # compact: 帳簿など列の多い表 / sum: 最終の強調行＝縦計を検証
        $compact = 1 if $1 eq 'compact';
        $sumchk  = 1 if $1 eq 'sum';
    }
    my $pad = $compact ? "px-1.5 py-1.5 text-xs whitespace-nowrap" : "px-2 py-2 sm:px-3";
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
            next if $v eq '';
            $ne++;
            $nn++ if is_num($v);
        }
        $numcol[$c] = ($ne && $nn / $ne >= 0.6) ? 1 : 0;
    }
    my $thc = "border-gray-600 bg-gray-800 $pad text-xs font-bold text-white";
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
        my $trc = $emph ? 'bg-amber-50 font-bold' : 'even:bg-slate-50';
        $tbody .= qq{<tr class="$trc">};
        for my $i (0 .. $#c) {
            my $v  = $c[$i];
            my $nm = is_num($v) || ($numcol[$i] && $v =~ /^\s*[-―－]\s*$/);
            my $cls = $nm ? 'whitespace-nowrap text-right tabular-nums' : 'min-w-[3.5em] text-left';
            my $bl  = @group && $i > 0 ? ' border-l border-gray-200' : '';
            $tbody .= qq{<td class="border-t border-gray-200 $pad align-top text-gray-800 $cls$bl">} . inl($v) . '</td>';
        }
        $tbody .= '</tr>';
    }
    my $cap = $arg ne '' ? '<figcaption class="mb-2 text-sm font-bold text-gray-700">' . inl($arg) . '</figcaption>' : '';
    my $hint = $compact ? '<p class="mt-1.5 text-right text-[11px] text-gray-400 sm:hidden">表は横にスクロールできます →</p>' : '';
    return qq{<figure class="my-6">$cap<div class="overflow-x-auto rounded-lg border border-gray-300 bg-white shadow-sm"><table class="w-full border-collapse text-sm"><thead>$thead</thead><tbody>$tbody</tbody></table></div>$hint</figure>};
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
            qq{<div class="flex flex-col items-center justify-center rounded-md px-2 text-center text-xs font-bold leading-snug sm:text-sm $cc" style="height:${h}px">} . inl($t) . '</div>';
        } @_;
    };
    my $hd = $H ? qq{<div class="mb-1.5 grid grid-cols-2 gap-1.5 text-center text-[11px] font-bold text-gray-500"><div>} . inl($H->[0]) . '</div><div>' . inl($H->[1] // '') . '</div></div>' : '';
    return qq{<figure class="my-8"><div class="mx-auto max-w-md">$hd<div class="grid grid-cols-2 items-start gap-1.5"><div class="flex flex-col gap-1.5">}
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
        $li .= qq{<li class="relative pb-6 pl-12 last:pb-0 before:absolute before:bottom-1 before:left-[15px] before:top-9 before:w-0.5 before:bg-gray-300 last:before:hidden">}
             . qq{<span class="absolute left-0 top-0 flex h-8 w-8 items-center justify-center rounded-full bg-gray-900 text-sm font-black text-white">$n</span>}
             . '<p class="pt-1 font-bold leading-snug text-gray-900">' . inl($t) . '</p>'
             . (defined $d && $d ne '' ? '<p class="mt-1 text-sm leading-relaxed text-gray-600">' . inl($d) . '</p>' : '')
             . '</li>';
    }
    my $cap = $arg ne '' ? '<p class="mb-5 font-bold text-gray-900">' . inl($arg) . '</p>' : '';
    return qq{<div class="my-8 rounded-lg border border-gray-200 bg-white p-5 shadow-sm sm:p-6">$cap<ol>$li</ol></div>};
}

sub r_kpi {
    my ($arg, $lines) = @_;
    my $tiles = '';
    for my $l (@$lines) {
        next unless $l =~ /\S/;
        my ($k, $v, $nt) = map { trim($_) } split /\|/, $l, 3;
        $tiles .= '<div class="rounded-lg border border-gray-200 bg-gray-50 p-3">'
                . '<p class="text-[11px] font-bold leading-snug text-gray-500">' . inl($k) . '</p>'
                . '<p class="mt-1 text-lg font-black leading-tight tabular-nums text-gray-900 sm:text-xl">' . inl($v // '') . '</p>'
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
        my $dot = 'bg-amber-500';
        if ($d =~ s/^!//) { $dot = 'bg-red-600'; }
        $li .= '<li class="relative pl-6">'
             . qq{<span class="absolute -left-[7px] top-1.5 h-3 w-3 rounded-full $dot ring-4 ring-white"></span>}
             . '<p class="text-xs font-bold tracking-wider text-gray-500">' . inl($d) . '</p>'
             . '<p class="font-bold leading-snug text-gray-900">' . inl($t // '') . '</p>'
             . (defined $x && $x ne '' ? '<p class="mt-0.5 text-sm leading-relaxed text-gray-600">' . inl($x) . '</p>' : '')
             . '</li>';
    }
    my $cap = $arg ne '' ? '<p class="mb-5 font-bold text-gray-900">' . inl($arg) . '</p>' : '';
    return qq{<div class="my-8 rounded-lg border border-gray-200 bg-white p-5 shadow-sm sm:p-6">$cap<ol class="ml-1.5 space-y-5 border-l-2 border-gray-200">$li</ol></div>};
}

# ---------------------------------------------------------------- toc / nav
sub href_for {
    my ($id, $mode) = @_;
    return $mode eq 'all' ? "#$id" : "$id.html";
}

sub r_toc {
    my $html = qq{<div id="toc" class="scroll-mt-20">};
    my $part = "\0";
    my $open = 0;
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
    $html .= '</div></section>' if $open;
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
        my $active = ($id eq ($cur // '')) ? 'bg-amber-50 text-amber-900' : 'text-gray-700 hover:bg-gray-50';
        my $href = href_for($id, $mode);
        $html .= qq{<a href="$href" class="flex gap-2 rounded-md px-3 py-2 text-sm $active"><span class="w-14 flex-none font-bold text-gray-400">} . esc($m->{num}) . '</span><span class="font-medium">' . esc($m->{subtitle}) . '</span></a>';
    }
    return $html;
}

# ---------------------------------------------------------------- page shell
sub head_html {
    my ($title, $desc) = @_;
    my $h = <<'HTML';
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<meta name="theme-color" content="#111827">
<title>__TITLE__</title>
<meta name="description" content="__DESC__">
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = {
    theme: {
      extend: {
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
  summary { list-style: none; }
  summary::-webkit-details-marker { display: none; }
  table { font-variant-numeric: tabular-nums; }
  @media print {
    .no-print { display: none !important; }
    body { background: #fff !important; }
    section, aside, figure, details { break-inside: avoid; }
  }
</style>
</head>
HTML
    my ($t, $d) = (esc($title), esc($desc));
    $h =~ s/__TITLE__/$t/;
    $h =~ s/__DESC__/$d/;
    return $h;
}

sub site_header {
    my ($cur, $mode) = @_;
    my $label = ($cur && $META{$cur}) ? esc($META{$cur}{num}) : '';
    my $home  = $mode eq 'all' ? '#top' : 'index.html';
    return qq{<header class="no-print sticky top-0 z-40 border-b border-gray-200 bg-white/90 backdrop-blur">}
         . qq{<div class="mx-auto flex h-14 max-w-3xl items-center justify-between gap-3 px-4 sm:px-6">}
         . qq{<a href="$home" class="flex min-w-0 items-center gap-2"><span class="flex h-7 w-7 flex-none items-center justify-center rounded bg-gray-900 font-serif text-sm font-black text-amber-400">簿</span><span class="truncate text-sm font-black text-gray-900 sm:text-base">$BOOK</span></a>}
         . qq{<div class="flex flex-none items-center gap-2">}
         . ($label ? qq{<span class="hidden text-xs font-bold text-gray-400 sm:inline">$label</span>} : '')
         . qq{<details data-dropdown class="relative"><summary class="flex cursor-pointer select-none items-center gap-1.5 rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm font-bold text-gray-700 hover:bg-gray-50">目次<span class="text-[10px] text-gray-400">▼</span></summary>}
         . qq{<nav class="absolute right-0 mt-2 max-h-[75vh] w-[min(22rem,calc(100vw-2rem))] overflow-y-auto rounded-lg border border-gray-200 bg-white p-2 shadow-xl">}
         . ($mode eq 'all'
              ? qq{<a href="index.html" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">章ごとのページ版へ</a>}
              : qq{<a href="index.html" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">表紙・目次</a><a href="all.html" class="block rounded-md px-3 py-2 text-sm font-bold text-gray-900 hover:bg-gray-50">全章一気読み版（1ファイル）</a>})
         . nav_list($cur, $mode)
         . qq{</nav></details></div></div></header>\n};
}

sub footer_html {
    return <<'HTML';
<footer class="mt-16 border-t border-gray-200 bg-white">
  <div class="mx-auto max-w-3xl space-y-2 px-4 py-10 text-xs leading-relaxed text-gray-500 sm:px-6">
    <p class="font-bold text-gray-700">ケースで学ぶ簿記3級 ― 身近な会社の数字で、日商簿記3級の全範囲を学ぶ</p>
    <p>本書に登場する企業・人物・数値は、学習のために設計した架空のものです。実在の企業・団体・商品とは関係ありません。</p>
    <p>出題範囲は日本商工会議所「商工会議所簿記検定試験 出題区分表」（2022年度適用版。2026年度の試験まで適用）に準拠し、2027年4月以降の試験に適用される改定（暫定版）の要点も併記しています。受験前に必ず日本商工会議所の公式情報をご確認ください。</p>
  </div>
</footer>
HTML
}

sub script_html {
    return <<'HTML';
<script>
(() => {
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
  addEventListener('beforeprint', () => document.querySelectorAll('main details').forEach((d) => (d.open = true)));
})();
</script>
HTML
}

sub page_html {
    my (%o) = @_;
    return head_html($o{title}, $o{desc})
         . qq{<body id="top" class="bg-stone-50 font-sans text-[16px] text-gray-800 antialiased sm:text-[17px]">\n}
         . qq{<div id="progress" class="no-print fixed left-0 top-0 z-50 h-1 w-0 bg-amber-500"></div>\n}
         . site_header($o{cur}, $o{mode})
         . ($o{top} // '')
         . qq{<main class="mx-auto max-w-3xl px-4 pb-10 sm:px-6">\n$o{main}\n</main>\n}
         . footer_html()
         . script_html()
         . "</body>\n</html>\n";
}

# ---------------------------------------------------------------- chapter assembly
sub chapter_hero {
    my $id = shift;
    my $m  = $META{$id};
    my $h  = qq{<header class="pt-10 sm:pt-14">};
    $h .= '<p class="text-[11px] font-bold tracking-[0.25em] text-gray-400">' . esc($m->{part}) . '</p>' if $m->{part};
    $h .= '<div class="mt-5 flex flex-wrap items-center gap-3"><span class="rounded bg-gray-900 px-3 py-1 text-sm font-black text-white">' . esc($m->{num}) . '</span>'
        . '<span class="text-sm font-bold text-gray-500">' . esc($m->{subtitle}) . '</span></div>';
    $h .= '<h1 class="mt-5 font-serif text-[1.75rem] font-black leading-[1.4] text-gray-900 sm:text-[2.4rem]">' . esc($m->{title}) . '</h1>';
    $h .= '<p class="mt-5 leading-[1.9] text-gray-600">' . inl($m->{lead}) . '</p>' if $m->{lead};
    my @chips;
    push @chips, '読了目安 ' . esc($m->{time}) if $m->{time};
    push @chips, '難易度 ' . esc($m->{level}) if $m->{level};
    push @chips, esc($m->{scope}) if $m->{scope};
    $h .= '<div class="mt-6 flex flex-wrap gap-2 text-xs font-bold text-gray-600">' . join('', map { qq{<span class="rounded-full border border-gray-300 bg-white px-3 py-1">$_</span>} } @chips) . '</div>' if @chips;
    $h .= '</header>';
    if (@{ $m->{goals} }) {
        $h .= qq{<section class="mt-8 rounded-lg border border-gray-200 bg-white p-5 shadow-sm sm:p-6">}
            . label('text-amber-600', 'GOALS')
            . '<p class="mb-3 font-bold text-gray-900">この章で学ぶこと</p><ul class="space-y-2">'
            . join('', map { '<li class="flex gap-3 text-[15px] leading-relaxed"><span class="mt-0.5 flex-none font-black text-amber-500">▸</span><span>' . inl($_) . '</span></li>' } @{ $m->{goals} })
            . '</ul></section>';
    }
    if ($TOC{$id} && @{ $TOC{$id} }) {
        $h .= qq{<details class="group mt-4 rounded-lg border border-gray-200 bg-white shadow-sm"><summary class="flex cursor-pointer select-none items-center justify-between px-5 py-3 text-sm font-bold text-gray-700">この章の目次<span class="text-xs text-gray-400 transition-transform group-open:rotate-180">▼</span></summary><ol class="space-y-1.5 border-t border-gray-100 px-5 py-4 text-sm">};
        my $i = 0;
        for my $s (@{ $TOC{$id} }) {
            $i++;
            $h .= sprintf('<li><a href="#%s" class="flex gap-3 text-gray-700 hover:text-amber-700"><span class="w-6 flex-none font-bold text-amber-600">%02d</span><span>%s</span></a></li>', $s->[0], $i, inl($s->[1]));
        }
        $h .= '</ol></details>';
    }
    return $h;
}

sub chapter_nav {
    my $idx = shift;
    my @ids = @{ $CTX{ids} };
    my $h = '<nav class="no-print mt-16 grid gap-3 sm:grid-cols-2">';
    if ($idx > 0) {
        my $p = $META{ $ids[$idx - 1] };
        $h .= qq{<a href="$ids[$idx-1].html" class="group rounded-lg border border-gray-300 bg-white p-4 transition hover:border-gray-900"><p class="text-xs font-bold text-gray-400">← 前へ　} . esc($p->{num}) . '</p><p class="mt-1 font-bold leading-snug text-gray-900 group-hover:underline">' . esc($p->{subtitle}) . '</p></a>';
    }
    if ($idx < $#ids) {
        my $n = $META{ $ids[$idx + 1] };
        $h .= qq{<a href="$ids[$idx+1].html" class="group rounded-lg border border-gray-900 bg-gray-900 p-4 text-right transition hover:bg-gray-800 sm:col-start-2"><p class="text-xs font-bold text-amber-400">次へ　} . esc($n->{num}) . ' →</p><p class="mt-1 font-bold leading-snug text-white group-hover:underline">' . esc($n->{subtitle}) . '</p></a>';
    }
    else {
        $h .= qq{<a href="index.html" class="group rounded-lg border border-gray-900 bg-gray-900 p-4 text-right transition hover:bg-gray-800 sm:col-start-2"><p class="text-xs font-bold text-amber-400">表紙へ戻る →</p><p class="mt-1 font-bold leading-snug text-white group-hover:underline">目次・全体像</p></a>};
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
    $TOC{$id} = [];
    my $i = 0;
    my $nodes = parse($BODY{$id}, \$i, 0);
    return rn($nodes, '');
}

# ---------------------------------------------------------------- main
my @ALL = grep { /\S/ && !/^#/ } map { trim($_) } split /\n/, slurp("$SRC/book.txt");
my @IDS = grep { -e "$SRC/$_.txt" } @ALL;
print "未作成（スキップ）: ", join(', ', grep { !-e "$SRC/$_.txt" } @ALL), "\n" if @IDS < @ALL;
$CTX{ids} = \@IDS;
read_source($_) for @IDS;
read_source('index');

$RENDERED{$_} = render_body($_) for @IDS;

my $count = 0;
for my $i (0 .. $#IDS) {
    my $id = $IDS[$i];
    my $m  = $META{$id};
    local $CTX{mode} = 'page';
    my $main = chapter_hero($id) . "\n" . $RENDERED{$id} . "\n" . chapter_nav($i);
    spew("$OUT/$id.html", page_html(
        title => "$m->{num} $m->{subtitle} | $BOOK",
        desc  => "$m->{title} ― $m->{subtitle}。$BOOK_SUB",
        cur   => $id,
        mode  => 'page',
        main  => $main,
    ));
    $count++;
}

# 表紙
sub cover_top {
    my $mode = shift;
    my $m    = $META{index};
    my $start = $mode eq 'all' ? "#$IDS[0]" : "$IDS[0].html";
    return qq{<section class="relative overflow-hidden bg-gray-900 text-white">}
         . qq{<div aria-hidden="true" class="pointer-events-none absolute inset-0 opacity-[0.08]"><div class="absolute left-0 right-0 top-28 h-px bg-white"></div><div class="absolute bottom-0 left-1/2 top-28 w-px bg-white"></div>}
         . qq{<div class="absolute left-[12%] top-12 font-serif text-5xl font-black sm:text-7xl">借方</div><div class="absolute right-[12%] top-12 font-serif text-5xl font-black sm:text-7xl">貸方</div></div>}
         . qq{<div class="relative mx-auto max-w-3xl px-4 pb-16 pt-24 sm:px-6 sm:pb-24 sm:pt-32">}
         . qq{<p class="text-[11px] font-bold tracking-[0.3em] text-amber-400">日商簿記3級 全範囲対応</p>}
         . qq{<h1 class="mt-6 font-serif text-[2.6rem] font-black leading-[1.2] sm:text-6xl">ケースで学ぶ<br>簿記3級</h1>}
         . qq{<p class="mt-5 text-lg font-bold text-amber-300 sm:text-xl">$BOOK_SUB</p>}
         . ($m->{lead} ? '<p class="mt-6 max-w-xl leading-[1.95] text-gray-300">' . inl($m->{lead}) . '</p>' : '')
         . qq{<div class="mt-9 flex flex-wrap gap-3"><a href="$start" class="rounded-md bg-amber-400 px-5 py-3 font-black text-gray-900 transition hover:bg-amber-300">序章から読む →</a><a href="#toc" class="rounded-md border border-white/30 px-5 py-3 font-bold text-white transition hover:bg-white/10">目次を見る</a></div>}
         . ($m->{note} ? '<p class="mt-8 text-xs leading-relaxed text-gray-400">' . inl($m->{note}) . '</p>' : '')
         . qq{</div></section>\n};
}

{
    local $CTX{mode} = 'page';
    my $body = render_body('index');
    spew("$OUT/index.html", page_html(
        title => "$BOOK ― $BOOK_SUB",
        desc  => $META{index}{lead} // $BOOK_SUB,
        cur   => '',
        mode  => 'page',
        top   => cover_top('page'),
        main  => $body,
    ));
    $count++;
}

# 全章一気読み版
{
    local $CTX{mode} = 'all';
    my $toc  = render_body('index');
    my $main = $toc;
    for my $id (@IDS) {
        $main .= qq{<article id="$id" class="scroll-mt-14 border-t-4 border-gray-900 pt-2 mt-24">} . chapter_hero($id) . "\n" . $RENDERED{$id} . '</article>';
    }
    spew("$OUT/all.html", page_html(
        title => "【全章一気読み版】$BOOK ― $BOOK_SUB",
        desc  => $META{index}{lead} // $BOOK_SUB,
        cur   => '',
        mode  => 'all',
        top   => cover_top('all'),
        main  => $main,
    ));
    $count++;
}

print "生成: $count ファイル\n";
if (@WARN) {
    print "\n⚠ 警告 " . scalar(@WARN) . " 件\n";
    print "  $_\n" for @WARN;
    exit 1;
}
printf "検証OK: 仕訳 %d 件の貸借一致・T字勘定 %d 件の合計・帳簿/試算表など %d 表の縦計・全表の列数\n",
    $NCHK{journal} // 0, $NCHK{taccount} // 0, $NCHK{table} // 0;
