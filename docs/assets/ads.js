// Ad measurement (see privacy.html#ads). Loads the Reddit pixel, and fires a Likely-specific
// "Lead" conversion (plus a "LikelyDownload" custom event) when a Mac visitor clicks Download.
// Cloudless's site uses "AddToCart" on the same pixel, so Likely never fires that.
//
// - Global Privacy Control on: nothing loads, no prompt.
// - Visitors in Europe (by time zone): nothing loads until they accept the cookie prompt.
// - Every call is guarded, so a blocked pixel never breaks the download link.
(function () {
  var REDDIT_PIXEL_ID = 'a2_h1chsn71jptb';
  var CONSENT_KEY = 'likely-ads-consent'; // "yes" | "no"

  function store(get, value) {
    try {
      if (get) return localStorage.getItem(CONSENT_KEY);
      localStorage.setItem(CONSENT_KEY, value);
    } catch (e) { return null; }
  }

  if (navigator.globalPrivacyControl === true) return;

  function needsConsent() {
    try {
      var zone = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
      return /^(Europe|Atlantic\/(Reykjavik|Canary|Madeira|Azores|Faroe))\//.test(zone);
    } catch (e) { return true; }
  }

  function isMac() {
    var ua = navigator.userAgent || '';
    var platform = navigator.platform || '';
    var iPad = platform === 'MacIntel' && (navigator.maxTouchPoints || 0) > 1;
    return (/Mac/.test(platform) || /Mac OS X/.test(ua)) && !iPad;
  }

  var loaded = false;
  function loadPixels() {
    if (loaded) return;
    loaded = true;
    // Reddit's snippet, unchanged apart from formatting.
    !function (w, d) { if (!w.rdt) { var p = w.rdt = function () { p.sendEvent ? p.sendEvent.apply(p, arguments) : p.callQueue.push(arguments) }; p.callQueue = []; var t = d.createElement("script"); t.src = "https://www.redditstatic.com/ads/pixel.js", t.async = !0; var s = d.getElementsByTagName("script")[0]; s.parentNode.insertBefore(t, s) } }(window, document);
    rdt('init', REDDIT_PIXEL_ID);
    rdt('track', 'PageVisit');
  }

  function trackDownload() {
    if (!loaded || !isMac()) return;
    try {
      rdt('track', 'Lead');
      rdt('track', 'Custom', { customEventName: 'LikelyDownload' });
    } catch (e) { /* never block the download */ }
  }

  document.addEventListener('click', function (event) {
    var link = event.target.closest && event.target.closest('a[href*="/releases/latest/download/"]');
    if (link) trackDownload();
  }, true);

  function showPrompt() {
    var bar = document.createElement('div');
    bar.className = 'consent';
    bar.setAttribute('role', 'region');
    bar.setAttribute('aria-label', 'Cookie choice');
    bar.innerHTML =
      '<p>We’d like to use advertising cookies to see which of our ads work. ' +
      '<a href="privacy.html#ads">Details</a></p>' +
      '<div class="consent-actions">' +
      '<button type="button" class="btn btn-quiet" data-choice="no">No thanks</button>' +
      '<button type="button" class="btn btn-primary" data-choice="yes">Allow</button>' +
      '</div>';
    bar.addEventListener('click', function (event) {
      var choice = event.target.getAttribute && event.target.getAttribute('data-choice');
      if (!choice) return;
      store(false, choice);
      bar.remove();
      if (choice === 'yes') loadPixels();
    });
    document.body.appendChild(bar);
  }

  function start() {
    if (!needsConsent()) return loadPixels();
    var choice = store(true);
    if (choice === 'yes') return loadPixels();
    if (choice !== 'no') showPrompt();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
