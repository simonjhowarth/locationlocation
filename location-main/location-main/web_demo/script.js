// Enhanced JS demo: Kalman smoothing, live params, distance filter, geofence
class OneDKalman {
  constructor(q = 1e-4, r = 5e-3) {
    this.q = q; this.r = r; this.x = null; this.p = 1.0; this.initialized = false;
  }
  filter(z) {
    if (!this.initialized) { this.x = z; this.initialized = true; return this.x; }
    this.p = this.p + this.q;
    const k = this.p / (this.p + this.r);
    this.x = this.x + k * (z - this.x);
    this.p = (1 - k) * this.p;
    return this.x;
  }
  reset() { this.initialized = false; this.p = 1.0; this.x = null; }
}

function gaussianRandom(mean = 0, stddev = 1) {
  let u = 0, v = 0; while (u === 0) u = Math.random(); while (v === 0) v = Math.random();
  return Math.sqrt(-2.0 * Math.log(u)) * Math.cos(2.0 * Math.PI * v) * stddev + mean;
}

const canvas = document.getElementById('plot');
const ctx = canvas.getContext('2d');
const rawEl = document.getElementById('raw');
const filtEl = document.getElementById('filtered');
const dropsEl = document.getElementById('drops');
const logEl = document.getElementById('log');

let interval = 250; let timer = null; let t = 0; let drops = 0;
let kf = new OneDKalman(1e-4, 5e-3); let kf2 = new OneDKalman(1e-4, 5e-3);
let lastX = null;
const rawPoints = []; const filtPoints = [];

function log(msg) {
  if (document.getElementById('showLogs').checked) {
    logEl.textContent = `[${new Date().toISOString()}] ${msg}\n` + logEl.textContent;
  }
}

function draw(pointsRaw, pointsFilt) {
  ctx.clearRect(0,0,canvas.width,canvas.height);
  ctx.strokeStyle = '#eee'; for (let i=0;i<canvas.height;i+=20) { ctx.beginPath(); ctx.moveTo(0,i); ctx.lineTo(canvas.width,i); ctx.stroke(); }
  const margin = 20; const w = canvas.width - margin*2; const h = canvas.height - margin*2;
  const n = Math.max(pointsRaw.length, 1);
  const all = pointsRaw.concat(pointsFilt); if (all.length === 0) return; const min = Math.min(...all); const max = Math.max(...all);
  const range = Math.max(1e-6, max - min);

  // draw geofence band
  const gfEnabled = document.getElementById('gf_enabled').checked;
  if (gfEnabled) {
    const gfCenter = Number(document.getElementById('gf_center').value) || 0;
    const gfRadius = Number(document.getElementById('gf_radius').value) || 50;
    const yTop = margin + h - (((gfCenter + gfRadius) - min) / range) * h;
    const yBottom = margin + h - (((gfCenter - gfRadius) - min) / range) * h;
    ctx.fillStyle = 'rgba(0,150,0,0.06)'; ctx.fillRect(margin, Math.min(yTop,yBottom), w, Math.abs(yBottom - yTop));
  }

  // raw
  ctx.beginPath(); ctx.strokeStyle = '#f55';
  for (let i=0;i<pointsRaw.length;i++) { const x = margin + (i / n) * w; const y = margin + h - ((pointsRaw[i]-min)/range)*h; if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y); }
  ctx.stroke();

  // filtered
  ctx.beginPath(); ctx.strokeStyle = '#1aaf6b';
  for (let i=0;i<pointsFilt.length;i++) { const x = margin + (i / n) * w; const y = margin + h - ((pointsFilt[i]-min)/range)*h; if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y); }
  ctx.stroke();
}

