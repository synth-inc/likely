/* Likely "whole app" interactive screenshot runtime. Reads window.WA_CONFIG (regions.js).
   Edit mode (?edit-regions or #edit-regions; the landing page's ?edit is its copy editor) loads wa-edit.js from the same folder; normal visitors never load it. */
(() => {
  const KEY = 'likely-wa-regions-v1';
  const clone = (o) => JSON.parse(JSON.stringify(o));
  const DEFAULT = clone(window.WA_CONFIG);
  const SELF = document.currentScript && document.currentScript.src;
  const editFlag = /(^|&)edit-regions(=|&|$)/.test(location.search.slice(1)) || location.hash === '#edit-regions';
  const stored = () => { try { const s = localStorage.getItem(KEY); return s ? JSON.parse(s) : null; } catch (e) { return null; } };
  const WA = window.WA = { KEY, DEFAULT, clone, editFlag, config: (editFlag && stored()) || clone(DEFAULT), figs: [] };
  const pct = (v) => (+v).toFixed(3) + '%';

  function place(fig) {
    fig.querySelectorAll('.wa-zoom,.wa-mark,.wa-label').forEach((e) => e.remove());
    WA.config.regions.forEach((r, i) => {
      const z = document.createElement('div');
      z.className = 'wa-zoom'; z.dataset.i = i;
      Object.assign(z.style, {
        left: pct(r.x), top: pct(r.y), width: pct(r.w), height: pct(r.h), borderRadius: (r.radius ?? 12) + 'px',
        backgroundImage: `url("${fig.dataset.img}")`,
        backgroundSize: `${pct(10000 / r.w)} ${pct(10000 / r.h)}`,
        backgroundPosition: `${pct(r.w >= 100 ? 0 : r.x / (100 - r.w) * 100)} ${pct(r.h >= 100 ? 0 : r.y / (100 - r.h) * 100)}`,
      });
      z.style.setProperty('--t', `translate(${pct((r.dx || 0) / r.w * 100)},${pct((r.dy || 0) / r.h * 100)}) scale(${r.k})`);
      const m = document.createElement('button');
      m.type = 'button'; m.className = 'wa-mark'; m.dataset.i = i; m.textContent = r.n ?? i + 1;
      m.setAttribute('aria-label', `${m.textContent}: ${r.label}`); m.setAttribute('aria-expanded', 'false');
      Object.assign(m.style, { left: pct(r.mx), top: pct(r.my) });
      const l = document.createElement('span');
      l.className = 'wa-label'; l.dataset.i = i; l.dataset.anchor = r.anchor || 'right'; l.textContent = r.label;
      Object.assign(l.style, { left: pct(r.lx), top: pct(r.ly) });
      fig.append(z, m, l);
    });
  }

  function wire(fig) {
    let wasOn = false;
    const editing = () => fig.classList.contains('editing');
    const set = (i) => {
      fig._on = i == null ? null : String(i);
      fig.querySelectorAll('.wa-zoom,.wa-mark,.wa-label').forEach((e) => e.classList.toggle('on', fig._on !== null && e.dataset.i === fig._on));
      fig.querySelectorAll('.wa-mark').forEach((m) => m.setAttribute('aria-expanded', m.dataset.i === fig._on));
      fig.classList.toggle('active', fig._on !== null);
    };
    fig._set = set;
    fig.addEventListener('pointerover', (e) => {
      if (editing() || e.pointerType !== 'mouse') return;
      const m = e.target.closest('.wa-mark'); if (m) set(m.dataset.i);
    });
    fig.addEventListener('pointerout', (e) => {
      if (editing() || e.pointerType !== 'mouse' || fig._on === null) return;
      const to = e.relatedTarget;
      if (to && fig.contains(to) && to.closest(`[data-i="${fig._on}"]`)) return;
      set(null);
      if (document.activeElement && fig.contains(document.activeElement)) document.activeElement.blur();
    });
    fig.addEventListener('pointerdown', (e) => {
      const m = e.target.closest('.wa-mark'); if (!m || editing()) return;
      wasOn = fig._on === m.dataset.i && e.pointerType !== 'mouse';
    });
    fig.addEventListener('focusin', (e) => { const m = e.target.closest('.wa-mark'); if (m && !editing()) set(m.dataset.i); });
    fig.addEventListener('focusout', (e) => { const m = e.target.closest('.wa-mark'); if (m && !editing() && fig._on === m.dataset.i) set(null); });
    fig.addEventListener('click', (e) => {
      const m = e.target.closest('.wa-mark'); if (!m || editing()) return;
      e.stopPropagation();
      if (wasOn) { set(null); m.blur(); } else set(m.dataset.i);
      wasOn = false;
    });
    document.addEventListener('click', (e) => { if (!editing() && !fig.contains(e.target)) set(null); });
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !editing()) { set(null); if (fig.contains(document.activeElement)) document.activeElement.blur(); } });
  }

  WA.render = () => WA.figs.forEach((f) => { const on = f._on; place(f); f._set(on); });
  WA.enterEdit = () => {
    if (WA.editorLoaded) return;
    WA.editorLoaded = true; WA.editFlag = true;
    const s = stored(); if (s) { WA.config = s; WA.render(); }
    const tag = document.createElement('script');
    tag.src = SELF ? SELF.replace(/wa\.js(\?.*)?$/, 'wa-edit.js') : 'wa-edit.js';
    document.head.appendChild(tag);
  };

  const init = () => {
    document.querySelectorAll('figure.wa[data-img]').forEach((fig) => { WA.figs.push(fig); place(fig); wire(fig); fig._set(null); });
    if (editFlag) WA.enterEdit();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
