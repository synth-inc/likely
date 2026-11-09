/* Hero effects: question marks burst out of the cursor while it moves over the hero.
   Off for touch and for people who prefer reduced motion. */
(function () {
  var hero = document.querySelector('.hero');
  if (!hero || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  if (getComputedStyle(hero).position === 'static') hero.style.position = 'relative';
  var parts = [], last = 0, lastX = -1e9, lastY = -1e9;
  var colors = ['#387DF5', '#5C96FA', '#82B0FF', 'rgba(235,240,255,0.75)'];

  hero.addEventListener('pointermove', function (e) {
    if (e.pointerType === 'touch' || document.documentElement.classList.contains('copy-editing')) return;
    var now = performance.now(), r = hero.getBoundingClientRect();
    var x = e.clientX - r.left, y = e.clientY - r.top;
    if (now - last < 70 || Math.hypot(x - lastX, y - lastY) < 18 || parts.length > 40) return;
    last = now; lastX = x; lastY = y;
    spawn(x, y);
  });

  function spawn(x, y) {
    var el = document.createElement('span');
    el.className = 'hero-pop';
    el.setAttribute('aria-hidden', 'true');
    el.textContent = '?';
    var size = 14 + Math.random() * 14, a = Math.random() * Math.PI * 2, speed = 5 + Math.random() * 4;
    el.style.fontSize = size + 'px';
    el.style.color = colors[(Math.random() * colors.length) | 0];
    hero.appendChild(el);
    parts.push({ el: el, x: x - size * 0.3, y: y - size * 0.6, vx: Math.cos(a) * speed, vy: Math.sin(a) * speed,
                 rot: (Math.random() - 0.5) * 30, vr: (Math.random() - 0.5) * 8, age: 0, life: 26 + Math.random() * 8 });
    if (parts.length === 1) requestAnimationFrame(tick);
  }

  function tick() {
    for (var i = parts.length - 1; i >= 0; i--) {
      var p = parts[i];
      p.age++; p.vx *= 0.9; p.vy *= 0.9;
      p.x += p.vx; p.y += p.vy; p.rot += p.vr;
      var t = p.age / p.life;
      var scale = p.age < 3 ? 0.5 + p.age * 0.17 : 1;
      p.el.style.transform = 'translate(' + p.x + 'px,' + p.y + 'px) rotate(' + p.rot + 'deg) scale(' + scale + ')';
      p.el.style.opacity = t < 0.3 ? 1 : Math.max(0, 1 - (t - 0.3) / 0.7);
      if (p.age >= p.life) { p.el.remove(); parts.splice(i, 1); }
    }
    if (parts.length) requestAnimationFrame(tick);
  }
})();
