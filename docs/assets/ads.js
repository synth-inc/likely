// Ad measurement (see privacy.html#ads). Loads the Reddit pixel, and fires a Likely-specific
// "Lead" conversion (plus a "LikelyDownload" custom event) when a Mac visitor clicks Download.
// Cloudless's site uses "AddToCart" on the same pixel, so Likely never fires that.
//
// - Global Privacy Control on: nothing loads, no prompt.
// - Visitors in Europe (by time zone, or with no usable time zone): nothing loads until they
//   accept the cookie prompt.
// - A stored "no" (the prompt, or the opt-out on privacy.html#ads) turns it off for everyone.
// - Every call is guarded, so a blocked pixel never breaks the download link.
(function () {
  var REDDIT_PIXEL_ID = 'a2_h1chsn71jptb';
  var CONSENT_KEY = 'likely-ads-consent'; // "yes" | "no"
  var EXTRA_ZONES = ['Atlantic/Reykjavik', 'Atlantic/Canary', 'Atlantic/Madeira', 'Atlantic/Azores',
    'Atlantic/Faroe', 'Africa/Ceuta', 'Asia/Nicosia', 'Asia/Famagusta', 'America/Cayenne',
    'America/Guadeloupe', 'America/Martinique', 'America/Marigot', 'America/St_Barthelemy',
    'Indian/Reunion', 'Indian/Mayotte', 'Arctic/Longyearbyen'];

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
      // Unknown or hidden (privacy browsers report UTC): ask, to be safe.
      if (!zone || zone === 'UTC' || /^Etc\//.test(zone)) return true;
      // Europe/* covers the EU, EEA, UK and Switzerland; the rest are EU or EEA places outside it
      // (Cyprus, Ceuta, the Atlantic islands, France's overseas regions).
      return /^Europe\//.test(zone) || EXTRA_ZONES.indexOf(zone) !== -1;
    } catch (e) { return true; }
  }

  function isMac() {
    var ua = navigator.userAgent || '';
    var platform = navigator.platform || '';
    var iPad = platform === 'MacIntel' && (navigator.maxTouchPoints || 0) > 1;
    return (/Mac/.test(platform) || /Mac OS X/.test(ua)) && !iPad;
  }

  var loaded = false;
  var downloadTracked = false;
  function loadPixels() {
    if (loaded) return;
    loaded = true;
    // Reddit's snippet, unchanged apart from formatting.
    !function (w, d) { if (!w.rdt) { var p = w.rdt = function () { p.sendEvent ? p.sendEvent.apply(p, arguments) : p.callQueue.push(arguments) }; p.callQueue = []; var t = d.createElement("script"); t.src = "https://www.redditstatic.com/ads/pixel.js", t.async = !0; var s = d.getElementsByTagName("script")[0]; s.parentNode.insertBefore(t, s) } }(window, document);
    rdt('init', REDDIT_PIXEL_ID);
    rdt('track', 'PageVisit');
  }

  function trackDownload() {
    if (!loaded || downloadTracked || !isMac()) return;
    downloadTracked = true; // one conversion per page view, however many clicks
    try {
      rdt('track', 'Lead', { conversionId: 'likely-' + Date.now() + '-' + Math.random().toString(36).slice(2) });
      rdt('track', 'Custom', { customEventName: 'LikelyDownload' });
    } catch (e) { /* never block the download */ }
  }

  function onLinkClick(event) {
    var link = event.target.closest && event.target.closest('a[href*="/releases/latest/download/"]');
    if (link) trackDownload();
  }
  document.addEventListener('click', onLinkClick, true);
  document.addEventListener('auxclick', onLinkClick, true); // middle-click

  function showPrompt() {
    var bar = document.createElement('div');
    bar.className = 'consent';
    bar.setAttribute('role', 'region');
    bar.setAttribute('aria-label', 'Cookie choice');
    bar.setAttribute('aria-live', 'polite');
    bar.innerHTML =
      '<p>We’d like to use advertising cookies to see which of our ads work. ' +
      '<a href="privacy.html#ads">Details</a></p>' +
      '<div class="consent-actions">' +
      '<button type="button" class="btn btn-quiet" data-choice="no">No thanks</button>' +
      '<button type="button" class="btn btn-quiet" data-choice="yes">Allow</button>' +
      '</div>';
    bar.addEventListener('click', function (event) {
      var choice = event.target.getAttribute && event.target.getAttribute('data-choice');
      if (!choice) return;
      store(false, choice);
      bar.remove();
      if (choice === 'yes') loadPixels();
    });
    // Early in the DOM, so keyboard and screen-reader users reach it first.
    document.body.insertBefore(bar, document.body.firstChild);
  }

  function start() {
    var choice = store(true);
    if (choice === 'no') return;
    if (choice === 'yes' || !needsConsent()) return loadPixels();
    showPrompt();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