function step() {
  const noise = Number(document.getElementById('noise').value);
  const trueX = t * 1.2; const measured = trueX + gaussianRandom(0, noise);

  let drop = false;
  if (lastX != null) { const dist = Math.abs(measured - lastX); if (dist > 200 && noise > 20) { drop = true; drops++; dropsEl.textContent = drops; log(`Dropped jump: ${dist.toFixed(1)}m (noise ${noise})`); } }

  if (!drop) {
    const distanceFilter = Number(document.getElementById('distanceFilter').value) || 0;
    if (distanceFilter > 0 && lastX != null) { const d = Math.abs(measured - lastX); if (d < distanceFilter) { log(`Skipped update (distance ${d.toFixed(2)} < ${distanceFilter})`); t += 1; return; } }

    const qVal = Number(document.getElementById('kf_q').value) || 0.0001;
    const rVal = Number(document.getElementById('kf_r').value) || 0.005;
    if (Math.abs(kf.q - qVal) > 0 || Math.abs(kf.r - rVal) > 0) {
      kf = new OneDKalman(qVal, rVal); kf2 = new OneDKalman(qVal, rVal); if (lastX != null) { kf.filter(lastX); kf2.filter(lastX + 0.0001); } log(`Updated Kalman params q=${qVal}, r=${rVal}`);
    }

    const fLat = kf.filter(measured);
    const fLng = kf2.filter(measured + 0.0001);

    rawPoints.push(measured); filtPoints.push(fLat); if (rawPoints.length > 200) rawPoints.shift(); if (filtPoints.length > 200) filtPoints.shift(); lastX = measured;
    rawEl.textContent = measured.toFixed(3) + ' m'; filtEl.textContent = fLat.toFixed(3) + ' m';

    // geofence state
    const gfEnabled2 = document.getElementById('gf_enabled').checked;
    if (gfEnabled2) {
      const gfCenter = Number(document.getElementById('gf_center').value) || 0; const gfRadius = Number(document.getElementById('gf_radius').value) || 50;
      const inside = Math.abs(trueX - gfCenter) <= gfRadius;
      dropsEl.className = inside ? 'status-inside' : 'status-outside';
    }

    // filtered view toggle
    const showFilteredOnly = document.getElementById('showFilteredOnly').checked;
    if (showFilteredOnly) draw([], filtPoints); else draw(rawPoints, filtPoints);
    log(`Raw ${measured.toFixed(3)}, Filtered ${fLat.toFixed(3)}`);
  }
  t += 1;
}

document.getElementById('start').addEventListener('click', () => { interval = Number(document.getElementById('interval').value) || 250; if (timer) clearInterval(timer); timer = setInterval(step, interval); document.getElementById('start').disabled = true; document.getElementById('stop').disabled = false; log('Started demo'); });
document.getElementById('stop').addEventListener('click', () => { if (timer) clearInterval(timer); timer = null; document.getElementById('start').disabled = false; document.getElementById('stop').disabled = true; log('Stopped demo'); });
document.getElementById('interval').addEventListener('change', () => { if (timer) { clearInterval(timer); timer = setInterval(step, Number(document.getElementById('interval').value)); } });

document.getElementById('reset').addEventListener('click', () => { kf.reset(); kf2.reset(); rawPoints.length = 0; filtPoints.length = 0; lastX = null; t = 0; drops = 0; dropsEl.textContent = '0'; log('Filters and data reset'); draw([],[]); });

// initial draw
draw([],[]);
// Simple JS Kalman filter (1D)
class OneDKalman {
  constructor(q = 1e-4, r = 5e-3) {
    this.q = q;
    this.r = r;
    this.x = null;
    this.p = 1.0;
    this.initialized = false;
  }
  filter(z) {
    if (!this.initialized) {
      this.x = z;
      this.initialized = true;
      return this.x;
    }
    this.p = this.p + this.q;
    const k = this.p / (this.p + this.r);
    this.x = this.x + k * (z - this.x);
    this.p = (1 - k) * this.p;
    return this.x;
  }
  reset() { this.initialized = false; this.p = 1.0; this.x = null; }
}

// Utilities
function gaussianRandom(mean = 0, stddev = 1) {
  let u = 0, v = 0;
  while (u === 0) u = Math.random();
  while (v === 0) v = Math.random();
  const num = Math.sqrt(-2.0 * Math.log(u)) * Math.cos(2.0 * Math.PI * v);
  return num * stddev + mean;
}

