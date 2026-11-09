/// The single-page web control UI served at "/". Plain HTML/CSS/JS with no
/// external resources; it polls /api/state once a second and posts small
/// JSON commands to /api/action.
enum WebControlPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#16161a">
<title>SoundCast</title>
<style>
  :root {
    --bg: #16161a; --card: #222228; --line: #34343c; --text: #f2f2f5; --dim: #9a9aa6;
    --accent: #ff7a59; --live: #6ee8c7; --bad: #ff6b6b;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 16px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         padding: 16px 16px calc(24px + env(safe-area-inset-bottom)); }
  main { max-width: 560px; margin: 0 auto; }
  header { display: flex; align-items: center; gap: 10px; margin: 4px 0 16px; }
  header h1 { font-size: 20px; margin: 0; flex: 1; }
  header .mac { color: var(--dim); font-size: 14px; }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--dim); }
  .dot.on { background: var(--live); }
  .card { background: var(--card); border-radius: 16px; padding: 14px 16px; margin-bottom: 12px; }
  .row { display: flex; align-items: center; gap: 12px; min-height: 40px; }
  .row .name { flex: 1; min-width: 0; }
  .label { font-size: 13px; color: var(--dim); text-transform: uppercase; letter-spacing: .06em; margin: 18px 4px 8px; }
  .status { font-size: 13px; color: var(--dim); }
  .status.bad, .error { color: var(--bad); }
  .error { font-size: 13px; margin-top: 4px; }
  input[type=range] { width: 100%; accent-color: var(--accent); height: 28px; }
  .value { font-variant-numeric: tabular-nums; color: var(--dim); font-size: 14px; min-width: 64px; text-align: right; }
  .switch { position: relative; width: 52px; height: 32px; flex: none; }
  .switch input { opacity: 0; width: 100%; height: 100%; position: absolute; margin: 0; cursor: pointer; z-index: 1; }
  .switch span { position: absolute; inset: 0; background: var(--line); border-radius: 16px; transition: .2s; }
  .switch span::after { content: ""; position: absolute; width: 26px; height: 26px; left: 3px; top: 3px;
                        background: #fff; border-radius: 50%; transition: .2s; }
  .switch input:checked + span { background: var(--accent); }
  .switch input:checked + span::after { transform: translateX(20px); }
  .check { width: 26px; height: 26px; accent-color: var(--accent); flex: none; }
  .meter { height: 6px; background: var(--line); border-radius: 3px; overflow: hidden; margin-top: 8px; }
  .meter div { height: 100%; width: 0; background: var(--live); transition: width .25s; }
  .group { font-size: 13px; color: var(--dim); margin: 12px 0 2px; }
  .device { border-top: 1px solid var(--line); padding: 4px 0; }
  .device:first-of-type { border-top: 0; }
  .gain { padding: 0 0 6px 38px; }
  button { font: inherit; color: var(--text); background: var(--line); border: 0; border-radius: 10px;
           padding: 8px 14px; cursor: pointer; }
  button.primary { background: var(--accent); color: #1a1a1a; font-weight: 600; }
  button:disabled { opacity: .5; }
  .more { background: none; color: var(--dim); padding: 6px 4px; }
  .hint { font-size: 13px; color: var(--dim); margin-top: 6px; }
  .offline { text-align: center; color: var(--bad); margin: 40px 0; }
</style>
</head>
<body>
<main>
  <header><span class="dot" id="dot"></span><h1>SoundCast</h1><span class="mac" id="mac"></span></header>
  <div id="app"><p class="offline">Connecting…</p></div>
</main>
<script>
"use strict";
let state = null;
let busyUntil = 0;
const timers = {};
let expanded = new Set();
try { expanded = new Set(JSON.parse(localStorage.getItem("expanded") || "[]")); } catch (e) {}

const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const ms = v => (v > 0 ? "+" : "") + Math.round(v) + " ms";

function online(on) { document.getElementById("dot").className = "dot" + (on ? " on" : ""); }

async function poll() {
  try {
    const r = await fetch("/api/state", { cache: "no-store" });
    state = await r.json();
    online(true);
    if (Date.now() > busyUntil) render(); else renderMeters();
  } catch (e) { online(false); }
}

async function act(command) {
  try {
    const r = await fetch("/api/action", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(command) });
    state = await r.json();
    online(true);
    if (Date.now() > busyUntil) render();
  } catch (e) { online(false); }
}

function slider(key, command, final) {
  busyUntil = Date.now() + 1200;
  clearTimeout(timers[key]);
  if (final) act(command); else timers[key] = setTimeout(() => act(command), 150);
}

function renderMeters() {
  if (!state) return;
  for (const s of state.sources) {
    const el = document.querySelector('.meter div[data-source="' + CSS.escape(s.id) + '"]');
    if (el) el.style.width = (s.active ? Math.min(100, Math.sqrt(s.level) * 110) : 0) + "%";
  }
}

function render() {
  if (!state) return;
  document.getElementById("mac").textContent = state.mac;
  let h = "";
  h += '<div class="card"><div class="row"><span class="name">Master Volume</span><span class="value" id="v-master">' + Math.round(state.master * 100) + '%</span></div>';
  h += '<input type="range" min="0" max="100" value="' + Math.round(state.master * 100) + '" data-act="setMaster" data-scale="0.01" data-out="v-master" data-fmt="pct"></div>';

  h += '<div class="label">Sources</div>';
  for (const s of state.sources) {
    const open = expanded.has(s.id);
    h += '<div class="card"><div class="row"><span class="name">' + esc(s.name) + '</span>';
    h += '<label class="switch"><input type="checkbox" data-act="setActive" data-source="' + esc(s.id) + '"' + (s.active ? " checked" : "") + '><span></span></label></div>';
    if (s.error) h += '<div class="error">' + esc(s.error) + "</div>";
    h += '<div class="meter"><div data-source="' + esc(s.id) + '"></div></div>';
    h += '<button class="more" data-toggle="' + esc(s.id) + '">' + (open ? "▾ Rooms" : "▸ Rooms") + " (" + s.selected.length + " on)</button>";
    if (open) {
      for (const g of state.groups) {
        h += '<div class="group">' + esc(g.name) + "</div>";
        for (const d of g.devices) {
          const on = s.selected.includes(d.id);
          const status = d.unpaired ? "Pair on the Mac" : d.status;
          const bad = /fail|not found|pair/i.test(status);
          h += '<div class="device"><div class="row"><input class="check" type="checkbox" data-act="toggleDevice" data-source="' + esc(s.id) + '" data-device="' + esc(d.id) + '"' + (on ? " checked" : "") + '>';
          h += '<span class="name">' + esc(d.name) + (status ? '<br><span class="status' + (bad ? " bad" : "") + '">' + esc(status) + "</span>" : "") + "</span>";
          if (on && /failed|not found/i.test(d.status) && d.id.startsWith("sonos:")) h += '<button data-retry="' + esc(d.id) + '" data-source="' + esc(s.id) + '">Retry</button>';
          h += "</div>";
          if (on) {
            const g100 = Math.round((s.gains[d.id] ?? 1) * 100);
            h += '<div class="gain"><input type="range" min="0" max="100" value="' + g100 + '" data-act="setGain" data-scale="0.01" data-source="' + esc(s.id) + '" data-device="' + esc(d.id) + '"></div>';
          }
          h += "</div>";
        }
      }
    }
    h += "</div>";
  }

  h += '<div class="label">Sync</div><div class="card">';
  h += '<div class="row"><span class="name">AirPlay Sync</span><span class="value" id="v-air">' + ms(state.airplaySync) + "</span></div>";
  h += '<input type="range" min="-500" max="500" step="10" value="' + state.airplaySync + '" data-act="setAirPlaySync" data-out="v-air" data-fmt="ms">';
  h += '<div class="hint">This Mac’s speakers vs. the Apple TVs: right if the Mac plays first.</div>';
  h += '<div class="row" style="margin-top:10px"><span class="name">Video Sync</span><span class="value" id="v-video">' + ms(state.videoSync) + "</span></div>";
  h += '<input type="range" min="-500" max="500" step="10" value="' + state.videoSync + '" data-act="setVideoSync" data-out="v-video" data-fmt="ms">';
  h += '<div class="hint">Lip sync: right if the voice comes after the lips. Pause and play the video after changing it.</div>';
  h += '<div class="row" style="margin-top:12px"><button class="primary" data-calibrate' + (state.calibrating ? " disabled" : "") + ">" + (state.calibrating ? "Calibrating…" : "Calibrate Sync") + "</button></div>";
  if (state.calibrationStatus) h += '<div class="hint">' + esc(state.calibrationStatus) + "</div>";
  h += "</div>";

  document.getElementById("app").innerHTML = h;
  renderMeters();
}

document.addEventListener("input", e => {
  const t = e.target;
  if (t.type !== "range") return;
  const value = Number(t.value) * Number(t.dataset.scale || 1);
  if (t.dataset.out) document.getElementById(t.dataset.out).textContent = t.dataset.fmt === "pct" ? t.value + "%" : ms(Number(t.value));
  slider(t.dataset.act + (t.dataset.source || "") + (t.dataset.device || ""), { action: t.dataset.act, source: t.dataset.source, device: t.dataset.device, value }, false);
});

document.addEventListener("change", e => {
  const t = e.target;
  if (t.type === "range") {
    const value = Number(t.value) * Number(t.dataset.scale || 1);
    slider(t.dataset.act + (t.dataset.source || "") + (t.dataset.device || ""), { action: t.dataset.act, source: t.dataset.source, device: t.dataset.device, value }, true);
  } else if (t.dataset.act === "setActive") {
    act({ action: "setActive", source: t.dataset.source, on: t.checked });
  } else if (t.dataset.act === "toggleDevice") {
    act({ action: "toggleDevice", source: t.dataset.source, device: t.dataset.device });
  }
});

document.addEventListener("click", e => {
  const t = e.target.closest("button");
  if (!t) return;
  if (t.dataset.toggle) {
    const id = t.dataset.toggle;
    if (expanded.has(id)) expanded.delete(id); else expanded.add(id);
    try { localStorage.setItem("expanded", JSON.stringify([...expanded])); } catch (err) {}
    render();
  } else if (t.dataset.retry) {
    act({ action: "retry", source: t.dataset.source, device: t.dataset.retry });
  } else if ("calibrate" in t.dataset) {
    act({ action: "calibrate" });
  }
});

poll();
setInterval(poll, 1000);
</script>
</body>
</html>
"""#
}
