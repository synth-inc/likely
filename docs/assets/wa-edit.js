/* Edit mode for the Likely "whole app" component. Loaded only with ?edit-regions / #edit-regions (or WA.enterEdit()). */
(() => {
  const WA = window.WA;
  const rd = (v) => Math.round(v * 1000) / 1000;
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

  const style = document.createElement('style');
  style.textContent = `
  .wa.editing .wa-label{opacity:1;pointer-events:auto;cursor:move}
  .wa.editing .wa-mark{cursor:move;animation:none;z-index:6}
  .wa.editing .wa-label{z-index:6}
  .wa.editing .wa-zoom.on{pointer-events:none;opacity:.92}
  .wa-ed{position:absolute;inset:0;z-index:5;pointer-events:none}
  .wa:not(.editing) .wa-ed{display:none}
  .wa-box{position:absolute;pointer-events:auto;cursor:move;outline:1.5px dashed rgba(255,255,255,.75);outline-offset:0;background:rgba(56,125,245,.06)}
  .wa-box.sel{outline:2px solid #FFB020;background:rgba(255,176,32,.08)}
  .wa-box b{position:absolute;left:-1px;top:-1px;transform:translateY(-100%);background:rgba(22,23,26,.9);color:#fff;font:600 11px/1 -apple-system,sans-serif;padding:3px 6px;border-radius:4px 4px 0 0;white-space:nowrap}
  .wa-box.sel b{background:#FFB020;color:#16171A}
  .wa-h{position:absolute;width:10px;height:10px;background:#fff;border:1.5px solid #FFB020;border-radius:2px;transform:translate(-50%,-50%);display:none}
  .wa-box.sel .wa-h{display:block}
  .wa-h[data-h=nw]{left:0;top:0;cursor:nwse-resize}.wa-h[data-h=n]{left:50%;top:0;cursor:ns-resize}.wa-h[data-h=ne]{left:100%;top:0;cursor:nesw-resize}
  .wa-h[data-h=e]{left:100%;top:50%;cursor:ew-resize}.wa-h[data-h=se]{left:100%;top:100%;cursor:nwse-resize}.wa-h[data-h=s]{left:50%;top:100%;cursor:ns-resize}
  .wa-h[data-h=sw]{left:0;top:100%;cursor:nesw-resize}.wa-h[data-h=w]{left:0;top:50%;cursor:ew-resize}
  .wa-knob{position:absolute;pointer-events:auto;width:16px;height:16px;border-radius:50%;transform:translate(-50%,-50%);border:2px solid #fff;box-shadow:0 2px 8px rgba(0,0,0,.5)}
  .wa-knob.off{background:#FFB020;cursor:move}.wa-knob.k{background:#387DF5;cursor:nwse-resize;border-radius:3px}
  .wa-insp{max-width:860px;margin:14px auto 0;background:#1E2024;color:#fff;border-radius:12px;padding:14px;font:13px/1.4 -apple-system,"SF Pro Text",sans-serif;box-shadow:0 0 0 1px rgba(255,255,255,.1);text-align:left}
  .wa-insp .row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:10px}
  .wa-insp button{font:inherit;color:#fff;background:rgba(255,255,255,.1);border:0;border-radius:7px;padding:6px 11px;cursor:pointer}
  .wa-insp button:hover{background:rgba(255,255,255,.18)}
  .wa-insp button.pri{background:#387DF5}.wa-insp button.cur{background:#FFB020;color:#16171A;font-weight:600}
  .wa-insp button:focus-visible,.wa-insp input:focus-visible,.wa-insp select:focus-visible,.wa-insp textarea:focus-visible{outline:2px solid #387DF5;outline-offset:2px}
  .wa-insp .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(118px,1fr));gap:8px 10px;margin-bottom:10px}
  .wa-insp label{display:flex;flex-direction:column;gap:3px;color:rgba(235,240,255,.62);font-size:11.5px}
  .wa-insp input,.wa-insp select{font:inherit;color:#fff;background:#16171A;border:1px solid rgba(255,255,255,.14);border-radius:6px;padding:5px 7px;width:100%;box-sizing:border-box;font-variant-numeric:tabular-nums}
  .wa-insp .wide{grid-column:span 2}
  .wa-insp textarea{width:100%;box-sizing:border-box;height:220px;font:12px/1.45 ui-monospace,Menlo,monospace;color:#e8ecf5;background:#16171A;border:1px solid rgba(255,255,255,.14);border-radius:8px;padding:10px}
  .wa-insp .note{color:rgba(235,240,255,.62);font-size:12px}
  .wa-insp .status{margin-left:auto;color:#7fd39a;font-size:12px}
  .wa-insp h4{margin:0 8px 0 0;font-size:13px}`;
  document.head.appendChild(style);

  WA.figs.forEach(setup);

  function setup(fig) {
    let sel = 0;
    const cur = () => WA.config.regions[sel];
    fig.classList.add('editing');
    const ov = document.createElement('div'); ov.className = 'wa-ed'; fig.appendChild(ov);
    const save = () => { try { localStorage.setItem(WA.KEY, JSON.stringify(WA.config)); } catch (e) {} };

    // source boxes, one per region, plus pop-out knobs for the selected region
    const boxes = WA.config.regions.map((r, i) => {
      const b = document.createElement('div'); b.className = 'wa-box'; b.dataset.i = i;
      b.innerHTML = `<b></b>` + ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'].map((h) => `<i class="wa-h" data-h="${h}"></i>`).join('');
      ov.appendChild(b); return b;
    });
    const knobOff = document.createElement('i'); knobOff.className = 'wa-knob off'; knobOff.title = 'Drag: pop-out offset';
    const knobK = document.createElement('i'); knobK.className = 'wa-knob k'; knobK.title = 'Drag: pop-out zoom';
    ov.append(knobOff, knobK);

    function drawOverlay() {
      WA.config.regions.forEach((r, i) => {
        const b = boxes[i];
        Object.assign(b.style, { left: r.x + '%', top: r.y + '%', width: r.w + '%', height: r.h + '%' });
        b.classList.toggle('sel', i === sel);
        b.querySelector('b').textContent = `${r.n ?? i + 1} · ${r.label} (source)`;
      });
      const r = cur(), cx = r.x + r.w / 2 + (r.dx || 0), cy = r.y + r.h / 2 + (r.dy || 0);
      Object.assign(knobOff.style, { left: cx + '%', top: cy + '%' });
      Object.assign(knobK.style, { left: (cx + r.w * r.k / 2) + '%', top: (cy + r.h * r.k / 2) + '%' });
    }

    function update(refill = true) {
      WA.render();
      if (fig.classList.contains('editing')) fig._set(sel);
      drawOverlay(); if (refill) fillFields(); save();
    }

    function drag(e, apply) {
      e.preventDefault(); e.stopPropagation();
      const R = fig.getBoundingClientRect(), sx = e.clientX, sy = e.clientY, start = WA.clone(cur());
      const mv = (ev) => { apply(start, (ev.clientX - sx) / R.width * 100, (ev.clientY - sy) / R.height * 100); update(); };
      const up = () => { removeEventListener('pointermove', mv); removeEventListener('pointerup', up); };
      addEventListener('pointermove', mv); addEventListener('pointerup', up);
    }

    ov.addEventListener('pointerdown', (e) => {
      const knob = e.target.closest('.wa-knob');
      if (knob === knobOff) return drag(e, (s, dx, dy) => { const r = cur(); r.dx = rd((s.dx || 0) + dx); r.dy = rd((s.dy || 0) + dy); });
      if (knob === knobK) return drag(e, (s, dx, dy) => { const r = cur(); r.k = rd(clamp(s.k + Math.max(dx / (s.w / 2), dy / (s.h / 2)), 1, 4)); });
      const b = e.target.closest('.wa-box'); if (!b) return;
      sel = +b.dataset.i; update();
      const h = e.target.dataset.h || '';
      drag(e, (s, dx, dy) => {
        const r = cur();
        if (!h) { r.x = rd(clamp(s.x + dx, 0, 100 - s.w)); r.y = rd(clamp(s.y + dy, 0, 100 - s.h)); return; }
        if (h.includes('e')) r.w = rd(clamp(s.w + dx, 1, 100 - s.x));
        if (h.includes('s')) r.h = rd(clamp(s.h + dy, 1, 100 - s.y));
        if (h.includes('w')) { const nx = clamp(s.x + dx, 0, s.x + s.w - 1); r.w = rd(s.w + s.x - nx); r.x = rd(nx); }
        if (h.includes('n')) { const ny = clamp(s.y + dy, 0, s.y + s.h - 1); r.h = rd(s.h + s.y - ny); r.y = rd(ny); }
      });
    });
    // markers and labels are dragged directly
    fig.addEventListener('pointerdown', (e) => {
      if (!fig.classList.contains('editing')) return;
      const m = e.target.closest('.wa-mark,.wa-label'); if (!m) return;
      sel = +m.dataset.i; update();
      const isMark = m.classList.contains('wa-mark');
      drag(e, (s, dx, dy) => { const r = cur(); if (isMark) { r.mx = rd(s.mx + dx); r.my = rd(s.my + dy); } else { r.lx = rd(s.lx + dx); r.ly = rd(s.ly + dy); } });
    }, true);
    fig.addEventListener('click', (e) => { if (fig.classList.contains('editing') && e.target.closest('.wa-mark')) { e.preventDefault(); e.stopPropagation(); } }, true);

    // inspector
    const P = document.createElement('div'); P.className = 'wa-insp';
    const F = [['label', 'Label text', 'text', 'wide'], ['x', 'Source x %'], ['y', 'Source y %'], ['w', 'Source width %'], ['h', 'Source height %'],
      ['k', 'Zoom scale', 0.01], ['dx', 'Pop offset x %'], ['dy', 'Pop offset y %'], ['radius', 'Corner radius px', 1],
      ['mx', 'Marker x %'], ['my', 'Marker y %'], ['lx', 'Label x %'], ['ly', 'Label y %'], ['anchor', 'Label anchor', 'select']];
    P.innerHTML = `<div class="row"><h4>Edit regions</h4><span id="wa-tabs" class="row" style="margin:0"></span>
        <button type="button" id="wa-toggle" class="pri">Edit regions: on</button><span class="status" id="wa-status" aria-live="polite"></span></div>
      <div class="grid">${F.map(([k, t, type, cls]) => `<label class="${cls || ''}" for="wa-f-${k}">${t}${type === 'select'
        ? `<select id="wa-f-${k}"><option value="right">right (label ends at point)</option><option value="left">left (label starts at point)</option><option value="center">center</option></select>`
        : `<input id="wa-f-${k}" type="${type === 'text' ? 'text' : 'number'}" ${type === 'text' ? '' : `step="${typeof type === 'number' ? type : 0.1}"`}>`}</label>`).join('')}</div>
      <div class="row"><button type="button" id="wa-copy" class="pri">Copy config</button><button type="button" id="wa-dl">Download config</button>
        <button type="button" id="wa-json">Show JSON</button><button type="button" id="wa-reset">Reset</button>
        <span class="note">Drag boxes and handles · orange knob = pop offset · blue knob = zoom · drag numbers and labels. Saved in this browser.</span></div>
      <div id="wa-out" hidden><p class="note" id="wa-out-note"></p><textarea id="wa-ta" spellcheck="false" aria-label="Regions config JSON"></textarea></div>`;
    fig.after(P);
    const $ = (id) => P.querySelector('#' + id);
    const status = (t) => { $('wa-status').textContent = t; clearTimeout(status.t); status.t = setTimeout(() => { $('wa-status').textContent = ''; }, 2600); };

    function tabs() {
      $('wa-tabs').innerHTML = WA.config.regions.map((r, i) => `<button type="button" data-t="${i}" class="${i === sel ? 'cur' : ''}">${r.n ?? i + 1} ${r.label}</button>`).join('');
    }
    $('wa-tabs').addEventListener('click', (e) => { const b = e.target.closest('[data-t]'); if (b) { sel = +b.dataset.t; update(); } });
    function fillFields() {
      tabs();
      const r = cur();
      F.forEach(([k]) => { const el = $('wa-f-' + k); if (el !== document.activeElement) el.value = r[k] ?? (k === 'anchor' ? 'right' : 0); });
      if (!$('wa-out').hidden) $('wa-ta').value = json();
    }
    F.forEach(([k, , type]) => $('wa-f-' + k).addEventListener('input', (e) => {
      const v = e.target.value;
      if (type === 'text' || type === 'select') cur()[k] = v; else { const n = parseFloat(v); if (Number.isNaN(n)) return; cur()[k] = n; }
      update(false); tabs();
    }));

    const json = () => JSON.stringify(WA.config, null, 2);
    const showJSON = (note) => { $('wa-out').hidden = false; $('wa-out-note').textContent = note || 'Config JSON (percent of image).'; $('wa-ta').value = json(); $('wa-ta').focus(); $('wa-ta').select(); };
    $('wa-json').addEventListener('click', () => ($('wa-out').hidden ? showJSON() : ($('wa-out').hidden = true)));
    $('wa-copy').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(json()); status('Copied config to clipboard'); }
      catch (e) {
        showJSON('Clipboard was blocked. The JSON is selected below: press ⌘C to copy.');
        let ok = false; try { ok = document.execCommand('copy'); } catch (_) {}
        status(ok ? 'Copied config to clipboard' : 'Select the JSON below and copy it');
      }
    });
    $('wa-dl').addEventListener('click', () => {
      if (location.protocol === 'file:') {
        const a = document.createElement('a');
        a.href = URL.createObjectURL(new Blob([json() + '\n'], { type: 'application/json' }));
        a.download = 'regions.json'; document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 1000); status('Downloaded regions.json');
      } else showJSON('Downloads are blocked on this page. Copy the JSON below instead.');
    });
    $('wa-reset').addEventListener('click', () => {
      WA.config = WA.clone(WA.DEFAULT); try { localStorage.removeItem(WA.KEY); } catch (e) {}
      sel = Math.min(sel, WA.config.regions.length - 1); update(); status('Reset to the built-in regions');
    });
    $('wa-toggle').addEventListener('click', () => {
      const on = !fig.classList.contains('editing');
      fig.classList.toggle('editing', on);
      $('wa-toggle').textContent = on ? 'Edit regions: on' : 'Edit regions: off (hover preview)';
      $('wa-toggle').classList.toggle('pri', on);
      fig._set(on ? sel : null);
    });

    update();
  }
})();
