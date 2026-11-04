// ======================================================================
//  ケースで学ぶ簿記3級 ― ページ内で動く演習・シミュレーター・用語・模擬試験
//  build.pl が各ページの末尾に埋め込む（外部ファイルは読み込まない）
//
//  [data-kb="sort"]    ドラッグで分類する演習
//  [data-kb="journal"] 仕訳の入力欄（勘定科目のドラッグ＋金額）
//  [data-kb="fill"]    穴埋め（問題文の空欄に入力・選択）
//  [data-kb="checks"]  当てはまる欄にチェックする表（補助簿の選択など）
//  [data-sim]          数字を動かすシミュレーター
//  .kb-term            勘定科目のポップアップ（付録Aの辞典から）
//  [data-mock]         模擬試験モード（制限時間・自動採点）
//  URL に ?selftest を付けると、すべてを自動で検査して結果を画面上部に出す
// ======================================================================
(() => {
  const $$ = (sel, root) => [...(root || document).querySelectorAll(sel)];
  const SEL = ['ring-2', 'ring-indigo-500', 'ring-offset-1'];
  const OVER = ['ring-2', 'ring-indigo-400'];
  const OK = ['!border-emerald-500', '!bg-emerald-50']; // 元の枠・背景色より優先させる
  const NG = ['!border-red-500', '!bg-red-50'];
  const OKC = ['!bg-emerald-100']; // チェック表のマス
  const NGC = ['!bg-red-100'];
  const fmt = (n) => Number(n).toLocaleString('ja-JP');
  // 入力値 → 数値（空なら null、数値として読めなければ NaN）。全角数字・カンマ・円・△ に対応
  const num = (s) => {
    s = String(s == null ? '' : s)
      .replace(/[０-９．]/g, (d) => String.fromCharCode(d.charCodeAt(0) - 0xfee0))
      .replace(/[,，\s円¥￥]/g, '');
    if (s === '') return null;
    let sign = 1;
    if (/^[△▲\-−－ー]/.test(s)) {
      sign = -1;
      s = s.slice(1);
    }
    return /^(\d+\.?\d*|\.\d+)$/.test(s) ? sign * Number(s) : NaN;
  };
  const widgetOf = (el) => (el && el.closest ? el.closest('[data-kb]') : null);
  const own = (w, sel) => $$(sel, w).filter((el) => widgetOf(el) === w); // 入れ子の演習を除く
  let selected = null;
  let drag = null;
  let suppress = false;

  // ---------------------------------------------------------------- 演習の共通処理
  const select = (chip) => {
    if (selected) selected.classList.remove(...SEL);
    selected = chip && chip !== selected ? chip : null;
    if (selected) selected.classList.add(...SEL);
  };
  const result = (w, text, ok) => {
    const r = own(w, '.kb-result')[0];
    if (!r) return;
    r.textContent = text;
    r.className = 'kb-result text-sm font-bold ' + (ok === true ? 'text-emerald-600' : ok === false ? 'text-red-600' : 'text-gray-500');
  };
  const clearMarks = (w) => {
    own(w, '.kb-chip, .kb-slot, .kb-amt, .kb-blank').forEach((el) => el.classList.remove(...OK, ...NG));
    own(w, '.kb-cell').forEach((el) => el.classList.remove(...OKC, ...NGC));
    own(w, '.kb-mark').forEach((m) => m.remove());
    own(w, '.kb-jres, .kb-colres').forEach((r) => (r.textContent = ''));
    result(w, '', null);
    delete w.dataset.ok;
    w._items = null;
  };
  const setSlot = (slot, acct) => {
    slot.dataset.acct = acct || '';
    slot.textContent = acct || '勘定科目';
    slot.classList.toggle('text-gray-400', !acct);
    slot.classList.toggle('border-dashed', !acct);
    slot.classList.toggle('text-gray-900', !!acct);
    slot.classList.toggle('font-bold', !!acct);
  };
  const place = (chip, target) => {
    const w = widgetOf(chip);
    if (!w || widgetOf(target) !== w) return false;
    if (w.dataset.kb === 'sort') {
      const zone = target.closest('[data-zone]');
      if (!zone) return false;
      (zone.querySelector('.kb-items') || zone).appendChild(chip);
    } else {
      const slot = target.closest('.kb-slot');
      if (!slot) return false;
      setSlot(slot, chip.dataset.acct);
    }
    clearMarks(w);
    return true;
  };
  const rows = (entry, side) => $$('.kb-row[data-side="' + side + '"]', entry);
  const tally = (items) => items.filter((i) => i.ok).length;
  const isPick = (b) => b.classList.contains('kb-pick');
  // 選択式の空欄：値を入れる（未選択なら記号を薄く表示）
  const setPick = (b, v) => {
    const pv = b.querySelector('.kb-pv');
    b.dataset.value = v || '';
    pv.textContent = v || b.dataset.label || '選択';
    pv.classList.toggle('text-indigo-300', !v);
  };

  // 答え合わせ。設問ごとの正誤（模擬試験の採点に使う）を返す
  const check = (w) => {
    clearMarks(w);
    const k = w.dataset.kb;
    let items = [];
    let ok = true;
    if (k === 'sort') {
      const chips = own(w, '.kb-chip');
      let n = 0;
      chips.forEach((c) => {
        const good = c.closest('[data-zone]').dataset.zone === c.dataset.ans;
        c.classList.add(...(good ? OK : NG));
        if (good) n++;
        else {
          const m = document.createElement('span');
          m.className = 'kb-mark ml-1 text-[11px] font-bold text-red-600';
          m.textContent = '→ ' + c.dataset.ans;
          c.appendChild(m);
        }
      });
      ok = n === chips.length;
      // 採点では「使わない語句」以外の分類先を1設問とし、入るべき項目だけが入っていれば正解
      items = own(w, '[data-zone]')
        .filter((z) => z.dataset.zone !== 'pool' && !z.dataset.unused)
        .map((z) => {
          const want = chips.filter((c) => c.dataset.ans === z.dataset.zone);
          const have = chips.filter((c) => c.closest('[data-zone]') === z);
          return { ok: want.length === have.length && want.every((c) => have.includes(c)) };
        });
      result(w, ok ? '全問正解！' : n + ' / ' + chips.length + ' 正解。赤い項目を見直そう', ok);
    } else if (k === 'journal') {
      const ans = JSON.parse(w.dataset.answer);
      own(w, '.kb-entry').forEach((entry, j) => {
        let good = true;
        ['d', 'c'].forEach((side) => {
          const left = ans[j][side].map((e) => e[0] + '|' + e[1]);
          rows(entry, side).forEach((r) => {
            const slot = r.querySelector('.kb-slot');
            const amt = r.querySelector('.kb-amt');
            if (!slot.dataset.acct && !amt.value.trim()) return;
            const i = left.indexOf(slot.dataset.acct + '|' + num(amt.value));
            if (i >= 0) left.splice(i, 1);
            else good = false;
            [slot, amt].forEach((el) => el.classList.add(...(i >= 0 ? OK : NG)));
          });
          if (left.length) good = false;
        });
        entry.dataset.ok = good ? '1' : '0';
        const r = entry.querySelector('.kb-jres');
        r.textContent = good ? '✓ 正解' : '✗ 見直そう';
        r.className = 'kb-jres text-xs font-bold ' + (good ? 'text-emerald-600' : 'text-red-600');
        items.push({ ok: good });
      });
      ok = tally(items) === items.length;
      result(w, ok ? '全問正解！' : '赤い欄を見直そう（足りない行がある場合もある）', ok);
    } else if (k === 'fill') {
      const groups = new Map(); // 同じラベルの空欄はまとめて1設問
      let extra = 0;
      own(w, '.kb-blank').forEach((b, i) => {
        const want = b.dataset.ans;
        let good;
        if (isPick(b)) good = (b.dataset.value || '') === want;
        else if (want === '') {
          // 何も書かないのが正解の欄（記入する場所そのものを問う）
          if (b.value.trim() !== '') {
            extra++;
            b.classList.add(...NG);
          }
          return;
        } else {
          const v = num(b.value);
          good = v !== null && !isNaN(v) && Math.abs(Math.abs(v) - Math.abs(Number(want))) < 1e-6;
        }
        b.classList.add(...(good ? OK : NG));
        const key = b.dataset.label ? 'L' + b.dataset.label : 'i' + i;
        const g = groups.get(key) || { ok: true, ch: [] };
        g.ok = g.ok && good;
        (b.dataset.ch || '').split(' ').filter(Boolean).forEach((c) => g.ch.includes(c) || g.ch.push(c));
        groups.set(key, g);
      });
      items = [...groups.values()]; // { ok, ch }：ch は空欄ごとの「復習する章」（なければ問題全体の章）
      const n = tally(items);
      ok = n === items.length && !extra;
      result(w, ok ? '全問正解！' : n + ' / ' + items.length + ' 正解' + (extra ? '・不要な記入が' + extra + 'か所' : '') + '。赤い欄を見直そう', ok);
    } else if (k === 'checks') {
      const cols = new Map(); // 1列（1つの取引）が1設問
      own(w, '.kb-ck').forEach((cb) => {
        const want = cb.dataset.ans === '1';
        const good = cb.checked === want;
        if (cb.checked || want) cb.closest('.kb-cell').classList.add(...(good ? OKC : NGC));
        cols.set(cb.dataset.col, (cols.has(cb.dataset.col) ? cols.get(cb.dataset.col) : true) && good);
      });
      cols.forEach((g, c) => {
        const r = own(w, '.kb-colres').find((x) => x.dataset.col === c);
        if (!r) return;
        r.textContent = g ? '○' : '×';
        r.classList.remove('text-emerald-600', 'text-red-600');
        r.classList.add(g ? 'text-emerald-600' : 'text-red-600');
      });
      items = [...cols.values()].map((g) => ({ ok: g }));
      const n = tally(items);
      ok = n === items.length;
      result(w, ok ? '全問正解！' : n + ' / ' + items.length + ' 列が正解。赤いマスを見直そう', ok);
    }
    w._items = items;
    w.dataset.ok = ok ? '1' : '0';
    return items;
  };

  const reveal = (w) => {
    const k = w.dataset.kb;
    if (k === 'sort') {
      own(w, '.kb-chip').forEach((c) => {
        const zone = own(w, '[data-zone]').find((z) => z.dataset.zone === c.dataset.ans);
        if (zone) (zone.querySelector('.kb-items') || zone).appendChild(c);
      });
    } else if (k === 'journal') {
      const ans = JSON.parse(w.dataset.answer);
      own(w, '.kb-entry').forEach((entry, j) => {
        ['d', 'c'].forEach((side) => {
          rows(entry, side).forEach((r, i) => {
            const e = ans[j][side][i];
            setSlot(r.querySelector('.kb-slot'), e ? e[0] : '');
            r.querySelector('.kb-amt').value = e ? fmt(e[1]) : '';
          });
        });
      });
    } else if (k === 'fill') {
      own(w, '.kb-blank').forEach((b) => {
        const a = b.dataset.ans;
        if (isPick(b)) setPick(b, a);
        else b.value = a === '' ? '' : fmt(Math.abs(Number(a)));
      });
    } else if (k === 'checks') {
      own(w, '.kb-ck').forEach((cb) => (cb.checked = cb.dataset.ans === '1'));
    }
    clearMarks(w);
    result(w, '正解を表示しました', null);
  };

  const reset = (w) => {
    const k = w.dataset.kb;
    if (k === 'sort') {
      const pool = own(w, '.kb-pool')[0];
      own(w, '.kb-chip')
        .sort((a, b) => a.dataset.i - b.dataset.i)
        .forEach((c) => pool.appendChild(c));
    } else if (k === 'journal') {
      own(w, '.kb-slot').forEach((s) => setSlot(s, ''));
      own(w, '.kb-amt').forEach((i) => (i.value = ''));
    } else if (k === 'fill') {
      own(w, '.kb-blank').forEach((b) => (isPick(b) ? setPick(b, '') : (b.value = '')));
    } else if (k === 'checks') {
      own(w, '.kb-ck').forEach((cb) => (cb.checked = false));
    }
    clearMarks(w);
  };

  // 選択式の空欄の一覧（ページに1つだけ作り、押されたボタンの下に出す）
  let picker = null;
  let pickFor = null;
  const closePick = (refocus) => {
    if (!picker || !pickFor) return;
    picker.classList.add('hidden');
    pickFor.setAttribute('aria-expanded', 'false');
    if (refocus) pickFor.focus();
    pickFor = null;
  };
  const openPick = (b) => {
    if (!picker) {
      picker = document.createElement('div');
      picker.id = 'kb-picker';
      picker.setAttribute('role', 'listbox');
      picker.className = 'absolute z-50 hidden max-h-[50vh] w-max min-w-[9rem] max-w-[calc(100vw-1.5rem)] overflow-y-auto rounded-lg border border-gray-200 bg-white p-1 shadow-xl';
      document.body.appendChild(picker);
    }
    const w = widgetOf(b);
    const opts = JSON.parse(w.dataset.opts || '[]');
    picker.textContent = '';
    picker.setAttribute('aria-label', (b.dataset.label ? '空欄（' + b.dataset.label + '）' : '空欄') + 'の選択肢');
    let focus = null;
    opts.concat(['']).forEach((o) => {
      const it = document.createElement('button');
      it.type = 'button';
      it.setAttribute('role', 'option');
      it.dataset.v = o;
      const on = o !== '' && o === b.dataset.value;
      it.setAttribute('aria-selected', on ? 'true' : 'false');
      it.className = 'kb-pickopt block w-full rounded-md px-3 py-2.5 text-left font-bold hover:bg-indigo-50 focus:bg-indigo-50 focus:outline-none ' + (o === '' ? 'text-sm text-gray-400' : on ? 'text-[15px] bg-indigo-50 text-indigo-700' : 'text-[15px] text-gray-800');
      it.textContent = o === '' ? '（未選択に戻す）' : o;
      picker.appendChild(it);
      if (on || (!focus && o !== '')) focus = on ? it : focus || it;
    });
    picker.classList.remove('hidden');
    const r = b.getBoundingClientRect();
    const pw = picker.offsetWidth;
    const ph = picker.offsetHeight;
    const left = Math.max(scrollX + 12, Math.min(r.left + scrollX, scrollX + document.documentElement.clientWidth - pw - 12));
    let top = r.bottom + scrollY + 6;
    if (r.bottom + ph + 12 > innerHeight && r.top > ph + 72) top = r.top + scrollY - ph - 6;
    picker.style.left = left + 'px';
    picker.style.top = top + 'px';
    pickFor = b;
    b.setAttribute('aria-expanded', 'true');
    if (focus) focus.focus({ preventScroll: true });
  };
  const choose = (b, v) => {
    const w = widgetOf(b);
    own(w, '.kb-pick')
      .filter((o) => o === b || (b.dataset.label && o.dataset.label === b.dataset.label))
      .forEach((o) => {
        setPick(o, v);
        o.classList.remove(...OK, ...NG);
      });
  };
  document.addEventListener('click', (e) => {
    const t = e.target;
    if (!t.closest) return;
    const opt = t.closest('.kb-pickopt');
    if (opt && pickFor) {
      choose(pickFor, opt.dataset.v);
      closePick(true);
      return;
    }
    const b = t.closest('.kb-pick');
    if (b) {
      if (pickFor === b) closePick();
      else openPick(b);
      return;
    }
    if (picker && !picker.contains(t)) closePick();
  });
  document.addEventListener('keydown', (e) => {
    if (!pickFor) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      closePick(true);
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const items = $$('.kb-pickopt', picker);
      const i = items.indexOf(document.activeElement);
      const n = items[(i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length];
      if (n) {
        e.preventDefault();
        n.focus();
      }
    }
  });
  addEventListener('resize', () => closePick());

  // ---------------------------------------------------------------- 操作（クリック・キーボード・ドラッグ・入力）
  document.addEventListener('click', (e) => {
    if (suppress) return;
    const t = e.target;
    const w = widgetOf(t);
    if (!w) return;
    if (t.closest('.kb-check')) return check(w);
    if (t.closest('.kb-reveal')) return reveal(w);
    if (t.closest('.kb-reset')) return reset(w);
    const chip = t.closest('.kb-chip');
    if (chip) return select(chip);
    const slot = t.closest('.kb-slot');
    if (slot) {
      if (selected && widgetOf(selected) === w) {
        place(selected, slot);
        select(null);
      } else if (slot.dataset.acct) {
        setSlot(slot, '');
        clearMarks(w);
      }
      return;
    }
    const zone = t.closest('[data-zone]');
    if (zone && selected && widgetOf(selected) === w) {
      place(selected, zone);
      select(null);
    }
  });
  document.addEventListener('keydown', (e) => {
    if ((e.key === 'Enter' || e.key === ' ') && e.target.matches && e.target.matches('[data-zone][role="button"]')) {
      e.preventDefault();
      e.target.click();
    }
  });
  // 空欄に入力したら、その欄の色を消し、同じラベルの空欄にも同じ値を入れる
  document.addEventListener('input', (e) => {
    const t = e.target;
    const w = widgetOf(t);
    if (!w || !t.classList) return;
    if (t.classList.contains('kb-blank')) {
      t.classList.remove(...OK, ...NG);
      if (t.dataset.label) {
        own(w, '.kb-blank').forEach((o) => {
          if (o !== t && o.dataset.label === t.dataset.label) {
            o.value = t.value;
            o.classList.remove(...OK, ...NG);
          }
        });
      }
    } else if (t.classList.contains('kb-ck')) {
      const cell = t.closest('.kb-cell');
      if (cell) cell.classList.remove(...OKC, ...NGC);
    }
  });

  // ドラッグ（マウス・タッチ共通。HTML5のドラッグはスマホで動かないためポインターで実装）
  document.addEventListener('pointerdown', (e) => {
    const chip = e.target.closest && e.target.closest('.kb-chip');
    if (!chip || e.button > 0) return;
    drag = { chip, x: e.clientX, y: e.clientY, ghost: null, over: null };
  });
  document.addEventListener(
    'pointermove',
    (e) => {
      if (!drag) return;
      if (!drag.ghost) {
        if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) < 6) return;
        const g = drag.chip.cloneNode(true);
        g.classList.remove(...SEL);
        g.classList.add('kb-ghost', 'shadow-lg');
        document.body.appendChild(g);
        drag.ghost = g;
        select(null);
      }
      e.preventDefault();
      drag.ghost.style.left = e.clientX + 'px';
      drag.ghost.style.top = e.clientY + 'px';
      const el = document.elementFromPoint(e.clientX, e.clientY);
      let over = el && el.closest ? el.closest('.kb-slot') || el.closest('[data-zone]') : null;
      if (over && widgetOf(over) !== widgetOf(drag.chip)) over = null;
      if (over !== drag.over) {
        if (drag.over) drag.over.classList.remove(...OVER);
        drag.over = over;
        if (over) over.classList.add(...OVER);
      }
    },
    { passive: false }
  );
  const endDrag = () => {
    if (!drag) return;
    const d = drag;
    drag = null;
    if (!d.ghost) return;
    d.ghost.remove();
    if (d.over) {
      d.over.classList.remove(...OVER);
      place(d.chip, d.over);
    }
    suppress = true;
    setTimeout(() => (suppress = false), 0);
  };
  document.addEventListener('pointerup', endDrag);
  document.addEventListener('pointercancel', () => {
    if (drag && drag.ghost) drag.ghost.remove();
    if (drag && drag.over) drag.over.classList.remove(...OVER);
    drag = null;
  });

  // ---------------------------------------------------------------- シミュレーター
  const COL = { blue: '#2a78d6', orange: '#eb6834', aqua: '#1baf7a', ink: '#52514e' }; // 色覚の検証済み
  const sgn = (n) => (n > 0 ? '+' : n < 0 ? '−' : '±') + fmt(Math.abs(n));
  const out = (root, key, text) => $$('[data-out="' + key + '"]', root).forEach((el) => (el.textContent = text));
  const show = (root, key, text) => $$('[data-show="' + key + '"]', root).forEach((el) => (el.textContent = text));
  const niceStep = (max, n) => {
    const raw = max / n;
    const p = Math.pow(10, Math.floor(Math.log10(raw)));
    return [1, 2, 2.5, 5, 10].map((m) => m * p).find((s) => s >= raw) || raw;
  };

  const SIM = {
    // 第6章：月初在庫200kg、10/8仕入300kg、10/12販売400kg、10/20仕入300kg、10/27販売250kg、売価1,800円
    fifo(v) {
      const d = v.d;
      const p = [1000, 1000 + d, 1000 + 2 * d];
      const sales = 650 * 1800;
      const layers = [[200, p[0]]];
      const issue = (q) => {
        let c = 0;
        while (q > 0 && layers.length) {
          const L = layers[0];
          const t = Math.min(q, L[0]);
          c += t * L[1];
          L[0] -= t;
          q -= t;
          if (!L[0]) layers.shift();
        }
        return c;
      };
      layers.push([300, p[1]]);
      let f = issue(400);
      layers.push([300, p[2]]);
      f += issue(250);
      const fEnd = layers.reduce((s, L) => s + L[0] * L[1], 0);
      // 移動平均法：払出額＝数量×平均単価（円未満四捨五入）、残高の金額は差し引きで求める
      let q = 500;
      let a = 200 * p[0] + 300 * p[1];
      let m = Math.round((400 * a) / q);
      a -= m;
      q = 100 + 300;
      a += 300 * p[2];
      const m2 = Math.round((250 * a) / q);
      m += m2;
      a -= m2;
      return {
        d, p,
        'fifo.sales': sales, 'avg.sales': sales,
        'fifo.cogs': f, 'avg.cogs': m,
        'fifo.gp': sales - f, 'avg.gp': sales - m,
        'fifo.end': fEnd, 'avg.end': a,
        'fifo.total': f + fEnd, 'avg.total': m + a,
      };
    },
    // 第7章：1か月＝30日。売掛金は売上、在庫・買掛金は仕入（売上×原価率）を基準に日数分を持つ
    ccc(v) {
      const cr = v.cr / 100;
      const ar = (v.sales * v.rec) / 30;
      const stock = (v.sales * cr * v.inv) / 30;
      const ap = (v.sales * cr * v.pay) / 30;
      const wc = ar + stock - ap;
      return { ccc: v.rec + v.inv - v.pay, ar: Math.round(ar), stock: Math.round(stock), ap: Math.round(ap), wc: Math.round(wc), grow: Math.round((wc * v.g) / 100) };
    },
    // 第12章：定額法（月割・残存価額あり）と定率法（期首帳簿価額×償却率）
    dep(v) {
      const C = v.cost;
      const N = v.n;
      const m = v.m;
      const r = v.rate / 100;
      if (!(C > 0) || !(r > 0 && r <= 1)) return { error: !(C > 0) ? '取得原価を入力しよう' : '償却率は0より大きく100%以下で入力しよう' };
      const R = Math.round((C * v.res) / 100);
      const n = N + (m < 12 ? 1 : 0);
      const annual = (C - R) / N;
      let rem = C - R;
      let book = C;
      const o = { rows: [], C, R, N, m };
      for (let i = 1; i <= n; i++) {
        let sl = Math.floor(i === 1 ? (annual * m) / 12 : annual);
        if (i === n || sl > rem) sl = rem;
        rem -= sl;
        let db = Math.floor(i === 1 ? (C * r * m) / 12 : book * r);
        if (db > book) db = book;
        book -= db;
        o.rows.push({ i, sl, slb: R + rem, db, dbb: book });
        o['sl.' + i] = sl;
        o['slbook.' + i] = R + rem;
        o['db.' + i] = db;
        o['dbbook.' + i] = book;
      }
      return o;
    },
  };

  const seg = (el, grow, tip, label) => {
    el.style.flexGrow = grow;
    el.style.flexBasis = '0';
    el.style.display = grow > 0 ? 'flex' : 'none';
    el.dataset.tip = tip;
    el.setAttribute('aria-label', tip);
    el.textContent = label || '';
    if (label && el.scrollWidth > el.clientWidth + 1) el.textContent = ''; // 収まらない数値は出さない（表と吹き出しで読める）
  };

  const RENDER = {
    fifo(root, o) {
      show(root, 'd', sgn(o.d));
      out(root, 'prices', '仕入単価：月初 ' + fmt(o.p[0]) + '円 → 10/8 ' + fmt(o.p[1]) + '円 → 10/20 ' + fmt(o.p[2]) + '円');
      ['sales', 'cogs', 'gp', 'end', 'total'].forEach((k) => {
        out(root, 'fifo.' + k, fmt(o['fifo.' + k]));
        out(root, 'avg.' + k, fmt(o['avg.' + k]));
        const df = o['fifo.' + k] - o['avg.' + k];
        out(root, 'diff.' + k, df ? sgn(df) : '0');
      });
      [['fifo', '先入先出法'], ['avg', '移動平均法']].forEach(([m, name]) => {
        const c = root.querySelector('[data-seg="' + m + '.cogs"]');
        const e = root.querySelector('[data-seg="' + m + '.end"]');
        seg(c, o[m + '.cogs'], name + '・売上原価 ' + fmt(o[m + '.cogs']) + '円', fmt(o[m + '.cogs']));
        seg(e, o[m + '.end'], name + '・月末在庫 ' + fmt(o[m + '.end']) + '円', fmt(o[m + '.end']));
      });
      const df = o['fifo.gp'] - o['avg.gp'];
      out(
        root,
        'msg',
        o.d > 0
          ? '仕入値が上がっていると、先入先出法は「古くて安い原価」から払い出したと考えるので、売上原価が小さくなり、売上総利益は移動平均法より' + fmt(df) + '円大きい。そのぶん月末在庫は新しい高い単価で残る。'
          : o.d < 0
            ? '仕入値が下がっていると逆になる。先入先出法は「古くて高い原価」から払い出すので、売上総利益は移動平均法より' + fmt(-df) + '円小さい。'
            : '仕入値が変わらなければ、どちらの方法でも売上原価と利益は同じになる。違いが生まれるのは、仕入値が動いたときだけだ。'
      );
    },
    ccc(root, o, v) {
      show(root, 'sales', fmt(v.sales));
      ['cr', 'rec', 'inv', 'pay', 'g'].forEach((k) => show(root, k, String(v[k])));
      out(root, 'ccc', String(o.ccc));
      out(root, 'wc2', fmt(o.wc));
      out(root, 'grow', (o.grow > 0 ? '+' : '') + fmt(o.grow));
      out(root, 'ar', fmt(o.ar));
      out(root, 'stock', fmt(o.stock));
      out(root, 'ap', '−' + fmt(o.ap));
      out(root, 'wc', fmt(o.wc));
      // お金の出入りの時間軸
      const end = v.inv + v.rec;
      const max = Math.max(end, v.pay, 30);
      const pct = (x) => (x / max) * 100 + '%';
      const bar = (key, from, to, tip) => {
        const el = root.querySelector('[data-seg="' + key + '"]');
        el.style.left = pct(from);
        el.style.width = to > from ? 'calc(' + pct(to - from) + ' - 2px)' : '0';
        el.style.display = to > from ? 'block' : 'none';
        el.dataset.tip = tip;
        el.setAttribute('aria-label', tip);
      };
      bar('stock', 0, v.inv, '在庫：仕入れてから' + v.inv + '日で販売');
      bar('ar', v.inv, end, '売掛金：販売から' + v.rec + '日後に入金（仕入れから' + end + '日目）');
      bar('ap', 0, v.pay, '買掛金：仕入れから' + v.pay + '日目に支払い');
      bar('gap', Math.min(v.pay, end), Math.max(v.pay, end), o.ccc > 0 ? '立て替え期間：' + o.ccc + '日（支払いから入金まで）' : o.ccc < 0 ? '入金が支払いより' + -o.ccc + '日早い' : '支払いと入金が同じ日');
      const step = max <= 60 ? 10 : max <= 120 ? 20 : 30;
      const axis = root.querySelector('[data-out="axis"]');
      axis.textContent = '';
      for (let x = 0; x <= max; x += step) {
        const s = document.createElement('span');
        s.className = 'absolute top-0.5 -translate-x-1/2 whitespace-nowrap';
        s.style.left = pct(x);
        s.textContent = x + (x === 0 ? '日' : '');
        axis.appendChild(s);
      }
      out(
        root,
        'msg',
        (o.ccc > 0
          ? '仕入代金を払ってから売上代金を回収するまで、' + o.ccc + '日分のお金を立て替えている。'
          : o.ccc < 0
            ? 'CCCがマイナス：仕入代金を払うより' + -o.ccc + '日早く、売上代金が入ってくる。'
            : '仕入代金の支払いと売上代金の入金が同じ日になっている。') +
          (o.wc > 0
            ? '運転資金は' + fmt(o.wc) + '万円。売上が' + v.g + '%伸びると、利益とは別に、さらに' + fmt(o.grow) + '万円のお金が必要になる。'
            : '運転資金はマイナス（' + fmt(o.wc) + '万円）で、仕入先のお金で商売を回している状態だ。売上が伸びるほど、手元のお金が増える。')
      );
    },
    dep(root, o, v) {
      const chart = root.querySelector('[data-out="chart"]');
      const xaxis = root.querySelector('[data-out="xaxis"]');
      const tbody = root.querySelector('[data-out="rows"]');
      chart.textContent = '';
      xaxis.textContent = '';
      tbody.textContent = '';
      if (o.error) {
        out(root, 'msg', o.error);
        return;
      }
      const maxDep = Math.max(1, ...o.rows.map((r) => Math.max(r.sl, r.db)));
      const step = niceStep(maxDep, 3);
      const top = Math.ceil(maxDep / step) * step;
      const plot = document.createElement('div');
      plot.style.cssText = 'position:absolute;top:0;bottom:0;right:0;left:3.6rem';
      for (let y = 0; y <= top + 1e-9; y += step) {
        const g = document.createElement('div');
        g.style.cssText = 'position:absolute;left:0;right:0;border-top:1px solid ' + (y === 0 ? '#c3c2b7' : '#e1e0d9') + ';bottom:' + (y / top) * 100 + '%';
        const t = document.createElement('span');
        t.style.cssText = 'position:absolute;right:calc(100% + 6px);transform:translateY(-50%);font-size:10px;color:#898781;white-space:nowrap;font-variant-numeric:tabular-nums';
        t.textContent = y >= 10000 ? fmt(y / 10000) + '万' : fmt(y);
        g.appendChild(t);
        plot.appendChild(g);
      }
      const groups = document.createElement('div');
      groups.style.cssText = 'position:absolute;inset:0;display:flex;align-items:flex-end';
      const xs = document.createElement('div');
      xs.style.cssText = 'position:absolute;inset:0;left:3.6rem;display:flex';
      o.rows.forEach((r) => {
        const g = document.createElement('div');
        g.style.cssText = 'flex:1;height:100%;display:flex;align-items:flex-end;justify-content:center;gap:2px';
        [['sl', '定額法', COL.blue], ['db', '定率法', COL.orange]].forEach(([k, name, col]) => {
          const b = document.createElement('div');
          b.style.cssText = 'width:min(38%,24px);border-radius:4px 4px 0 0;background:' + col + ';height:' + (r[k] / top) * 100 + '%';
          b.tabIndex = 0;
          b.dataset.tip = r.i + '年目・' + name + ' ' + fmt(r[k]) + '円';
          b.setAttribute('aria-label', b.dataset.tip);
          g.appendChild(b);
        });
        groups.appendChild(g);
        const x = document.createElement('span');
        x.style.cssText = 'flex:1;text-align:center';
        x.textContent = r.i + (o.rows.length > 7 ? '' : '年目');
        xs.appendChild(x);
      });
      plot.appendChild(groups);
      chart.appendChild(plot);
      xaxis.appendChild(xs);
      // 表
      const td = 'border-t border-gray-200 px-1.5 py-1.5 text-right sm:px-2 tabular-nums text-gray-900';
      const cell = (tag, cls, text) => {
        const c = document.createElement(tag);
        c.className = cls;
        c.textContent = text;
        return c;
      };
      let sumSl = 0;
      let sumDb = 0;
      o.rows.forEach((r) => {
        sumSl += r.sl;
        sumDb += r.db;
        const tr = document.createElement('tr');
        tr.append(
          cell('th', 'border-t border-gray-200 whitespace-nowrap px-1.5 py-1.5 text-left font-bold text-gray-700 sm:px-2', r.i + '年目'),
          cell('td', td + ' border-l', fmt(r.sl)),
          cell('td', td + ' text-gray-600', fmt(r.slb)),
          cell('td', td + ' border-l', fmt(r.db)),
          cell('td', td + ' text-gray-600', fmt(r.dbb))
        );
        tbody.appendChild(tr);
      });
      const tr = document.createElement('tr');
      tr.className = 'bg-amber-50 font-bold';
      tr.append(cell('th', 'border-t border-gray-200 whitespace-nowrap px-1.5 py-1.5 text-left font-bold text-gray-700 sm:px-2', '合計'), cell('td', td + ' border-l', fmt(sumSl)), cell('td', td, ''), cell('td', td + ' border-l', fmt(sumDb)), cell('td', td, ''));
      tbody.appendChild(tr);
      const first = o.rows[0];
      const last = o.rows[o.rows.length - 1];
      const ratio = first.sl ? Math.round((first.db / first.sl) * 10) / 10 : 0;
      out(
        root,
        'msg',
        (o.m < 12 ? '1年目は' + o.m + 'か月分だけ償却する（月割）。' : '') +
          '定率法の1年目の償却費は' + fmt(first.db) + '円で、定額法の' + ratio + '倍。その後は毎年、期首の帳簿価額×償却率で小さくなっていく。' +
          '定額法は' + fmt(sumSl) + '円を償却し終えて帳簿価額が' + fmt(last.slb) + '円（残存価額）になるが、定率法では最後の年にも' + fmt(last.dbb) + '円が残る。実務の200%定率法では、途中で「改定償却率」に切り替えて残りを償却する（3級では出題されない）。'
      );
    },
  };

  $$('[data-sim]').forEach((root) => {
    const type = root.dataset.sim;
    if (!SIM[type]) return;
    const run = (e) => {
      const t = e && e.target;
      if (type === 'dep' && t && t.dataset && t.dataset.in === 'n') {
        root.querySelector('[data-in="rate"]').value = String(Math.round((2 / Number(t.value)) * 1000) / 10);
      }
      const v = {};
      $$('[data-in]', root).forEach((el) => {
        v[el.dataset.in] = el.type === 'range' || el.tagName === 'SELECT' ? Number(el.value) : num(el.value);
      });
      const o = SIM[type](v);
      root._out = o;
      RENDER[type](root, o, v);
    };
    root.addEventListener('input', run);
    run();
    // スタイルの生成（Tailwind）やフォントの読み込みが終わってから、グラフ内の数値の収まりを測り直す
    let raf = 0;
    const again = () => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => run());
    };
    addEventListener('load', again);
    addEventListener('resize', again);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(again);
  });

  // グラフの吹き出し（マウスを乗せる・タップする・キーボードで選ぶと表示。値は表でも読める）
  const tip = (el, on) => {
    const box = el.closest('.kb-chart');
    const t = box && box.querySelector('.kb-tip');
    if (!t) return;
    if (!on) return t.classList.add('hidden');
    t.textContent = el.dataset.tip;
    t.classList.remove('hidden');
    const b = box.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const x = Math.max(4, Math.min(r.left + r.width / 2 - b.left - t.offsetWidth / 2, b.width - t.offsetWidth - 4));
    t.style.left = x + 'px';
    t.style.top = Math.max(2, r.top - b.top - t.offsetHeight - 6) + 'px';
  };
  ['pointerover', 'focusin'].forEach((ev) =>
    document.addEventListener(ev, (e) => {
      const el = e.target.closest && e.target.closest('.kb-sim [data-tip]');
      if (el) tip(el, true);
    })
  );
  ['pointerout', 'focusout'].forEach((ev) =>
    document.addEventListener(ev, (e) => {
      const el = e.target.closest && e.target.closest('.kb-sim [data-tip]');
      if (el) tip(el, false);
    })
  );

  // ---------------------------------------------------------------- 用語のポップアップ
  const termData = document.getElementById('kb-terms');
  const pop = document.getElementById('kb-pop');
  let curTerm = null;
  const closeTerm = () => {
    if (!pop) return;
    pop.classList.add('hidden');
    if (curTerm) curTerm.setAttribute('aria-expanded', 'false');
    curTerm = null;
  };
  if (termData && pop) {
    const T = JSON.parse(termData.textContent);
    const f = (k) => pop.querySelector('[data-f="' + k + '"]');
    const openTerm = (btn) => {
      const t = T[btn.dataset.term];
      if (!t) return;
      f('y').textContent = t.y || '';
      f('n').textContent = btn.dataset.term;
      f('c').textContent = t.c;
      f('c').className = 'rounded px-1.5 py-0.5 text-[11px] font-bold ' + t.cc;
      f('hp').textContent = t.hp || '';
      f('b').textContent = t.b || '';
      f('b').className = 'rounded px-1.5 py-0.5 text-[11px] font-bold ' + (t.b ? t.bc : 'hidden');
      f('d').textContent = t.d;
      const a = f('h');
      a.textContent = t.h ? t.l + 'で詳しく →' : '';
      a.classList.toggle('hidden', !t.h);
      if (t.h) a.href = t.h;
      else a.removeAttribute('href');
      pop.classList.remove('hidden');
      const r = btn.getBoundingClientRect();
      const pw = pop.offsetWidth;
      const ph = pop.offsetHeight;
      let left = r.left + scrollX + r.width / 2 - pw / 2;
      left = Math.max(scrollX + 12, Math.min(left, scrollX + document.documentElement.clientWidth - pw - 12));
      let topY = r.bottom + scrollY + 8;
      if (r.bottom + ph + 16 > innerHeight && r.top > ph + 72) topY = r.top + scrollY - ph - 8;
      pop.style.left = left + 'px';
      pop.style.top = topY + 'px';
      curTerm = btn;
      btn.setAttribute('aria-expanded', 'true');
    };
    document.addEventListener('click', (e) => {
      const b = e.target.closest && e.target.closest('.kb-term');
      if (b) {
        e.preventDefault();
        if (curTerm === b) closeTerm();
        else openTerm(b);
        return;
      }
      if (!pop.contains(e.target) || (e.target.closest && e.target.closest('[data-close]'))) closeTerm();
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && curTerm) {
        const b = curTerm;
        closeTerm();
        b.focus();
      }
    });
    addEventListener('resize', closeTerm);
  }

  // ---------------------------------------------------------------- THINK（選択式）
  // 選ぶまでは、各選択肢へのフィードバックと「考え方の例」を隠しておく（スクリプトが動かない環境では全部見える）
  const THINK_ON = ['!border-amber-500', '!bg-amber-100', 'ring-2', 'ring-amber-400'];
  $$('[data-think]').forEach((box) => {
    $$('.kb-fb', box).forEach((f) => f.classList.add('hidden'));
    $$('.kb-answer', box).forEach((a) => a.classList.add('hidden'));
  });
  const pickThink = (opt) => {
    const box = opt.closest('[data-think]');
    $$('.kb-opt', box).forEach((o) => {
      const on = o === opt;
      o.setAttribute('aria-pressed', on ? 'true' : 'false');
      THINK_ON.forEach((c) => o.classList.toggle(c, on));
    });
    $$('.kb-fb', box).forEach((f) => f.classList.toggle('hidden', f.dataset.k !== opt.dataset.k));
    $$('.kb-answer', box).forEach((a) => a.classList.remove('hidden'));
    const fb = $$('.kb-fb', box).find((f) => f.dataset.k === opt.dataset.k);
    if (fb && fb.scrollIntoView) fb.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  };
  document.addEventListener('click', (e) => {
    const o = e.target.closest && e.target.closest('.kb-opt');
    if (o) pickThink(o);
  });
  addEventListener('beforeprint', () => $$('[data-think] .kb-fb, [data-think] .kb-answer').forEach((el) => el.classList.remove('hidden')));

  // ---------------------------------------------------------------- 模擬試験モード
  const M = document.querySelector('[data-mock]');
  const mock = M
    ? (() => {
        const cfg = JSON.parse(M.dataset.mock);
        const scope = M.closest('article') || document;
        const timer = document.getElementById('kb-timer');
        const T = timer.querySelector('[data-t]');
        const pauseBtn = timer.querySelector('.kb-mock-pause');
        const res = M.querySelector('.kb-mock-result');
        const q = (k) => res.querySelector('[data-r="' + k + '"]');
        const limit = cfg.min * 60000;
        let used = 0;
        let t0 = 0;
        let tick = null;
        let active = false;
        const secOf = (w) => cfg.secs.find((s) => (w.dataset.sec || '').indexOf(s.k) === 0);
        const widgets = () => $$('[data-kb]', scope).filter(secOf);
        const elapsed = () => used + (tick ? Date.now() - t0 : 0);
        const mmss = (ms) => {
          const s = Math.max(0, Math.ceil(ms / 1000));
          return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
        };
        const paint = () => {
          const left = limit - elapsed();
          T.textContent = mmss(left);
          T.classList.toggle('text-red-400', left <= 5 * 60000);
          if (active && left <= 0) finish(true);
        };
        const run = () => {
          t0 = Date.now();
          tick = setInterval(paint, 250);
          pauseBtn.textContent = '一時停止';
        };
        const pause = () => {
          if (tick) {
            used += Date.now() - t0;
            clearInterval(tick);
            tick = null;
            pauseBtn.textContent = '再開';
          } else run();
          paint();
        };
        const stop = () => {
          if (tick) clearInterval(tick);
          tick = null;
          active = false;
          document.body.classList.remove('kb-exam');
          timer.classList.add('hidden');
        };
        const start = () => {
          if (tick) clearInterval(tick);
          widgets().forEach(reset);
          $$('details.kb-answer', scope).forEach((d) => (d.open = false));
          closeTerm();
          document.body.classList.add('kb-exam');
          res.classList.add('hidden');
          timer.classList.remove('hidden');
          used = 0;
          active = true;
          run();
          paint();
          const h = $$('h2', scope).find((x) => x.textContent.indexOf(cfg.secs[0].k) >= 0);
          if (h) h.scrollIntoView({ block: 'start' });
        };
        const score = () => {
          const S = cfg.secs.map((s) => ({ k: s.k, p: s.p, n: 0, c: 0 }));
          const miss = {};
          widgets().forEach((w) => {
            const s = S.find((x) => (w.dataset.sec || '').indexOf(x.k) === 0);
            check(w).forEach((it) => {
              s.n++;
              if (it.ok) s.c++;
              else ((it.ch && it.ch.length ? it.ch.join(' ') : w.dataset.ch) || '').split(' ').filter(Boolean).forEach((c) => (miss[c] = (miss[c] || 0) + 1));
            });
          });
          S.forEach((s) => (s.pts = s.n ? Math.round((s.p * s.c) / s.n) : 0));
          return { S, total: S.reduce((a, s) => a + s.pts, 0), miss };
        };
        const showLast = () => {
          try {
            const L = JSON.parse(localStorage.getItem('kb3-mock') || 'null');
            if (L) M.querySelector('.kb-mock-last').textContent = '前回の結果：' + L.total + '点（' + new Date(L.at).toLocaleDateString('ja-JP') + '）';
          } catch (e) {}
        };
        const finish = (timeUp) => {
          if (!active) return;
          const ms = Math.min(elapsed(), limit);
          stop();
          const r = score();
          const pass = r.total >= cfg.pass;
          q('total').textContent = r.total;
          q('verdict').textContent = (timeUp ? '時間切れ・' : '') + (pass ? '合格圏' : '合格まであと' + (cfg.pass - r.total) + '点');
          q('verdict').className = 'rounded-full px-3 py-1 text-sm font-black ' + (pass ? 'bg-emerald-100 text-emerald-800' : 'bg-red-100 text-red-800');
          q('meter').style.width = r.total + '%';
          q('meter').className = 'h-2.5 rounded-full transition-all ' + (pass ? 'bg-emerald-600' : 'bg-amber-500');
          r.S.forEach((s) => {
            const tr = $$('tr[data-s]', res).find((x) => x.dataset.s === s.k);
            if (!tr) return;
            tr.querySelector('[data-r="pts"]').textContent = s.pts + ' / ' + s.p;
            tr.querySelector('[data-r="bar"]').style.width = (s.p ? (s.pts / s.p) * 100 : 0) + '%';
            tr.querySelector('[data-r="det"]').textContent = s.n ? s.n + '問中 ' + s.c + '問 正解' : '';
          });
          q('time').textContent = (timeUp ? '時間切れ（' + cfg.min + '分）' : '解答時間 ' + Math.floor(ms / 60000) + '分' + Math.floor((ms % 60000) / 1000) + '秒');
          const links = q('links');
          links.textContent = '';
          Object.entries(r.miss)
            .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
            .forEach(([id, n]) => {
              const a = document.createElement('a');
              a.href = document.getElementById(id) ? '#' + id : id + '.html';
              a.className = 'flex items-center justify-between gap-3 rounded-md border border-amber-300 bg-white px-3 py-2 text-sm font-bold text-gray-800 hover:border-amber-500';
              const name = document.createElement('span');
              name.textContent = cfg.ch[id] || id;
              const cnt = document.createElement('span');
              cnt.className = 'flex-none text-xs text-gray-500';
              cnt.textContent = '誤り ' + n;
              a.append(name, cnt);
              links.appendChild(a);
            });
          q('review').classList.toggle('hidden', !links.children.length);
          try {
            localStorage.setItem('kb3-mock', JSON.stringify({ total: r.total, at: Date.now() }));
          } catch (e) {}
          showLast();
          res.classList.remove('hidden');
          res.scrollIntoView({ block: 'start' });
          res.focus({ preventScroll: true });
          return r;
        };
        document.addEventListener('click', (e) => {
          const t = e.target;
          if (!t.closest) return;
          if (t.closest('.kb-mock-start')) start();
          else if (t.closest('.kb-mock-pause')) pause();
          else if (t.closest('.kb-mock-finish')) finish(false);
          else if (t.closest('.kb-mock-quit')) stop();
        });
        addEventListener('beforeunload', (e) => {
          if (active) {
            e.preventDefault();
            e.returnValue = '';
          }
        });
        showLast();
        return { start, stop, score, widgets };
      })()
    : null;

  // ---------------------------------------------------------------- 自己テスト（URL に ?selftest を付けたときだけ動く）
  if (/[?&]selftest/.test(location.search)) {
    setTimeout(() => {
      const ws = $$('[data-kb]');
      let pass = 0;
      const fails = [];
      const fire = (type, x, y, el) => el.dispatchEvent(new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, pointerId: 1, button: 0 }));
      ws.forEach((w, i) => {
        const k = w.dataset.kb;
        try {
          reset(w);
          let dragged = true;
          if (k === 'sort' || k === 'journal') {
            const chip = k === 'sort' ? own(w, '.kb-pool .kb-chip')[0] : own(w, '.kb-pool .kb-chip').find((c) => c.dataset.acct === JSON.parse(w.dataset.answer)[0].d[0][0]);
            const target = k === 'sort' ? own(w, '[data-zone]').find((z) => z.dataset.zone === chip.dataset.ans) : own(w, '.kb-row[data-side="d"] .kb-slot')[0];
            target.scrollIntoView({ block: 'center' });
            const a = chip.getBoundingClientRect();
            const b = target.getBoundingClientRect();
            fire('pointerdown', a.x + a.width / 2, a.y + a.height / 2, chip);
            fire('pointermove', a.x + a.width / 2 + 12, a.y + a.height / 2 + 12, document);
            fire('pointermove', b.x + b.width / 2, b.y + b.height / 2, document);
            fire('pointerup', b.x + b.width / 2, b.y + b.height / 2, document);
            dragged = k === 'sort' ? chip.closest('[data-zone]') === target : target.dataset.acct === chip.dataset.acct;
          }
          reveal(w);
          check(w);
          const right = w.dataset.ok === '1' && w._items.length > 0;
          if (k === 'sort') own(w, '.kb-pool')[0].appendChild(own(w, '.kb-chip')[0]);
          else if (k === 'journal') own(w, '.kb-amt')[0].value += '1';
          else if (k === 'fill') {
            const b = own(w, '.kb-blank').find((x) => x.dataset.ans !== '');
            if (isPick(b)) setPick(b, '');
            else b.value += '1';
          } else if (k === 'checks') {
            const cb = own(w, '.kb-ck')[0];
            cb.checked = !cb.checked;
          }
          check(w);
          const wrong = w.dataset.ok === '0';
          if (dragged && right && wrong) pass++;
          else fails.push('#' + i + ' ' + k + (dragged ? '' : ' drag') + (right ? '' : ' answer') + (wrong ? '' : ' wrong-undetected'));
          reset(w);
        } catch (err) {
          fails.push('#' + i + ' ' + k + ' ' + err.message);
        }
      });
      const sims = $$('[data-sim]');
      let simPass = 0;
      sims.forEach((root, i) => {
        const exp = JSON.parse(root.dataset.expect || '{}');
        const o = root._out || {};
        const bad = Object.keys(exp).filter((key) => !(Math.abs(o[key] - exp[key]) < 1e-6));
        if (!Object.keys(exp).length || bad.length) fails.push('sim#' + i + ' ' + bad.map((key) => key + '=' + o[key]).join(','));
        else simPass++;
      });
      const thinks = $$('[data-think]');
      let thinkPass = 0;
      thinks.forEach((box, i) => {
        const opts = $$('.kb-opt', box);
        const hiddenFirst = $$('.kb-fb', box).every((f) => f.classList.contains('hidden')) && $$('.kb-answer', box).every((a) => a.classList.contains('hidden'));
        const last = opts[opts.length - 1];
        last.click();
        const shown = $$('.kb-fb', box).filter((f) => !f.classList.contains('hidden'));
        const ok = hiddenFirst && opts.length >= 2 && shown.length === 1 && shown[0].dataset.k === last.dataset.k && last.getAttribute('aria-pressed') === 'true' && $$('.kb-answer', box).every((a) => !a.classList.contains('hidden'));
        if (ok) thinkPass++;
        else fails.push('think#' + i);
      });
      let termOk = null;
      const term = document.querySelector('.kb-term');
      if (term && pop) {
        term.click();
        termOk = !pop.classList.contains('hidden') && pop.querySelector('[data-f="n"]').textContent === term.dataset.term && pop.querySelector('[data-f="d"]').textContent !== '';
        document.body.click();
        termOk = termOk && pop.classList.contains('hidden');
        if (!termOk) fails.push('term');
      }
      let mockOk = null;
      if (mock) {
        mock.start();
        const ans = document.querySelector('.kb-answer');
        const hidden = !ans || getComputedStyle(ans).display === 'none';
        mock.widgets().forEach(reveal);
        const full = mock.score().total;
        mock.widgets().forEach(reset);
        const zero = mock.score().total;
        mock.stop();
        mock.widgets().forEach(reset);
        mockOk = hidden && full === 100 && zero === 0;
        if (!mockOk) fails.push('mock ' + full + '/' + zero + (hidden ? '' : ' answers-visible'));
      }
      const parts = ['演習 ' + pass + ' / ' + ws.length];
      if (sims.length) parts.push('シミュレーター ' + simPass + ' / ' + sims.length);
      if (thinks.length) parts.push('THINK ' + thinkPass + ' / ' + thinks.length);
      if (termOk !== null) parts.push('用語 ' + (termOk ? 'OK' : 'NG'));
      if (mockOk !== null) parts.push('模試 ' + (mockOk ? 'OK' : 'NG'));
      const b = document.createElement('div');
      b.id = 'kb-selftest';
      b.textContent = 'SELFTEST ' + (fails.length ? 'NG' : 'OK') + ' : ' + parts.join('・') + (fails.length ? ' ／ ' + fails.join(', ') : '');
      b.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:99;padding:12px;font:bold 16px sans-serif;color:#fff;background:' + (fails.length ? '#dc2626' : '#059669');
      document.body.appendChild(b);
      window.scrollTo(0, 0);
    }, 400);
  }
})();