const canvas = document.getElementById('plot');
const ctx = canvas.getContext('2d');
const rawEl = document.getElementById('raw');
const filtEl = document.getElementById('filtered');
const dropsEl = document.getElementById('drops');
const logEl = document.getElementById('log');

let interval = 250;
let timer = null;
let t = 0;
let drops = 0;

const kf = new OneDKalman(1e-4, 5e-3);
const kf2 = new OneDKalman(1e-4, 5e-3);
let lastX = null;

function log(msg) {
  if (document.getElementById('showLogs').checked) {
    logEl.textContent = `[${new Date().toISOString()}] ${msg}\n` + logEl.textContent;
  }
}

function draw(pointsRaw, pointsFilt) {
  ctx.clearRect(0,0,canvas.width,canvas.height);
  // draw grid
  ctx.strokeStyle = '#eee';
  for (let i=0;i<canvas.height;i+=20) { ctx.beginPath(); ctx.moveTo(0,i); ctx.lineTo(canvas.width,i); ctx.stroke(); }

  // scale
  const margin = 20;
  const w = canvas.width - margin*2;
  const h = canvas.height - margin*2;
  const n = Math.max(pointsRaw.length, 1);
  const all = pointsRaw.concat(pointsFilt);
  const min = Math.min(...all);
  const max = Math.max(...all);
  const range = Math.max(1e-6, max - min);

  // raw
  ctx.beginPath(); ctx.strokeStyle = '#f55';
  for (let i=0;i<pointsRaw.length;i++) {
    const x = margin + (i / n) * w;
    const y = margin + h - ((pointsRaw[i]-min)/range)*h;
    if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  }
  ctx.stroke();

  // filtered
  ctx.beginPath(); ctx.strokeStyle = '#1aaf6b';
  for (let i=0;i<pointsFilt.length;i++) {
    const x = margin + (i / n) * w;
    const y = margin + h - ((pointsFilt[i]-min)/range)*h;
    if (i===0) ctx.moveTo(x,y); else ctx.lineTo(x,y);
  }
  ctx.stroke();
}

const rawPoints = [];
const filtPoints = [];

function step() {
  const noise = Number(document.getElementById('noise').value);
  // simulate movement along X axis (meters from origin)
  const trueX = t * 1.2; // 1.2 m per tick
  const measured = trueX + gaussianRandom(0, noise);

  // simple speed/accuracy guard: if jump > 200m since last and noise large, drop
  let drop = false;
  if (lastX != null) {
    const dist = Math.abs(measured - lastX);
    if (dist > 200 && noise > 20) { drop = true; drops++; dropsEl.textContent = drops; log(`Dropped jump: ${dist.toFixed(1)}m (noise ${noise})`); }
  }

  if (!drop) {
    const fLat = kf.filter(measured);
    const fLng = kf2.filter(measured + 0.0001); // small offset to show two filtered lines if desired
    rawPoints.push(measured);
    filtPoints.push(fLat);
    if (rawPoints.length > 200) rawPoints.shift();
    if (filtPoints.length > 200) filtPoints.shift();
    lastX = measured;
    rawEl.textContent = measured.toFixed(3) + ' m';
    filtEl.textContent = fLat.toFixed(3) + ' m';
    draw(rawPoints, filtPoints);
    log(`Raw ${measured.toFixed(3)}, Filtered ${fLat.toFixed(3)}`);
  }

  t += 1;
}

document.getElementById('start').addEventListener('click', () => {
  interval = Number(document.getElementById('interval').value) || 250;
  if (timer) clearInterval(timer);
  timer = setInterval(step, interval);
  document.getElementById('start').disabled = true;
  document.getElementById('stop').disabled = false;
  log('Started demo');
});

document.getElementById('stop').addEventListener('click', () => {
  if (timer) clearInterval(timer);
  timer = null;
  document.getElementById('start').disabled = false;
  document.getElementById('stop').disabled = true;
  log('Stopped demo');
});

// allow changing interval while running
document.getElementById('interval').addEventListener('change', () => {
  if (timer) { clearInterval(timer); timer = setInterval(step, Number(document.getElementById('interval').value)); }
});

// init draw
draw([],[]);
