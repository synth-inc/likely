/* Likely landing page: the animated product demo (styles in assets/demo.css).
 *
 * A macOS 26 desktop in dark mode: a browser upload page, its Open dialog, and Likely's search bar
 * above it. The scene is drawn at a fixed 1152 x 720 point size and scaled to the box.
 *
 * The animation is a timeline of events (built in `script()` below) rendered as a pure function of
 * time, so any moment can be shown with LikelyDemo.seek(seconds).
 *
 * TO CHANGE THE SEARCHES OR TIMING: edit SEARCHES (what's typed, the status lines, the files found)
 * and TIMING (seconds). Everything else follows from them.
 *
 * THE CAMERA (Screen Studio-style zoom): `cam` events in script() say where to look and how close
 * (CAMERA below); the Player eases between them and never shows past the wide view.
 */
(function () {
  'use strict';

  // ---- Timing (seconds) -------------------------------------------------------------------------
  var TIMING = {
    sheetIn: 0.34,        // dialog animates in
    sheetOut: 0.22,       // dialog animates out
    recentHold: 2.0,      // first open: how long "your newest files are already there" holds
    focusDelay: 0.45,     // after the dialog opens, the caret appears (the app waits 0.6 s)
    typeMin: 0.030,       // per-character typing delay range
    typeMax: 0.085,
    beforeReturn: 0.30,   // pause between the last character and Return
    statusStep: 1.0,      // each status file shows this long
    popGap: 0.30,         // between files popping into the folder
    afterFound: 0.45,     // results settle before the pointer moves
    move: 0.50,           // pointer travel time
    clickGap: 0.30,       // between clicks
    betweenSearches: 0.55,// dialog closed, before the next one opens
    loopRest: 0.6,        // extra pause before the loop starts again
    // Camera. Each `cam` event eases from wherever the camera is to its new target over camMove
    // seconds (camWide when going back out to the wide view). Longer = lazier, shorter = snappier.
    camMove: 0.7,
    camWide: 0.9,
    camIntro: 1.2,        // the slow drift in toward the recent files at the start
    camIntroAt: 0.75,     // ...starting this long after the first dialog opens
    camBarLead: 0.15,     // later searches: after the dialog opens, wait this long, then zoom to the bar
    clickRing: 0.5        // the ring that pulses at the pointer on each click
  };

  // ---- Camera -----------------------------------------------------------------------------------
  // Zoom levels: 1 = the wide view (CROP below); 1.5 = things look 1.5x bigger. Where each shot
  // looks is FOCUS (scene points). To change a shot, edit its zoom here; to change when it
  // happens, move its cam(...) call in script().
  var CAMERA = {
    recent: 1.15,     // first dialog: the recent files
    bar: 1.7,         // typing in Likely's search bar
    list: 1.5,        // the agent working: status files and results popping into the list
    follow: 1.25,     // selecting files and clicking Open: a steady shot of the rows and Open button
    ql: 1.6,          // Quick Look of the meme
    followLag: 0.42,  // follow: seconds of pointer history the camera averages (more = lazier)
    followMargin: 70, // follow: keep the pointer at least this many points inside the frame
    // Small boxes (phones): zooms above 1 get stronger, so text stays readable.
    // zoom' = 1 + (zoom - 1) * smallBoost when the box is narrower than smallWidth px.
    smallWidth: 560,
    smallBoost: 1.5
  };

  // ---- The searches -----------------------------------------------------------------------------
  // f(): name, date modified, size, kind, icon. Names are made up.
  function f(n, d, s, k, ic) { return { n: n, d: d, s: s, k: k, ic: ic }; }
  // Like the app: while the agent works, its latest status is an empty " …status…" file at the top of the folder.
  function statusFile(line) { return f('…' + line.replace(/…$/, '') + '…', 'Now', 'Zero bytes', 'Document', 'txt'); }

  var RECENT = [
    f('Screenshot 2026-11-09 at 9.38.12 AM.png', 'Today at 9:38 AM', '1.2 MB', 'PNG image', 'shot'),
    f('trip-itinerary.pdf', 'Today at 8:15 AM', '240 KB', 'PDF document', 'pdf'),
    f('Budget 2027.numbers', 'Yesterday at 6:02 PM', '486 KB', 'Numbers Spreadsheet', 'numbers'),
    f('IMG_4790.HEIC', 'Yesterday at 1:14 PM', '2.8 MB', 'HEIF image', 'photo'),
    f('notes.txt', 'Nov 6, 2026 at 4:51 PM', '4 KB', 'Plain Text', 'txt')
  ];

  var INV_OCT = f('Hosting invoice – October 2026.pdf', 'Oct 3, 2026 at 9:12 AM', '88 KB', 'PDF document', 'invoice');
  var INV_AUG = f('Hosting invoice – August 2026.pdf', 'Aug 3, 2026 at 9:10 AM', '87 KB', 'PDF document', 'invoice');
  var INV_MAR = f('Hosting invoice – March 2026.pdf', 'Mar 3, 2026 at 9:08 AM', '86 KB', 'PDF document', 'invoice');

  var SEARCHES = [
    { cap: 1, query: 'last year’s tax forms',
      status: ['Searching Documents…', 'Checking 2025 PDFs…'],
      found: [
        f('W-2 2025.pdf', 'Feb 12, 2026 at 10:04 AM', '182 KB', 'PDF document', 'form'),
        f('1099-INT 2025.pdf', 'Feb 3, 2026 at 8:47 AM', '96 KB', 'PDF document', 'form'),
        f('1099-DIV 2025.pdf', 'Jan 30, 2026 at 5:21 PM', '104 KB', 'PDF document', 'form')
      ] },
    { cap: 1, query: 'our logo with a transparent background',
      status: ['Searching Pictures and Desktop…', 'Checking PNGs for transparency…'],
      found: [ f('likely-logo.png', 'Sep 18, 2026 at 3:02 PM', '64 KB', 'PNG image', 'logo') ] },
    { cap: 2, query: 'that meme about losing files',
      status: ['Searching Pictures and Downloads…', 'Looking inside images…'],
      found: [ f('IMG_4821.png', 'Oct 26, 2026 at 8:03 AM', '412 KB', 'PNG image', 'meme') ],
      quickLook: true },
    { cap: 3, query: 'the invoice from the hosting company',
      status: ['Searching Documents and Mail Downloads…', 'Reading PDFs…'],
      found: [INV_OCT, INV_AUG, INV_MAR],
      refine: { query: 'not that one, the one from March', status: ['Checking dates…'], keep: [INV_MAR] } }
  ];

  // The frame shown when the visitor prefers reduced motion: the tax forms, selected.
  var STILL_AT = 'taxSelected';

  // ---- Scene geometry (points; see assets/demo.css) ---------------------------------------------
  var CROP = { x: 187, y: 96, w: 880, h: 550 };       // the part of the 1152 x 720 desktop shown
  var ROW_H = 24.2, ROWS_TOP = 172 + 52 + 30.8;        // first file row, in desktop points
  var OPEN_BTN = { x: 222.4 + 705.2 + 47, y: 172 + 411.2 + 17 };
  var REST = { x: 840, y: 520 };                       // where the pointer idles
  // What each camera shot looks at. If the zoomed frame is smaller than the rect it keeps the
  // rect's top-left corner in view (where the text starts) and crops the right/bottom.
  var SHEET = { x: 222.4, y: 172, w: 808.4, h: 454.4 };
  var HUD = { x: 418.4, y: 115.2, w: 612, h: 48 };
  var FOCUS = {
    wide: CROP,
    // The bar's mark + field and the top of the list just below it.
    bar: { x: HUD.x - 12, y: HUD.y - 4, w: 470, h: 56 },
    // The file list (header + rows), with the bar above it so its status line is in view too.
    list: { x: SHEET.x + 196 - 6, y: HUD.y - 4, w: 580, h: ROWS_TOP + 7.5 * ROW_H - HUD.y + 4 },
    ql: { x: 540, y: 200, w: 450, h: 328 },          // the Quick Look panel, and the selected row's pointer
    open: { x: OPEN_BTN.x - 150, y: OPEN_BTN.y - 90, w: 200, h: 120 },
    // Selecting files and clicking Open: one steady shot of the rows and the Open button (no pointer following).
    pick: { x: SHEET.x + 196 - 6, y: ROWS_TOP - 40, w: OPEN_BTN.x + 50 - (SHEET.x + 196 - 6), h: OPEN_BTN.y + 26 - (ROWS_TOP - 40) }
  };

  // ---- Icons ------------------------------------------------------------------------------------
  var GLYPH = '<svg viewBox="0 0 22 22" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round">' +
    '<path stroke-width="1.45" d="M5.8 2h8l4.2 4.2v12a1.8 1.8 0 0 1-1.8 1.8H5.8A1.8 1.8 0 0 1 4 18.2V3.8A1.8 1.8 0 0 1 5.8 2z"/>' +
    '<path stroke-width="1.45" fill="currentColor" d="M13.8 2 18 6.2h-4.2z"/>' +
    '<circle cx="8.2" cy="10.4" r="1.15" fill="currentColor" stroke="none"/><circle cx="13.8" cy="10.4" r="1.15" fill="currentColor" stroke="none"/>' +
    '<path stroke-width="1.4" d="M9 14.8h4"/></svg>';
  var SB = {
    likely: GLYPH,
    recents: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"><circle cx="8" cy="8" r="6.6"/><path d="M8 3.9V8H5.1"/></svg>',
    apps: '<svg viewBox="0 0 16 16"><rect x="1.6" y="1.6" width="12.8" height="12.8" rx="2.4" fill="none" stroke="currentColor" stroke-width="1.1"/>' +
      [4.3, 7.1, 9.9].map(function (y) { return [4.3, 7.1, 9.9].map(function (x) { return '<rect x="' + x + '" y="' + y + '" width="1.9" height="1.9" rx=".35" fill="currentColor"/>'; }).join(''); }).join('') + '</svg>',
    desktop: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1"><rect x="0.9" y="2.6" width="14.2" height="10.8" rx="2"/><path d="M1 5.2h14"/><rect x="2.8" y="9.6" width="10.4" height="1.6" rx=".5" fill="currentColor" stroke="none"/></svg>',
    docs: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"><path d="M4.2 1.2h5.2l3.8 3.8v8.6a1.2 1.2 0 0 1-1.2 1.2H4.2A1.2 1.2 0 0 1 3 13.6V2.4a1.2 1.2 0 0 1 1.2-1.2z"/><path d="M9.2 1.3v3.2a.6.6 0 0 0 .6.6h3.3"/></svg>',
    downloads: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="6.6"/><path d="M8 4.4v6.6M5.3 8.5 8 11.1l2.7-2.6"/></svg>',
    icloud: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"><path d="M4.4 12.6h7.9a3 3 0 0 0 .4-6 4.3 4.3 0 0 0-8.2-1A3.5 3.5 0 0 0 4.4 12.6z"/></svg>',
    shared: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"><path d="M1 4.2V3a1 1 0 0 1 1-1h3.4l1.4 1.5H9"/><path d="M1 4.6h8.6M1 4.2v8.4a1 1 0 0 0 1 1h8.2"/><circle cx="12.6" cy="4.6" r="1.8" fill="currentColor" stroke="none"/><path d="M9.6 10.6c.3-1.8 1.6-2.7 3-2.7s2.7.9 3 2.7z" fill="currentColor" stroke="none"/></svg>',
    hd: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"><path d="M1 9.6 3.4 4h9.2L15 9.6v3a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1z"/><path d="M1 9.6h14"/><path d="M4 11.6h.01M5.6 11.6h.01M7.2 11.6h.01M8.8 11.6h.01" stroke-width="1.1" stroke-linecap="round"/></svg>',
    network: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.1"><circle cx="8" cy="8" r="6.6"/><ellipse cx="8" cy="8" rx="2.9" ry="6.6"/><path d="M1.4 8h13.2M2.5 4.4h11M2.5 11.6h11M8 1.4v13.2"/></svg>'
  };
  var CHEV_L = '<svg viewBox="0 0 14 14" fill="none" stroke="#9C9C9F" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8.8 2.4 4.2 7l4.6 4.6"/></svg>';
  var CHEV_R = '<svg viewBox="0 0 14 14" fill="none" stroke="#4B4B4E" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5.2 2.4 9.8 7l-4.6 4.6"/></svg>';
  var UPDOWN = '<svg viewBox="0 0 9 13" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1.4 4.4 4.5 1.4l3.1 3M1.4 8.6l3.1 3 3.1-3"/></svg>';
  var LISTI = '<svg viewBox="0 0 30 14" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"><path d="M5.6 2.6h11M5.6 7h11M5.6 11.4h11"/><circle cx="1.6" cy="2.6" r=".9" fill="currentColor" stroke="none"/><circle cx="1.6" cy="7" r=".9" fill="currentColor" stroke="none"/><circle cx="1.6" cy="11.4" r=".9" fill="currentColor" stroke="none"/><path d="m22.6 5.8 2.6 2.6 2.6-2.6" stroke-width="1.2" stroke-linejoin="round"/></svg>';
  var GRIDI = '<svg viewBox="0 0 30 14" fill="none" stroke="currentColor" stroke-width="1.05"><rect x=".7" y=".7" width="5.4" height="5.4" rx="1.2"/><rect x="8.5" y=".7" width="5.4" height="5.4" rx="1.2"/><rect x=".7" y="8" width="5.4" height="5.4" rx="1.2"/><rect x="8.5" y="8" width="5.4" height="5.4" rx="1.2"/><path d="m19.8 5.8 2.6 2.6 2.6-2.6" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var MAG = '<svg viewBox="0 0 14 14" fill="none" stroke="#8D8D90" stroke-width="1.15" stroke-linecap="round"><circle cx="5.9" cy="5.9" r="4.8"/><path d="m9.5 9.5 3.6 3.6"/></svg>';
  var ARROW_UP = '<svg viewBox="0 0 14 14" fill="none" stroke="#fff" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M7 12V2.4M2.9 6.4 7 2.3l4.1 4.1"/></svg>';
  var CURSOR = '<svg viewBox="0 0 17 25" width="17" height="25"><path d="M1.5 1.2v19.6l4.7-4.6 3 6.9 3.3-1.4-2.9-6.8h6.6z" fill="#000" stroke="#fff" stroke-width="1.3" stroke-linejoin="round" style="filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.45))"/></svg>';

  // The made-up meme (IMG_4821.png) and the Likely logo (likely-logo.png), as SVG.
  var MEME = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 240"><rect width="320" height="119" fill="#cfe3f7"/><rect y="92" width="320" height="27" fill="#9fbf7a"/><circle cx="160" cy="58" r="13" fill="#ffd9b3" stroke="#222" stroke-width="2.5"/><path d="M154 61q6 6 12 0" fill="none" stroke="#222" stroke-width="2" stroke-linecap="round"/><circle cx="155" cy="55" r="1.6" fill="#222"/><circle cx="165" cy="55" r="1.6" fill="#222"/><path d="M160 71v20M160 91l-9 14M160 91l9 14M160 77l-14 6M160 77l12-10" stroke="#222" stroke-width="3" stroke-linecap="round" fill="none"/><path d="M172 67l2-7" stroke="#222" stroke-width="3" stroke-linecap="round"/><rect y="119" width="320" height="3" fill="#111"/><rect y="122" width="320" height="118" fill="#2b2f38"/><path d="M0 122l26 0-26 22zM0 122l14 16M8 122l-8 9" stroke="#8a8f99" stroke-width="1" fill="none" opacity=".7"/><path d="M320 122l-26 0 26 22zM320 122l-14 16M312 122l8 9" stroke="#8a8f99" stroke-width="1" fill="none" opacity=".7"/><rect x="176" y="150" width="104" height="62" rx="5" fill="#e9ecf2" stroke="#111" stroke-width="2"/><rect x="176" y="150" width="104" height="11" rx="5" fill="#c9ced8"/><circle cx="183" cy="155.5" r="2" fill="#ff5f57"/><circle cx="190" cy="155.5" r="2" fill="#febc2e"/><circle cx="197" cy="155.5" r="2" fill="#28c840"/><path d="M184 170h60M184 178h72M184 186h52M184 194h66M184 202h44" stroke="#9aa1ad" stroke-width="3" stroke-linecap="round"/><rect x="170" y="212" width="116" height="6" fill="#6b4f3a"/><circle cx="128" cy="160" r="14" fill="#f1efe8" stroke="#111" stroke-width="2"/><circle cx="123" cy="158" r="3.4" fill="#111"/><circle cx="133" cy="158" r="3.4" fill="#111"/><path d="M122 167h12M125 165v4M128 165v4M131 165v4" stroke="#111" stroke-width="1.4"/><path d="M128 174v34" stroke="#f1efe8" stroke-width="4"/><path d="M116 182h24M117 189h22M118 196h20" stroke="#f1efe8" stroke-width="3" stroke-linecap="round"/><path d="M128 180l26 14 18 4" stroke="#f1efe8" stroke-width="3.4" stroke-linecap="round" fill="none"/><path d="M128 208l-14 22M128 208l10 22" stroke="#f1efe8" stroke-width="3.4" stroke-linecap="round"/><rect x="92" y="206" width="36" height="5" fill="#6b4f3a"/><path d="M96 211v24M124 211v24" stroke="#6b4f3a" stroke-width="3"/><g font-family="Impact, Haettenschweiler, \'Arial Narrow Bold\', sans-serif" fill="#fff" stroke="#000" stroke-width="2.2" paint-order="stroke" text-anchor="middle"><text x="160" y="30" font-size="21">ME: I\'LL REMEMBER WHERE</text><text x="160" y="52" font-size="21" opacity="0">.</text><text x="76" y="112" font-size="18">I SAVED IT</text><text x="240" y="145" font-size="18">3 WEEKS LATER</text></g></svg>';
  var LOGO = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"> <defs> <linearGradient id="ldlk-bg" x1="0" y1="0" x2="0" y2="1"> <stop offset="0" stop-color="#5c94f7"/> <stop offset="1" stop-color="#387DF5"/> </linearGradient> <filter id="ldlk-ish" x="-10%" y="-10%" width="120%" height="130%"> <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".3"/> </filter> <filter id="ldlk-psh" x="-20%" y="-15%" width="140%" height="140%"> <feDropShadow dx="0" dy="10" stdDeviation="16" flood-color="#000" flood-opacity=".22"/> </filter> </defs> <g> <path d="M924.0 512.0L923.9 608.0L923.8 638.6L923.5 660.9L923.1 679.0L922.6 694.5L922.0 708.2L921.2 720.5L920.4 731.8L919.4 742.2L918.3 751.9L917.1 761.0L915.8 769.6L914.4 777.6L912.8 785.3L911.2 792.6L909.4 799.5L907.5 806.1L905.4 812.4L903.3 818.5L901.0 824.2L898.5 829.8L896.0 835.1L893.3 840.2L890.5 845.1L887.6 849.8L884.5 854.3L881.2 858.7L877.9 862.8L874.3 866.8L870.7 870.7L866.8 874.3L862.8 877.9L858.7 881.2L854.3 884.5L849.8 887.6L845.1 890.5L840.2 893.3L835.1 896.0L829.8 898.5L824.2 901.0L818.5 903.3L812.4 905.4L806.1 907.5L799.5 909.4L792.6 911.2L785.3 912.8L777.6 914.4L769.6 915.8L761.0 917.1L751.9 918.3L742.2 919.4L731.8 920.4L720.5 921.2L708.2 922.0L694.5 922.6L679.0 923.1L660.9 923.5L638.6 923.8L608.0 923.9L512.0 924.0L416.0 923.9L385.4 923.8L363.1 923.5L345.0 923.1L329.5 922.6L315.8 922.0L303.5 921.2L292.2 920.4L281.8 919.4L272.1 918.3L263.0 917.1L254.4 915.8L246.4 914.4L238.7 912.8L231.4 911.2L224.5 909.4L217.9 907.5L211.6 905.4L205.5 903.3L199.8 901.0L194.2 898.5L188.9 896.0L183.8 893.3L178.9 890.5L174.2 887.6L169.7 884.5L165.3 881.2L161.2 877.9L157.2 874.3L153.3 870.7L149.7 866.8L146.1 862.8L142.8 858.7L139.5 854.3L136.4 849.8L133.5 845.1L130.7 840.2L128.0 835.1L125.5 829.8L123.0 824.2L120.7 818.5L118.6 812.4L116.5 806.1L114.6 799.5L112.8 792.6L111.2 785.3L109.6 777.6L108.2 769.6L106.9 761.0L105.7 751.9L104.6 742.2L103.6 731.8L102.8 720.5L102.0 708.2L101.4 694.5L100.9 679.0L100.5 660.9L100.2 638.6L100.1 608.0L100.0 512.0L100.1 416.0L100.2 385.4L100.5 363.1L100.9 345.0L101.4 329.5L102.0 315.8L102.8 303.5L103.6 292.2L104.6 281.8L105.7 272.1L106.9 263.0L108.2 254.4L109.6 246.4L111.2 238.7L112.8 231.4L114.6 224.5L116.5 217.9L118.6 211.6L120.7 205.5L123.0 199.8L125.5 194.2L128.0 188.9L130.7 183.8L133.5 178.9L136.4 174.2L139.5 169.7L142.8 165.3L146.1 161.2L149.7 157.2L153.3 153.3L157.2 149.7L161.2 146.1L165.3 142.8L169.7 139.5L174.2 136.4L178.9 133.5L183.8 130.7L188.9 128.0L194.2 125.5L199.8 123.0L205.5 120.7L211.6 118.6L217.9 116.5L224.5 114.6L231.4 112.8L238.7 111.2L246.4 109.6L254.4 108.2L263.0 106.9L272.1 105.7L281.8 104.6L292.2 103.6L303.5 102.8L315.8 102.0L329.5 101.4L345.0 100.9L363.1 100.5L385.4 100.2L416.0 100.1L512.0 100.0L608.0 100.1L638.6 100.2L660.9 100.5L679.0 100.9L694.5 101.4L708.2 102.0L720.5 102.8L731.8 103.6L742.2 104.6L751.9 105.7L761.0 106.9L769.6 108.2L777.6 109.6L785.3 111.2L792.6 112.8L799.5 114.6L806.1 116.5L812.4 118.6L818.5 120.7L824.2 123.0L829.8 125.5L835.1 128.0L840.2 130.7L845.1 133.5L849.8 136.4L854.3 139.5L858.7 142.8L862.8 146.1L866.8 149.7L870.7 153.3L874.3 157.2L877.9 161.2L881.2 165.3L884.5 169.7L887.6 174.2L890.5 178.9L893.3 183.8L896.0 188.9L898.5 194.2L901.0 199.8L903.3 205.5L905.4 211.6L907.5 217.9L909.4 224.5L911.2 231.4L912.8 238.7L914.4 246.4L915.8 254.4L917.1 263.0L918.3 272.1L919.4 281.8L920.4 292.2L921.2 303.5L922.0 315.8L922.6 329.5L923.1 345.0L923.5 363.1L923.8 385.4L923.9 416.0Z" fill="url(#ldlk-bg)" filter="url(#ldlk-ish)"/> <path d="M344.63 254.5H589.25L705.13 370.38V769.5A25.75 25.75 0 0 1 679.38 795.25H344.63A25.75 25.75 0 0 1 318.88 769.5V280.25A25.75 25.75 0 0 1 344.63 254.5Z" fill="#FFFFFF" filter="url(#ldlk-psh)"/> <path d="M589.25 254.5V344.63A25.75 25.75 0 0 0 615 370.38H705.13Z" fill="#c9dcfc"/> <path d="M460.5 679.38L563.5 679.38" stroke="#1B1D22" stroke-width="25.75" stroke-linecap="round"/> <circle cx="441.19" cy="576.38" r="28.97" fill="#1B1D22"/> <circle cx="582.82" cy="576.38" r="28.97" fill="#1B1D22"/> <path d="M392 514C420 505 458 503 488 508" fill="none" stroke="#1B1D22" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/> <path d="M540 472C562 436 608 430 640 458" fill="none" stroke="#1B1D22" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/> </g> </svg>';
  function dataURI(svg) { return 'url("data:image/svg+xml,' + encodeURIComponent(svg) + '")'; }

  // File icons (Finder thumbnails), 14 x 14 points.
  function pageIcon(inner) {
    return '<svg class="ld-ic" viewBox="0 0 14 14"><path d="M2.6 0.4h6.2l2.6 2.6v10.2a.4.4 0 0 1-.4.4H2.6a.4.4 0 0 1-.4-.4V.8a.4.4 0 0 1 .4-.4z" fill="#fff"/>' +
      '<path d="M8.8.4V3h2.6" fill="#d9dce2"/>' + inner + '</svg>';
  }
  function lines(y0, n, x0, x1, gap, color) {
    var s = ''; for (var i = 0; i < n; i++) s += '<rect x="' + x0 + '" y="' + (y0 + i * gap) + '" width="' + (x1 - x0) * (i % 3 === 2 ? 0.6 : 1) + '" height=".5" fill="' + (color || '#b8bcc6') + '"/>';
    return s;
  }
  var ICONS = {
    pdf: pageIcon('<rect x="3.3" y="2" width="4" height=".9" fill="#333"/>' + lines(4, 5, 3.3, 10.4, 1.3)),
    form: pageIcon('<rect x="3.2" y="1.6" width="3.2" height=".8" fill="#222"/><rect x="3.2" y="3.4" width="7.4" height="2.4" fill="none" stroke="#8a9099" stroke-width=".35"/><rect x="3.2" y="6.6" width="3.5" height="2" fill="none" stroke="#8a9099" stroke-width=".35"/><rect x="7.1" y="6.6" width="3.5" height="2" fill="none" stroke="#8a9099" stroke-width=".35"/><rect x="3.2" y="9.4" width="7.4" height="2.6" fill="none" stroke="#8a9099" stroke-width=".35"/>'),
    invoice: pageIcon('<rect x="3.3" y="1.8" width="2.4" height="2.4" rx=".5" fill="#6C5CE7"/><rect x="7.2" y="2.2" width="3" height=".6" fill="#555"/>' + lines(5.6, 4, 3.3, 10.4, 1.2) + '<rect x="7" y="11" width="3.4" height=".9" fill="#333"/>'),
    txt: pageIcon(lines(2.2, 7, 3.3, 10.4, 1.4, '#9aa0aa')),
    numbers: pageIcon('<rect x="3.2" y="2.4" width="7.6" height="1.4" fill="#1fae5a"/>' + lines(4.8, 5, 3.2, 10.8, 1.4, '#c9ced6')),
    shot: '<svg class="ld-ic" viewBox="0 0 14 14"><rect x=".3" y="2.6" width="13.4" height="8.8" rx=".8" fill="#e6e8ee"/><rect x=".8" y="3.1" width="12.4" height="7.8" rx=".4" fill="#1d2a52"/><rect x="2.4" y="4.4" width="6.4" height="4.6" rx=".6" fill="#2c2d31"/><rect x="2.4" y="4.4" width="6.4" height="1" fill="#3a3b40"/><rect x="9.4" y="5.6" width="2.6" height="3.4" rx=".5" fill="#3a3b40"/></svg>',
    photo: '<svg class="ld-ic" viewBox="0 0 14 14"><defs><linearGradient id="ldsky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f6b26b"/><stop offset="1" stop-color="#e06666"/></linearGradient></defs><rect x="0" y="2.5" width="14" height="9.3" rx=".7" fill="url(#ldsky)"/><path d="M0 9.6l3.6-3 3 2.4 2.6-2 4.8 3.4v1.4H0z" fill="#3d2b4f"/></svg>',
    logo: '<svg class="ld-ic" viewBox="0 0 14 14"><g transform="translate(1 1) scale(.01171875)">' + LOGO.replace(/^<svg[^>]*>|<\/svg>$/g, '') + '</g></svg>',
    meme: '<span class="ld-ic"><span class="ld-thumbimg" style="top:2.1px;bottom:2.1px;background-image:' + dataURI(MEME).replace(/"/g, '&quot;') + '"></span></span>',
    // The reference screenshot's files (only for the comparison render).
    appicon: '<svg class="ld-ic" viewBox="0 0 14 14"><rect width="14" height="14" rx="3.2" fill="#4B86F0"/><rect x="4" y="2.8" width="6" height="8.4" rx=".6" fill="#fff"/><path d="M5.4 6.2h1.2M7.6 6h1.1M6.2 9h1.8" stroke="#222" stroke-width=".55" stroke-linecap="round"/></svg>',
    appiconDark: '<svg class="ld-ic" viewBox="0 0 14 14"><rect width="14" height="14" rx="3.2" fill="#4B86F0"/><rect x="4" y="2.8" width="6" height="8.4" rx=".6" fill="#1b1b1d"/></svg>',
    svgdoc: pageIcon(''),
    head: '<svg class="ld-ic" viewBox="0 0 14 14"><rect x="1.5" y="0" width="11" height="14" rx=".6" fill="#c6d3e6"/><circle cx="7" cy="5" r="2.3" fill="#e2bfa0"/><path d="M2.6 14c.4-3.4 2.2-4.8 4.4-4.8s4 1.4 4.4 4.8z" fill="#2f3f5f"/></svg>',
    lease: pageIcon(lines(2, 4, 3.3, 10.4, 1.2) + '<rect x="2.2" y="8.2" width="9.2" height="2.6" fill="#d33a32"/>')
  };

  // ---- Small helpers ----------------------------------------------------------------------------
  function el(tag, cls, html) { var e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; }
  function clamp(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
  function easeOut(x) { x = clamp(x); return 1 - Math.pow(1 - x, 3); }
  function easeInOut(x) { x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; }
  // macOS-like spring settle (slight overshoot), for things that appear.
  function spring(x) { x = clamp(x); return 1 - Math.exp(-6.5 * x) * Math.cos(7.5 * x) * (1 - x); }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
  function seeded(seed) { return function () { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }; }

  // ---- Build the scene --------------------------------------------------------------------------
  function buildScene(ref) {
    var s = el('div', 'ld');
    s.setAttribute('aria-hidden', 'true');

    // Desktop + menu bar
    s.appendChild(el('div', 'ld-wall'));
    var mb = el('div', 'ld-menubar');
    [['Bookmarks', 4.2], ['Profiles', 90.0], ['Tab', 155.4], ['Window', 194.8], ['Help', 262.4]].forEach(function (m) {
      var i = el('span', 'ld-mi', m[0]); i.style.left = m[1] + 'px'; mb.appendChild(i);
    });
    var status = el('span', 'ld-status', '<svg viewBox="0 0 190 16" width="190" height="16" fill="none" stroke="#fff">' +
      '<g transform="translate(-2.4 -2.2) scale(.92)" stroke-width="1.9">' + GLYPH.replace(/^<svg[^>]*>|<\/svg>$/g, '') + '</g>' +
      '<rect x="32.6" y="3.4" width="21" height="10" rx="3" stroke-width="1.1"/><rect x="34.4" y="5.2" width="17.4" height="6.4" rx="1.6" fill="#fff" stroke="none"/><path d="M55.4 7v2.8" stroke-width="1.4" stroke-linecap="round"/>' +
      '<g transform="translate(72.8 2.4)" stroke-width="1.7" stroke-linecap="round"><path d="M0 4.4a10 10 0 0 1 14 0M2.4 7.2a6.2 6.2 0 0 1 9.2 0"/><circle cx="7" cy="10.6" r="1.3" fill="#fff" stroke="none"/></g>' +
      '<g transform="translate(104 2)" stroke-width="1.6" stroke-linecap="round"><circle cx="5.4" cy="5.4" r="4.4"/><path d="m8.6 8.6 3.6 3.6"/></g>' +
      '<g transform="translate(134.6 2)" stroke-width="1.3"><rect x=".6" y=".6" width="12" height="5" rx="2.5"/><circle cx="3.2" cy="3.1" r="1.5" fill="#fff" stroke="none"/><rect x=".6" y="7.2" width="12" height="5" rx="2.5"/><circle cx="10" cy="9.7" r="1.5" fill="#fff" stroke="none"/></g></svg>');
    status.style.left = '849px';
    mb.appendChild(status);
    var clock = el('span', 'ld-mi ld-clock', ref ? 'Wed Nov 4&nbsp;&nbsp;9:41 AM' : 'Mon Nov 9&nbsp;&nbsp;9:41 AM');
    mb.appendChild(clock);
    s.appendChild(mb);

    // The browser window behind
    var app = el('div', 'ld-app');
    app.innerHTML =
      '<div class="ld-tabs"><div class="ld-tab"><span class="ld-tab-t">' + (ref ? 'Dashboard' : 'Uploads · Northwind') + '</span><span class="ld-x">✕</span></div>' +
      '<div class="ld-newtab"><i></i><span>New Tab</span></div></div>' +
      '<div class="ld-toolbar"><div class="ld-url"><span>' + (ref ? 'console.example.com/apps/likely/listing' : 'portal.example.com/clients/northwind/uploads') + '</span></div>' +
      '<div class="ld-avatar" style="left:1094.8px;top:7px;width:22px;height:22px"></div></div>' +
      '<div class="ld-page"><div class="ld-pnav">' +
      (ref ? '<span style="left:-14px">Analytics</span><span style="left:92.6px">Payouts</span><span style="left:164.6px">Docs</span>'
           : '<span style="left:20px">Overview</span><span style="left:93px">Files</span><span style="left:150px">Messages</span><span style="left:229px">Billing</span>') +
      '<div class="ld-avatar" style="left:1072px;top:15.6px;width:30px;height:30px"></div></div>' +
      '<div class="ld-crumb">' + (ref ? 'Apps › Likely › Store listing' : 'Clients › Northwind › Uploads') + '</div>' +
      '<h4>' + (ref ? 'Upload your app icon' : 'Upload your documents') + '</h4>' +
      '<div class="ld-sub">' + (ref ? 'PNG, 1024 × 1024 px, no transparency' : 'PDF, PNG or JPEG, up to 25 MB each') + '</div>' +
      '<div class="ld-drop"><b>Drag files here</b><i></i></div>' +
      '<div class="ld-shots">' + (ref ? 'Screenshots <span>0 of 10</span>' : 'Files <span>0 of 10</span>') + '</div>' +
      [0, 1, 2, 3, 4].map(function (i) { return '<div class="ld-thumb" style="left:' + (64.8 + i * 123.6) + 'px"></div>'; }).join('') +
      '</div>';
    // Only the reference comparison draws the browser behind; the demo shows just the desktop.
    if (ref) s.appendChild(app);

    // The Open dialog
    var sheet = el('div', 'ld-sheet');
    var side = el('div', 'ld-side');
    var items = [
      ['h', 'Favorites'], ['likely', 'Likely', true], ['recents', 'Recents'], ['apps', 'Applications'], ['desktop', 'Desktop'],
      ['docs', 'Documents'], ['downloads', 'Downloads'], ['h', 'iCloud'], ['icloud', 'iCloud Drive'], ['shared', 'Shared'],
      ['h', 'Locations'], ['hd', 'Macintosh HD'], ['network', 'Network']
    ];
    var y = 31.2, first = true;
    items.forEach(function (it) {
      if (it[0] === 'h') {
        if (!first) y += 28.8;
        var h = el('div', 'ld-sh', it[1]); h.style.top = (first ? 13.6 : y - 28.8 + 10.4) + 'px'; side.appendChild(h);
        first = false;
        return;
      }
      var r = el('div', 'ld-si' + (it[2] ? ' on' : ''), SB[it[0]] + '<span>' + it[1] + '</span>');
      r.style.top = y + 'px'; side.appendChild(r); y += 28;
    });
    sheet.appendChild(side);

    var tb = el('div', 'ld-tb');
    tb.innerHTML =
      '<div class="ld-cap ld-nav">' + CHEV_L.replace('<svg', '<svg style="left:10.4px;width:14px"') + CHEV_R.replace('<svg', '<svg style="left:40px;width:14px"') + '</div>' +
      '<div class="ld-path">' + GLYPH.replace('<svg', '<svg class="ld-pi"') + '<b>Likely</b>' + UPDOWN.replace('<svg', '<svg class="ld-ud" style="left:67.6px"') + '</div>' +
      '<div class="ld-cap ld-view1">' + LISTI.replace('<svg', '<svg style="left:9.4px;width:30px"') + '</div>' +
      '<div class="ld-cap ld-view2">' + GRIDI.replace('<svg', '<svg style="left:9.8px;width:30px"') + '</div>' +
      '<div class="ld-cap ld-search">' + MAG + '<span>Search</span></div>';
    sheet.appendChild(tb);

    var list = el('div', 'ld-list' + (ref ? ' ld-cols-ref' : ''));
    list.innerHTML = '<div class="ld-hdr"><span class="ld-c-name">Name</span><span class="ld-c-date ld-sort">Date Modified <svg viewBox="0 0 10 6" width="8" height="5" style="display:inline-block;vertical-align:2px;margin-left:2.6px" fill="none" stroke="#F2F2F5" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M1 1l4 4 4-4"/></svg></span>' +
      '<span class="ld-c-size">Size</span><span class="ld-c-kind">Kind</span></div>';
    var rows = el('div', 'ld-rows');
    for (var i = 1; i < 12; i += 2) { var st = el('div', 'ld-stripe'); st.style.top = (i * ROW_H) + 'px'; rows.appendChild(st); }
    list.appendChild(rows);
    sheet.appendChild(list);
    sheet.appendChild(el('div', 'ld-btn ld-cancel', 'Cancel'));
    sheet.appendChild(el('div', 'ld-btn ld-open', 'Open'));
    s.appendChild(sheet);

    // Likely's search bar
    var hud = el('div', 'ld-hud');
    hud.innerHTML = '<div class="ld-mark"><img alt="" src="' + assetURL('logo.svg') + '"></div>' +
      '<div class="ld-field"><span class="ld-ph">Tell Likely what you’re looking for…</span><span class="ld-typed"></span></div>' +
      '<div class="ld-status"></div>' +
      '<div class="ld-send">' + ARROW_UP + '</div>';
    s.appendChild(hud);

    // Quick Look
    var ql = el('div', 'ld-ql');
    ql.innerHTML = '<div class="ld-ql-bar"><span class="ld-ql-x"></span><span class="ld-ql-t">IMG_4821.png</span><span class="ld-ql-open">Open with Preview</span></div>' +
      '<div class="ld-ql-img" style="background-image:' + dataURI(MEME).replace(/"/g, '&quot;') + '"></div>';
    s.appendChild(ql);

    var ring = el('div', 'ld-click');
    s.appendChild(ring);
    var cur = el('div', 'ld-cursor', CURSOR);
    s.appendChild(cur);

    return {
      root: s, sheet: sheet, rows: rows, open: sheet.querySelector('.ld-open'), hud: hud, ql: ql, cursor: cur, ring: ring,
      mark: hud.querySelector('.ld-mark'), field: hud.querySelector('.ld-field'),
      ph: hud.querySelector('.ld-ph'), typed: hud.querySelector('.ld-typed'),
      status: hud.querySelector('.ld-status'), send: hud.querySelector('.ld-send')
    };
  }

  var scriptSrc = (document.currentScript && document.currentScript.src) || '';
  function assetURL(name) { return scriptSrc ? scriptSrc.replace(/[^\/]*$/, '') + name : 'assets/' + name; }

  // ---- The timeline -----------------------------------------------------------------------------
  // Events: { t, type, ... }. stateAt(t) folds over the events up to t.
  function script() {
    var ev = [], t = 0.25, rnd = seeded(7), marks = {};
    var cursor = { x: REST.x, y: REST.y };
    function add(e) { e.t = t; ev.push(e); return e; }
    function wait(d) { t += d; }
    // Camera: focus is a FOCUS key or 'follow' (trail the pointer); d = seconds to get there.
    function cam(focus, zoom, d) { add({ type: 'cam', focus: focus, zoom: zoom || 1, d: d || TIMING.camMove }); }
    function click() { add({ type: 'down' }); wait(0.09); add({ type: 'up' }); }
    function moveTo(x, y, d) { add({ type: 'move', fx: cursor.x, fy: cursor.y, x: x, y: y, d: d }); cursor = { x: x, y: y }; wait(d); }
    function type(text, from) {
      add({ type: 'focus', on: true });
      add({ type: 'dim', on: false });   // typing a new query replaces the greyed one
      var s = from || '';
      for (var i = 0; i < text.length; i++) {
        s += text[i]; add({ type: 'text', s: s });
        var d = TIMING.typeMin + rnd() * (TIMING.typeMax - TIMING.typeMin);
        if (text[i] === ' ') d += 0.03;
        wait(d);
      }
    }
    function rowY(i) { return ROWS_TOP + i * ROW_H + ROW_H / 2; }
    function open(hold, camAt, camFn) {
      add({ type: 'sheet', on: true });
      add({ type: 'rows', files: RECENT, pop: false });
      add({ type: 'sel', ids: [RECENT[0].n] });
      add({ type: 'status', s: '' });
      add({ type: 'dim', on: false });
      add({ type: 'text', s: '' });
      wait(camAt); camFn(); wait(hold - camAt);
    }
    function submit(s, files) {
      wait(TIMING.beforeReturn);
      cam('list', CAMERA.list);                     // watch the agent work in the list
      add({ type: 'dim', on: true });              // the query stays in the field, greyed out, while the agent works
      add({ type: 'focus', on: false });           // ...and hands the keyboard back to the picker
      add({ type: 'working', on: true });
      add({ type: 'rows', files: files || [], pop: false });
      add({ type: 'sel', ids: [] });
      add({ type: 'status', s: '' });
      s.status.forEach(function (line) {
        lastStatus = statusFile(line);
        add({ type: 'rows', files: [lastStatus].concat(files || []), pop: true });
        wait(TIMING.statusStep);
      });
    }
    var lastStatus = null;
    function found(list, keepRows) {
      var shown = keepRows ? keepRows.slice() : [];
      list.forEach(function (file, i) {
        shown = shown.concat([file]);
        add({ type: 'rows', files: (lastStatus ? [lastStatus] : []).concat(shown), pop: true });
        if (i < list.length - 1) wait(TIMING.popGap);
      });
      wait(0.35);
      add({ type: 'rows', files: shown.slice(), pop: false });   // the status file goes away when the search ends
      lastStatus = null;
      add({ type: 'working', on: false });
      add({ type: 'status', s: list.length + ' found · <u>Not these</u>', tone: 'found' });
      wait(TIMING.afterFound);
    }
    function pickAndOpen(files) {
      cam('wide', 1);
      moveTo(560, rowY(0), TIMING.move); click(); add({ type: 'sel', ids: [files[0].n] });
      if (files.length > 1) {
        wait(TIMING.clickGap);
        moveTo(585, rowY(files.length - 1), TIMING.move * 0.7); click();
        add({ type: 'sel', ids: files.map(function (x) { return x.n; }) });
        marks.taxSelected = marks.taxSelected || t + 0.6;
      }
      wait(TIMING.clickGap + 0.2);
      moveTo(OPEN_BTN.x, OPEN_BTN.y, TIMING.move * 1.1); click();
      add({ type: 'press', on: true }); wait(0.12); add({ type: 'press', on: false });
      add({ type: 'sheet', on: false }); add({ type: 'focus', on: false }); add({ type: 'ql', on: false });
      cam('wide', 1, TIMING.camWide);              // the dialog closes: ease back out
      wait(TIMING.sheetOut);
      moveTo(REST.x, REST.y, 0.6);
    }

    // 1. The dialog opens on the Likely folder: recent files, newest screenshot first.
    cam('wide', 1);
    add({ type: 'cap', i: 0 });
    open(TIMING.recentHold, TIMING.camIntroAt, function () { cam('list', CAMERA.recent, TIMING.camIntro); });
    SEARCHES.forEach(function (s, n) {
      if (n > 0) { wait(TIMING.betweenSearches); open(TIMING.focusDelay, TIMING.camBarLead, function () { cam('bar', CAMERA.bar); }); }
      else cam('bar', CAMERA.bar);
      add({ type: 'cap', i: s.cap });
      type(s.query);
      submit(s);
      found(s.found);
      if (s.quickLook) {
        cam('wide', 1);
        moveTo(560, rowY(0), TIMING.move); click(); add({ type: 'sel', ids: [s.found[0].n] });
        wait(0.25); add({ type: 'ql', on: true }); cam('ql', CAMERA.ql);
        wait(1.7); add({ type: 'ql', on: false }); wait(0.3);
      }
      if (s.refine) {
        wait(0.5);
        cam('bar', CAMERA.bar);
        type(s.refine.query);
        submit({ status: s.refine.status }, s.found);
        add({ type: 'rows', files: s.refine.keep, pop: false });
        lastStatus = null;
        add({ type: 'working', on: false });
        add({ type: 'status', s: s.refine.keep.length + ' found · <u>Not these</u>', tone: 'found' });
        wait(TIMING.afterFound + 0.3);
        pickAndOpen(s.refine.keep);
      } else {
        pickAndOpen(s.found);
      }
    });
    wait(TIMING.loopRest);
    return { events: ev, duration: t, marks: marks };
  }

  // The reference screenshot's state (assets/whole-app-base.png), for pixel comparisons.
  function refTimeline() {
    var REF = [
      f('app-icon-1024.png', 'Today at 9:12 AM', '612 KB', 'PNG image', 'appicon'),
      f('app-icon-1024-dark.png', 'Today at 9:12 AM', '598 KB', 'PNG image', 'appiconDark'),
      f('AppIcon.svg', 'Yesterday at 6:40 PM', '9 KB', 'SVG document', 'svgdoc'),
      f('headshot.jpg', 'Oct 28, 2026 at 2:03 PM', '1.4 MB', 'JPEG image', 'head'),
      f('Lease – signed.pdf', 'Oct 21, 2026 at 11:47 AM', '2.1 MB', 'PDF document', 'lease')
    ];
    return { duration: 1, marks: {}, events: [
      { t: -9, type: 'sheet', on: true }, { t: -9, type: 'rows', files: REF }, { t: -9, type: 'sel', ids: [REF[0].n] },
      { t: -9, type: 'move', fx: 2000, fy: 2000, x: 2000, y: 2000, d: 1 }] };
  }

  // ---- Camera at time t -------------------------------------------------------------------------
  // A camera is { x, y, z }: the scene point at the middle of the box and the zoom (1 = wide).
  // It's a pure function of time (no per-frame state), so seek() lands on the same frame as play.
  // view = { w, h, boost }: the scene points the box shows at zoom 1 (CROP, or less of it when the
  // box isn't 16:10) and the small-box zoom boost.

  // Ease for camera moves: a critically damped spring from rest, scaled to land exactly at 1.
  var CAM_K = 5.5, CAM_N = 1 - (1 + CAM_K) * Math.exp(-CAM_K);
  function camEase(x) { x = clamp(x); return (1 - (1 + CAM_K * x) * Math.exp(-CAM_K * x)) / CAM_N; }

  function cursorAt(tl, t) {
    var mv = tl.moves || (tl.moves = tl.events.filter(function (e) { return e.type === 'move'; }));
    var c = { x: REST.x, y: REST.y };
    for (var i = 0; i < mv.length && mv[i].t <= t; i++) {
      var e = mv[i], p = easeInOut((t - e.t) / e.d);
      c = { x: e.fx + (e.x - e.fx) * p, y: e.fy + (e.y - e.fy) * p };
    }
    return c;
  }

  // Where a cam event wants the camera at time t (it can move: 'follow' trails the pointer).
  function camTarget(tl, e, t, view) {
    var z = e.zoom > 1 ? 1 + (e.zoom - 1) * view.boost : 1;
    var vw = view.w / z, vh = view.h / z;
    if (e.focus === 'follow') {
      // Average the pointer over the last followLag seconds: the camera trails it smoothly.
      var sx = 0, sy = 0, N = 7;
      for (var j = 0; j < N; j++) { var c = cursorAt(tl, t - CAMERA.followLag * j / (N - 1)); sx += c.x; sy += c.y; }
      var cx = sx / N, cy = sy / N, now = cursorAt(tl, t);
      // ...but never let the pointer itself leave the frame.
      var mx = Math.min(CAMERA.followMargin, vw / 4), my = Math.min(CAMERA.followMargin, vh / 4);
      cx = Math.min(Math.max(cx, now.x - vw / 2 + mx), now.x + vw / 2 - mx);
      cy = Math.min(Math.max(cy, now.y - vh / 2 + my), now.y + vh / 2 - my);
      return { x: cx, y: cy, z: z };
    }
    var r = FOCUS[e.focus] || CROP;
    // Center on the rect; if it doesn't fit, keep its top-left (where the reading starts) in view.
    return {
      x: vw >= r.w ? r.x + r.w / 2 : r.x + vw / 2,
      y: vh >= r.h ? r.y + r.h / 2 : r.y + vh / 2,
      z: z
    };
  }
  function camMix(a, b, p) {
    return { x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p, z: a.z * Math.pow(b.z / a.z, p) };  // zoom: geometric
  }
  function camAt(tl, t, view) {
    var cams = tl.cams || (tl.cams = tl.events.filter(function (e) { return e.type === 'cam'; }));
    var key = view.w + ',' + view.h + ',' + view.boost;
    // from[i]: where the camera was when cams[i] started (memoized; depends only on the timeline and the view).
    if (!tl.camFrom || tl.camFrom.key !== key) tl.camFrom = { key: key, v: [] };
    var from = tl.camFrom.v;
    var wide = { x: CROP.x + CROP.w / 2, y: CROP.y + CROP.h / 2, z: 1 };
    var i = -1;
    while (i + 1 < cams.length && cams[i + 1].t <= t) i++;
    if (i < 0) return wide;
    for (var j = from.length; j <= i; j++) {
      from[j] = j === 0 ? wide : camMix(from[j - 1], camTarget(tl, cams[j - 1], cams[j].t, view), camEase((cams[j].t - cams[j - 1].t) / cams[j - 1].d));
    }
    return camMix(from[i], camTarget(tl, cams[i], t, view), camEase((t - cams[i].t) / cams[i].d));
  }

  // ---- State at time t --------------------------------------------------------------------------
  function stateAt(tl, t, view) {
    var st = {
      sheet: { on: false, t: -9 }, rows: {}, order: [], sel: [], text: '', lastType: -9, focus: false,
      status: '', tone: '', working: false, dim: false, cap: 0, ql: { on: false, t: -9 }, press: false,
      cur: { x: REST.x, y: REST.y }, down: false, click: null
    };
    var rows = st.rows, gen = 0;
    for (var i = 0; i < tl.events.length; i++) {
      var e = tl.events[i];
      if (e.t > t) break;
      switch (e.type) {
        case 'sheet': st.sheet = { on: e.on, t: e.t }; if (e.on) { for (var k in rows) delete rows[k]; gen++; } break;
        case 'rows':
          var names = e.files.map(function (x) { return x.n; });
          for (var key in rows) if (names.indexOf(key) < 0 && rows[key].tout == null) rows[key].tout = e.t;
          e.files.forEach(function (file, idx) {
            var r = rows[file.n];
            if (!r || r.tout != null) {
              r = rows[file.n] = { file: file, tin: e.pop ? e.t : (st.sheet.t === e.t ? -9 : e.t), pop: e.pop, idx: idx, pidx: idx, tmove: -9, tout: null, key: gen + ':' + file.n };
            } else if (r.idx !== idx) { r.pidx = r.idx; r.idx = idx; r.tmove = e.t; }
          });
          break;
        case 'sel': st.sel = e.ids; break;
        case 'text': if (e.s && e.s !== st.text) st.lastType = e.t; st.text = e.s; break;
        case 'focus': st.focus = e.on; if (e.on) st.lastType = Math.max(st.lastType, e.t - 0.6); break;
        case 'status': st.status = e.s; st.tone = e.tone || ''; break;
        case 'working': st.working = e.on; break;
        case 'dim': st.dim = e.on; break;
        case 'cap': st.cap = e.i; break;
        case 'ql': if (st.ql.on !== e.on) st.ql = { on: e.on, t: e.t }; break;
        case 'press': st.press = e.on; break;
        case 'down': st.down = true; st.click = { t: e.t, x: st.cur.x, y: st.cur.y }; break;
        case 'up': st.down = false; break;
        case 'move':
          var p = easeInOut((t - e.t) / e.d);
          st.cur = { x: e.fx + (e.x - e.fx) * p, y: e.fy + (e.y - e.fy) * p };
          break;
      }
    }
    st.cam = view ? camAt(tl, t, view) : null;
    return st;
  }

  // ---- Player -----------------------------------------------------------------------------------
  function Player(host, opts) {
    opts = opts || {};
    var ref = !!opts.ref;
    var tl = ref ? refTimeline() : script();
    var sc = buildScene(ref);
    var viewport = el('div', 'ld-viewport');
    viewport.appendChild(sc.root);
    host.appendChild(viewport);
    var crop = opts.crop || CROP;
    var rowEls = {}, last = {}, t0 = null, t = 0, playing = false, raf = 0, started = false;
    // The camera only runs on the real demo (not the reference comparison, nor a custom crop).
    var camOn = !ref && !opts.crop;
    var shown = null, box = { w: 0, h: 0, k: 1 }, view = { w: crop.w, h: crop.h, boost: 1 };

    function fit() {
      var w = host.clientWidth, h = host.clientHeight; if (!w || !h) return;
      var k = Math.max(w / crop.w, h / crop.h);   // cover the box with the crop
      box = { w: w, h: h, k: k };
      view = { w: w / k, h: h / k, boost: w < CAMERA.smallWidth ? CAMERA.smallBoost : 1 };
      if (shown != null) render(shown); else applyCamera(null);
    }

    // Fit transform x camera: scale by k*z around the camera point, clamped to the wide view
    // (CROP) so nothing past it is ever shown. Transform only: no layout.
    function applyCamera(c) {
      if (!box.w) return;
      var z = c ? Math.max(1, c.z) : 1, K = box.k * z;
      var vw = box.w / K, vh = box.h / K;
      var cx = c ? c.x : crop.x + crop.w / 2, cy = c ? c.y : crop.y + crop.h / 2;
      cx = Math.min(Math.max(cx, crop.x + vw / 2), crop.x + crop.w - vw / 2);
      cy = Math.min(Math.max(cy, crop.y + vh / 2), crop.y + crop.h - vh / 2);
      var tf = 'translate(' + (box.w / 2 - cx * K).toFixed(2) + 'px,' + (box.h / 2 - cy * K).toFixed(2) + 'px) scale(' + K.toFixed(5) + ')';
      if (last.cam !== tf) { last.cam = tf; sc.root.style.transform = tf; }
    }
    fit();
    if (window.ResizeObserver) new ResizeObserver(fit).observe(host); else window.addEventListener('resize', fit);

    function set(node, prop, val, cacheKey) {
      if (last[cacheKey] === val) return; last[cacheKey] = val;
      if (prop === 'html') node.innerHTML = val; else if (prop === 'text') node.textContent = val; else if (prop === 'class') node.className = val; else node.style[prop] = val;
    }

    function rowEl(r) {
      var x = rowEls[r.key];
      if (x) return x;
      var file = r.file;
      x = el('div', 'ld-row', '<div class="ld-hl"></div>' + ICONS[file.ic] +
        '<span class="ld-n">' + esc(fitName(file.n)) + '</span><span class="ld-d">' + esc(file.d) + '</span><span class="ld-s">' + esc(file.s) + '</span><span class="ld-k">' + esc(fitKind(file.k)) + '</span>');
      sc.rows.appendChild(x);
      return (rowEls[r.key] = x);
    }

    // Finder truncates long names in the middle and kinds at the end.
    var measurer;
    function textWidth(s) {
      if (!measurer) { measurer = el('span', 'ld-row-measure'); measurer.style.cssText = 'position:absolute;visibility:hidden;font-size:13.2px;white-space:nowrap;left:0;top:0'; sc.root.appendChild(measurer); }
      measurer.textContent = s; return measurer.offsetWidth;
    }
    var nameMax = ref ? 196 : 226, kindMax = ref ? 104 : 98;
    var nameCache = {};
    function fitName(n) {
      if (nameCache[n]) return nameCache[n];
      var out = n;
      if (textWidth(n) > nameMax && n.lastIndexOf('.') <= 0) {
        // No extension (e.g. the "…Searching…" status files): cut the end, like Finder does.
        var cut = n.length;
        do { cut--; out = n.slice(0, cut).replace(/[\s…]+$/, '') + '…'; } while (cut > 4 && textWidth(out) > nameMax);
      } else if (textWidth(n) > nameMax) {
        var dot = n.lastIndexOf('.'), tail = n.length - Math.max(dot - 6, 0), head = n.length - tail;
        do { head--; out = n.slice(0, head) + '…' + n.slice(n.length - tail); } while (head > 4 && textWidth(out) > nameMax);
      }
      return (nameCache[n] = out);
    }
    function fitKind(k) { var out = k; while (textWidth(out) > kindMax && out.length > 4) out = out.slice(0, -2) + '…'; if (out !== k) out = out.replace(/\s*…$/, '…'); return out; }

    function render(now) {
      shown = now;
      var st = stateAt(tl, now, camOn ? view : null);
      applyCamera(st.cam);

      // Dialog
      var sp = st.sheet.on ? spring((now - st.sheet.t) / 0.55) : 1 - easeOut((now - st.sheet.t) / TIMING.sheetOut);
      var so = st.sheet.on ? easeOut((now - st.sheet.t) / TIMING.sheetIn) : sp;
      if (st.sheet.t < 0 && st.sheet.on) { sp = 1; so = 1; }
      var sheetVisible = so > 0.001;
      set(sc.sheet, 'opacity', sheetVisible ? so.toFixed(3) : '0', 'so');
      set(sc.sheet, 'transform', 'translateY(' + ((1 - sp) * -10).toFixed(2) + 'px) scale(' + (0.955 + 0.045 * sp).toFixed(4) + ')', 'sx');
      set(sc.sheet, 'visibility', sheetVisible ? 'visible' : 'hidden', 'sv');

      // The bar follows the picker: it shows once the picker has appeared and hides with it.
      var ho = st.sheet.on ? easeOut((now - st.sheet.t - 0.18) / 0.2) : (now - st.sheet.t < 0.02 ? 1 : 0);
      if (st.sheet.t < 0 && st.sheet.on) ho = 1;
      set(sc.hud, 'opacity', ho.toFixed(3), 'ho');
      set(sc.hud, 'visibility', ho > 0.001 ? 'visible' : 'hidden', 'hv');

      // Field, caret, status, send button
      var caret = '';
      if (st.focus) {
        var idle = now - st.lastType - 0.5;
        var on = idle < 0 || Math.floor(idle / 0.53) % 2 === 1;
        caret = '<i class="ld-caret" style="opacity:' + (on ? 1 : 0) + '"></i>';
      }
      set(sc.typed, 'html', esc(st.text) + caret, 'typed');
      set(sc.typed, 'color', st.dim ? '#7C7D82' : '', 'tdim');
      set(sc.ph, 'opacity', st.text ? '0' : '1', 'ph');
      set(sc.ph, 'transform', st.text || !st.focus ? 'none' : 'translateX(2px)', 'phx');
      set(sc.status, 'html', st.status, 'status');
      set(sc.status, 'color', st.tone === 'found' ? '#9B9B9E' : '#6E6E72', 'stc');
      var sw = st.status ? (last.swFor === st.status ? last.sw : (last.swFor = st.status, last.sw = sc.status.offsetWidth)) : 0;
      set(sc.field, 'right', (45.4 + (sw ? sw + 10 : 0)) + 'px', 'fr');
      set(sc.status, 'right', '45.4px', 'sr');
      set(sc.send, 'class', 'ld-send' + (st.text.trim() ? ' on' : ''), 'send');
      set(sc.mark, 'class', 'ld-mark' + (st.working ? ' working' : ''), 'mark');

      // Rows
      var alive = {};
      Object.keys(st.rows).forEach(function (name) {
        var r = st.rows[name], node = rowEl(r);
        alive[r.key] = 1;
        var a = r.tin < 0 ? 1 : (r.pop ? spring((now - r.tin) / 0.45) : easeOut((now - r.tin) / 0.2));
        var o = r.tin < 0 ? 1 : easeOut((now - r.tin) / (r.pop ? 0.22 : 0.18));
        if (r.tout != null) { var k = 1 - easeOut((now - r.tout) / 0.18); o *= k; }
        var mv = r.tmove < 0 ? 1 : easeInOut((now - r.tmove - 0.12) / 0.28);
        var yy = (r.pidx + (r.idx - r.pidx) * mv) * ROW_H;
        var sc2 = r.pop ? 0.94 + 0.06 * a : 1;
        var tf = 'translate(' + (r.pop ? (1 - a) * -6 : 0).toFixed(2) + 'px,' + yy.toFixed(2) + 'px) scale(' + sc2.toFixed(4) + ')';
        if (node._tf !== tf) { node.style.transform = tf; node._tf = tf; }
        var op = o.toFixed(3);
        if (node._op !== op) { node.style.opacity = op; node._op = op; }
        var selIdx = st.sel.indexOf(name), isSel = selIdx >= 0 && r.tout == null;
        var prevSel = isSel && st.sel.indexOf(prevName(st, r.idx)) >= 0, nextSel = isSel && st.sel.indexOf(prevName(st, r.idx + 1, true)) >= 0;
        var cls = 'ld-row' + (isSel ? ' sel' : '') + (prevSel ? ' sel-up' : '') + (nextSel ? ' sel-down' : '');
        if (node.className !== cls) node.className = cls;
      });
      Object.keys(rowEls).forEach(function (key) { if (!alive[key]) { rowEls[key].remove(); delete rowEls[key]; } });

      // Quick Look
      var qp = st.ql.on ? spring((now - st.ql.t) / 0.45) : 1 - easeOut((now - st.ql.t) / 0.2);
      var qo = st.ql.on ? easeOut((now - st.ql.t) / 0.2) : qp;
      set(sc.ql, 'opacity', qo.toFixed(3), 'qo');
      set(sc.ql, 'visibility', qo > 0.001 ? 'visible' : 'hidden', 'qv');
      set(sc.ql, 'transform', 'scale(' + (0.3 + 0.7 * qp).toFixed(4) + ')', 'qt');

      // Open button press, pointer
      set(sc.open, 'filter', st.press ? 'brightness(0.85)' : 'none', 'press');
      set(sc.cursor, 'transform', 'translate(' + (st.cur.x - 1.5).toFixed(2) + 'px,' + (st.cur.y - 1.2).toFixed(2) + 'px) scale(' + (st.down ? 0.92 : 1) + ')', 'cur');

      // Click highlight: a ring pulses out from the pointer's tip.
      var cp = camOn && st.click ? (now - st.click.t) / TIMING.clickRing : 1;
      if (cp < 1) {
        set(sc.ring, 'transform', 'translate(' + st.click.x.toFixed(2) + 'px,' + st.click.y.toFixed(2) + 'px) scale(' + (0.3 + 0.9 * easeOut(cp)).toFixed(4) + ')', 'rt');
        set(sc.ring, 'opacity', (0.9 * (1 - easeInOut(cp))).toFixed(3), 'ro');
      } else set(sc.ring, 'opacity', '0', 'ro');

      // Captions
      if (opts.captions && last.cap !== st.cap) {
        last.cap = st.cap;
        opts.captions.forEach(function (c, i) { c.classList.toggle('on', i === st.cap); });
      }
    }
    function prevName(st, idx, fwd) {
      var names = Object.keys(st.rows).filter(function (n) { return st.rows[n].tout == null; });
      for (var i = 0; i < names.length; i++) if (st.rows[names[i]].idx === (fwd ? idx : idx - 1)) return names[i];
      return null;
    }

    function frame(ts) {
      if (!playing) return;
      if (t0 == null) t0 = ts - t * 1000;
      t = ((ts - t0) / 1000) % tl.duration;
      render(t);
      raf = requestAnimationFrame(frame);
    }
    var api = {
      duration: tl.duration, marks: tl.marks, events: tl.events,
      play: function () { if (playing) return; if (!started) { started = true; t = 0; } playing = true; t0 = null; raf = requestAnimationFrame(frame); },
      pause: function () { playing = false; cancelAnimationFrame(raf); },
      seek: function (s) { started = true; t = typeof s === 'string' ? tl.marks[s] : s; t0 = null; render(t); return t; },
      // camera(false): hold the wide view (reduced motion). camera(true) turns it back on.
      camera: function (on) { on = !!on && !ref && !opts.crop; if (on === camOn) return; camOn = on; if (shown != null) render(shown); },
      get time() { return t; }
    };
    // Before it first plays (e.g. still below the fold), show the picker open with recent files.
    render(ref ? 0 : 1.2);
    return api;
  }

  window.LikelyDemo = { Player: Player, SEARCHES: SEARCHES, TIMING: TIMING, CAMERA: CAMERA, script: script };

  // ---- Mount on the landing page ----------------------------------------------------------------
  var host = document.querySelector('[data-likely-demo]');
  if (!host) return;
  var caps = Array.prototype.slice.call(document.querySelectorAll('.demo-cap'));
  var player = Player(host, { captions: caps });
  window.LikelyDemo.player = player;
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)');
  var visible = false;
  function update() {
    if (reduce && reduce.matches) { player.pause(); player.camera(false); player.seek(STILL_AT); return; }
    player.camera(true);
    if (visible && !document.hidden) player.play(); else player.pause();
  }
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) { visible = entries[entries.length - 1].isIntersecting; update(); }, { threshold: 0.15 }).observe(host);
  } else { visible = true; }
  document.addEventListener('visibilitychange', update);
  if (reduce && reduce.addEventListener) reduce.addEventListener('change', update);
  update();

  // ---- ?edit: a background picker for the demo (editing aid only; never shown to visitors) -------
  if (/[?&]edit(&|=|$)/.test(location.search)) {
    var WALLS = [["Midnight aurora (current)", "radial-gradient(60% 55% at 12% 18%, rgba(56,125,245,.55), transparent 70%), radial-gradient(55% 60% at 88% 78%, rgba(124,82,230,.5), transparent 72%), radial-gradient(45% 40% at 70% 15%, rgba(40,170,200,.3), transparent 70%), radial-gradient(50% 45% at 25% 90%, rgba(220,90,150,.22), transparent 70%), linear-gradient(160deg,#101A3A,#141233 55%,#0C0F24)"], ["Deep blue", "radial-gradient(70% 60% at 30% 20%, #2B5BD6, transparent 70%), radial-gradient(60% 60% at 80% 90%, #1B2F7A, transparent 70%), #0A1230"], ["Sunset dunes", "radial-gradient(80% 60% at 20% 100%, #E9734A, transparent 70%), radial-gradient(70% 60% at 85% 85%, #B8467A, transparent 70%), linear-gradient(180deg,#2A1B4A,#5A2E62 55%,#C2566A)"], ["Teal lagoon", "radial-gradient(60% 60% at 15% 25%, #1FB5A8, transparent 70%), radial-gradient(60% 60% at 85% 75%, #146C94, transparent 70%), linear-gradient(160deg,#08262E,#0B3A44)"], ["Graphite", "radial-gradient(70% 70% at 30% 20%, #3A3D45, transparent 70%), linear-gradient(160deg,#1C1D21,#121316)"], ["Warm sand (light)", "radial-gradient(70% 60% at 20% 20%, #F6E3C6, transparent 70%), radial-gradient(60% 60% at 85% 85%, #E7B98C, transparent 70%), #EED6B6"], ["Lavender haze", "radial-gradient(60% 60% at 20% 20%, #9B8CF2, transparent 70%), radial-gradient(60% 60% at 80% 80%, #F2A2C8, transparent 70%), linear-gradient(160deg,#3B2F6E,#6A4A9C)"], ["Forest", "radial-gradient(70% 60% at 25% 25%, #2F7A4F, transparent 70%), radial-gradient(60% 60% at 85% 85%, #144C3A, transparent 70%), #0B1F18"], ["Brand blue", "radial-gradient(70% 70% at 50% 0%, #5C96FA, transparent 70%), linear-gradient(180deg,#387DF5,#1D4FB8)"], ["Peach glow", "radial-gradient(60% 60% at 15% 85%, #FFB38A, transparent 70%), radial-gradient(60% 60% at 85% 15%, #FF7E8A, transparent 70%), linear-gradient(160deg,#4A1F3A,#8A3550)"], ["Ocean wave", "conic-gradient(from 210deg at 70% 60%, #0F3D8A, #2A7BD6, #4FC3E8, #2A7BD6, #0F3D8A)"], ["Plain near-black", "#141519"]];
    var wall = host.querySelector('.ld-wall');
    var KEY = 'likely-demo-wall';
    var i = 0;
    i = 6;   // Lavender haze, the chosen default
    try { var saved = localStorage.getItem(KEY); if (saved !== null) i = Math.min(WALLS.length - 1, Math.max(0, +saved)); } catch (e) {}
    var bar = document.createElement('div');
    bar.className = 'ld-wallpicker';
    bar.innerHTML = '<button type="button" data-d="-1" aria-label="Previous background">‹</button><span></span><button type="button" data-d="1" aria-label="Next background">›</button>';
    var label = bar.querySelector('span');
    function apply() {
      wall.style.background = WALLS[i][1];
      label.textContent = 'Background ' + (i + 1) + ' of ' + WALLS.length + ': ' + WALLS[i][0];
      try { localStorage.setItem(KEY, String(i)); } catch (e) {}
    }
    bar.addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b) return;
      i = (i + (+b.dataset.d) + WALLS.length) % WALLS.length; apply();
    });
    host.parentNode.insertBefore(bar, host.nextSibling);
    apply();
  }
})();
