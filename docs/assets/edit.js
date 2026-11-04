/* Copy-editing mode for the Likely landing page.
 *   ?edit           edit text in place; changes autosave to localStorage (this browser only)
 *   ?preview-edits  view the page with saved edits applied, read-only
 * Normal visitors never see stored edits. */
(function () {
  var params = new URLSearchParams(location.search);
  var editing = params.has('edit');
  var previewing = params.has('preview-edits');
  if (!editing && !previewing) return;

  var KEY = 'likely-landing-copy-v1';
  var els = Array.prototype.slice.call(document.querySelectorAll('[data-copy-id]'));
  var originals = {};
  els.forEach(function (el) { originals[el.dataset.copyId] = el.innerHTML.trim(); });

  function load() { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) { return {}; } }
  function save(map) { try { localStorage.setItem(KEY, JSON.stringify(map)); } catch (e) {} }
  function norm(s) { return String(s).replace(/\s+/g, ' ').trim(); }

  // Drop stale keys (ids that no longer exist) and edits that now match the source.
  var edits = load(), pruned = false;
  Object.keys(edits).forEach(function (id) {
    if (!Object.prototype.hasOwnProperty.call(originals, id) || norm(edits[id]) === norm(originals[id])) {
      delete edits[id]; pruned = true;
    }
  });
  if (pruned && editing) save(edits);
  els.forEach(function (el) {
    var id = el.dataset.copyId;
    if (Object.prototype.hasOwnProperty.call(edits, id)) el.innerHTML = edits[id];
  });

  if (previewing && !editing) {
    var badge = bar();
    badge.innerHTML = '<span class="count">Previewing saved edits</span>';
    return;
  }

  document.documentElement.classList.add('copy-editing');
  document.querySelectorAll('details').forEach(function (d) { d.open = true; });

  els.forEach(function (el) {
    el.setAttribute('contenteditable', 'true');
    el.setAttribute('spellcheck', 'true');
    el.addEventListener('input', function () { record(el); });
    el.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); el.blur(); }
    });
    el.addEventListener('paste', function (e) {
      e.preventDefault();
      var text = (e.clipboardData || window.clipboardData).getData('text/plain').replace(/\s+/g, ' ');
      document.execCommand('insertText', false, text);
    });
  });

  // Don't follow links or toggle FAQ items while editing.
  document.addEventListener('click', function (e) {
    if (e.target.closest('.copy-bar')) return;
    var a = e.target.closest('a, summary');
    if (a && !(e.metaKey || e.ctrlKey)) e.preventDefault();
  }, true);

  function record(el) {
    var id = el.dataset.copyId, html = el.innerHTML.trim();
    if (norm(html) === norm(originals[id])) delete edits[id]; else edits[id] = html;
    save(edits);
    refresh();
  }

  function changes() {
    return els.filter(function (el) { return Object.prototype.hasOwnProperty.call(edits, el.dataset.copyId); })
      .map(function (el) {
        var id = el.dataset.copyId;
        return { selectorOrId: '[data-copy-id="' + id + '"]', id: id, original: originals[id], edited: edits[id] };
      });
  }

  var ui = bar();
  ui.innerHTML =
    '<span class="count"></span>' +
    '<button type="button" data-act="export" class="primary">Export edits</button>' +
    '<button type="button" data-act="copy">Copy edits</button>' +
    '<button type="button" data-act="reset">Reset</button>';
  var count = ui.querySelector('.count');

  function refresh() {
    var n = changes().length;
    count.textContent = n === 1 ? '1 change' : n + ' changes';
    els.forEach(function (el) { el.classList.toggle('copy-changed', Object.prototype.hasOwnProperty.call(edits, el.dataset.copyId)); });
  }
  refresh();

  ui.addEventListener('click', function (e) {
    var act = e.target.dataset && e.target.dataset.act;
    var json = JSON.stringify(changes(), null, 2);
    if (act === 'export') {
      var url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
      var a = document.createElement('a');
      a.href = url; a.download = 'likely-landing-copy.json';
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    } else if (act === 'copy') {
      copyText(json, e.target);
    } else if (act === 'reset') {
      if (!confirm('Discard all copy edits?')) return;
      els.forEach(function (el) { el.innerHTML = originals[el.dataset.copyId]; });
      edits = {}; save(edits); refresh();
    }
  });

  function copyText(text, btn) {
    function done(ok) {
      var label = btn.textContent; btn.textContent = ok ? 'Copied' : 'Copy failed';
      setTimeout(function () { btn.textContent = label; }, 1400);
    }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      var ok = false; try { ok = document.execCommand('copy'); } catch (e) {}
      ta.remove();
      if (!ok) window.prompt('Copy the edits below:', text);
      done(ok);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
    } else fallback();
  }

  function bar() {
    var b = document.createElement('div');
    b.className = 'copy-bar';
    b.setAttribute('role', 'toolbar');
    b.setAttribute('aria-label', 'Copy editing');
    document.body.appendChild(b);
    return b;
  }
})();
