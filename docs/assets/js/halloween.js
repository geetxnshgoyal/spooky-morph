// The Halloween edition: cobwebs drawn the same way as the Mac app's Pumpkin wheel (Wheel.swift), on when
// <html> has the `halloween` class. A web in the page's corner and the demo desk's, each with a spider on a
// thread, and a round web in the demo wheel's hub.

export const isHalloween = document.documentElement.classList.contains('halloween');

const f = (n) => n.toFixed(1);

// Threads fanning out from the top-right corner of a `size` square, joined by rings that sag toward it.
export function cornerWebPath(size, threads = 6, rings = [0.22, 0.4, 0.58, 0.76, 0.94]) {
  const angles = Array.from({ length: threads }, (_, i) => (Math.PI / 2) * (i / (threads - 1)));
  const at = (a, r) => [size - r * Math.cos(a), r * Math.sin(a)];
  let d = '';
  for (const a of angles) {
    const [x, y] = at(a, size);
    d += `M${size} 0L${f(x)} ${f(y)}`;
  }
  rings.forEach((ring, k) => {
    const r = size * ring;
    for (let i = 0; i < threads - 1; i++) {
      // Hand-spun: each ring a touch uneven, each span sagging toward the corner.
      const wobble = ((i + k) % 3) * 0.012 * size;
      const [ax, ay] = at(angles[i], r + wobble), [bx, by] = at(angles[i + 1], r - wobble);
      const [cx, cy] = at((angles[i] + angles[i + 1]) / 2, r * 0.82);
      if (i === 0) d += `M${f(ax)} ${f(ay)}`;
      d += `Q${f(cx)} ${f(cy)} ${f(bx)} ${f(by)}`;
    }
  });
  return d;
}

// Spokes from the centre and rings that sag between them, for a hub of `radius` centred on 0,0.
export function hubWebPath(radius, spokes = 10, rings = [0.18, 0.36, 0.55, 0.74, 0.93]) {
  const at = (i, r) => {
    const a = (i / spokes) * 2 * Math.PI - Math.PI / 2;
    return [r * Math.cos(a), r * Math.sin(a)];
  };
  let d = '';
  for (let i = 0; i < spokes; i++) {
    const [x, y] = at(i, radius);
    d += `M0 0L${f(x)} ${f(y)}`;
  }
  for (const ring of rings) {
    const r = radius * ring;
    const [sx, sy] = at(0, r);
    d += `M${f(sx)} ${f(sy)}`;
    for (let i = 0; i < spokes; i++) {
      const [x, y] = at(i + 1, r), [cx, cy] = at(i + 0.5, r * 0.86);
      d += `Q${f(cx)} ${f(cy)} ${f(x)} ${f(y)}`;
    }
  }
  return d;
}

// A small spider seen from above: eight jointed legs, abdomen and head, two eyes in the accent.
function spiderSvg() {
  const legs = [[6, -6, 11, -2], [7, -2, 12, 2], [7, 2, 12, 7], [6, 5, 9, 10]];
  const d = legs.flatMap(([kx, ky, fx, fy]) => [1, -1].map((s) => `M13 11L${13 + s * kx} ${11 + ky}L${13 + s * fx} ${11 + fy}`)).join('');
  return `<svg class="spider" viewBox="0 0 26 22" aria-hidden="true">
    <path d="${d}" fill="none" stroke="#141414" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>
    <ellipse cx="13" cy="15" rx="4.5" ry="5" fill="#141414"/><circle cx="13" cy="8" r="3" fill="#141414"/>
    <circle cx="11.7" cy="7.2" r="0.8" class="spider-eye"/><circle cx="14.3" cy="7.2" r="0.8" class="spider-eye"/>
  </svg>`;
}

// Fills every [data-web="<size>"] with a corner web and a spider hanging from it.
export function hangWebs() {
  for (const el of document.querySelectorAll('[data-web]')) {
    const size = Number(el.dataset.web) || 160;
    el.innerHTML = `<svg class="web-lines" viewBox="0 0 ${size} ${size}" width="${size}" height="${size}" aria-hidden="true"><path d="${cornerWebPath(size)}"/></svg>
      <span class="web-thread" style="--drop:${Math.round(size * 0.62)}px">${spiderSvg()}</span>`;
  }
}
