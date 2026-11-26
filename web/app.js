// YTHelper front end: search, watch (ad-free 4K60 or official embed), download, settings.
const $ = (sel, el = document) => el.querySelector(sel);
const view = $("#view");
let settings = {};

const api = async (path, opts) => {
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || r.statusText);
  return r.json();
};
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const fmtTime = (s) => (s == null ? "" : new Date(s * 1000).toISOString().slice(s >= 3600 ? 11 : 14, 19));
const fmtViews = (n) => (n == null ? "" : Intl.NumberFormat("en", { notation: "compact" }).format(n) + " views");
function toast(msg, ms = 2500) {
  const t = Object.assign(document.createElement("div"), { className: "toast", textContent: msg });
  document.body.append(t);
  setTimeout(() => t.remove(), ms);
}

// ---------- settings / branding ----------
function applyBranding() {
  const v = settings.iconVersion;
  document.title = settings.inAppName;
  $("#brandName").textContent = settings.inAppName;
  $("#brandIcon").src = `/icons/inapp-192.png?v=${v}`;
  document.querySelector('link[rel="icon"]').href = `/icons/inapp-32.png?v=${v}`;
  document.querySelector('link[rel="apple-touch-icon"]').href = `/icons/home-180.png?v=${v}`;
  document.querySelector('link[rel="manifest"]').href = `/manifest.webmanifest?v=${v}`;
  document.querySelector('meta[name="apple-mobile-web-app-title"]').content = settings.homeName;
  $("#inappPreview").src = `/icons/inapp-192.png?v=${v}`;
  $("#homePreview").src = `/icons/home-192.png?v=${v}`;
}

function fillSettingsForm() {
  const f = $("#settingsForm");
  f.inAppName.value = settings.inAppName;
  f.homeName.value = settings.homeName;
  f.adsEnabled.checked = settings.adsEnabled;
  f.maxHeight.value = String(settings.maxHeight);
  f.maxFps.value = String(settings.maxFps);
  const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone;
  $("#installHint").textContent = standalone
    ? "Home Screen name/picture changes apply after you remove the app and add it to the Home Screen again (iOS/Android cache them at install)."
    : "To install: Share → Add to Home Screen (iOS) or ⋮ → Install app (Android/desktop).";
}

$("#settingsBtn").onclick = () => { fillSettingsForm(); $("#settings").showModal(); };

$("#saveSettings").onclick = async (e) => {
  e.preventDefault();
  const f = $("#settingsForm");
  const before = settings.adsEnabled;
  settings = await api("/api/settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      inAppName: f.inAppName.value,
      homeName: f.homeName.value,
      adsEnabled: f.adsEnabled.checked,
      maxHeight: +f.maxHeight.value,
      maxFps: +f.maxFps.value,
    }),
  });
  applyBranding();
  $("#settings").close();
  toast("Saved");
  if (before !== settings.adsEnabled || location.hash.startsWith("#/watch")) route();
};

document.querySelectorAll('input[type=file][data-kind]').forEach((inp) => {
  inp.onchange = async () => {
    if (!inp.files[0]) return;
    const fd = new FormData();
    fd.append("file", inp.files[0]);
    try {
      settings = await api(`/api/icon/${inp.dataset.kind}`, { method: "POST", body: fd });
      applyBranding();
      toast("Picture updated");
    } catch (err) { toast(err.message); }
    inp.value = "";
  };
});
document.querySelectorAll("[data-reset]").forEach((b) => {
  b.onclick = async () => {
    settings = await api(`/api/icon/${b.dataset.reset}`, { method: "DELETE" });
    applyBranding();
  };
});

// ---------- search ----------
$("#searchForm").onsubmit = (e) => {
  e.preventDefault();
  const q = $("#q").value.trim();
  if (q) location.hash = `#/search?q=${encodeURIComponent(q)}`;
};

function cards(items) {
  if (!items.length) return `<p class="empty">No results</p>`;
  return `<div class="grid">${items.map((v) => `
    <a class="card" href="#/watch/${v.id}">
      <img loading="lazy" src="${esc(v.thumb)}" alt="">
      <h3>${esc(v.title)}</h3>
      <div class="meta">${esc(v.channel)} · ${fmtViews(v.views)} ${v.duration ? "· " + fmtTime(v.duration) : ""}</div>
    </a>`).join("")}</div>`;
}

async function showSearch(q) {
  const seq = routeSeq;
  $("#q").value = q;
  view.innerHTML = `<p class="empty">Searching…</p>`;
  let html;
  try { html = cards(await api(`/api/search?q=${encodeURIComponent(q)}`)); }
  catch (err) { html = `<p class="empty">${esc(err.message)}</p>`; }
  if (seq === routeSeq) view.innerHTML = html;
}

function showHome() {
  const history = JSON.parse(safeGet("history") || "[]");
  view.innerHTML = history.length
    ? `<h2>Recently watched</h2>${cards(history)}`
    : `<p class="empty">Search for a video to get started.</p>`;
}

// ---------- watch ----------
function safeGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function safeSet(k, v) { try { localStorage.setItem(k, v); } catch {} }
function remember(v) {
  const h = JSON.parse(safeGet("history") || "[]").filter((x) => x.id !== v.id);
  h.unshift({ id: v.id, title: v.title, channel: v.channel, views: v.views, duration: v.duration, thumb: `https://i.ytimg.com/vi/${v.id}/hqdefault.jpg` });
  safeSet("history", JSON.stringify(h.slice(0, 24)));
}

const probe = document.createElement("video");
const canPlay = (mime) =>
  (window.MediaSource?.isTypeSupported?.(mime) ?? false) || probe.canPlayType(mime) === "probably";

// Build the quality list: DASH video-only formats (need a separate audio track) plus
// progressive formats (audio+video in one file) as a fallback for heights DASH can't cover.
function playableOptions(info) {
  const rank = (c) => (/^av01/.test(c) ? 3 : /^vp0?9/.test(c) ? 2 : 1); // AV1 > VP9 > H.264
  const audio = info.audioFormats.find((a) => canPlay(a.mime));
  const best = new Map();
  const consider = (f, muxed) => {
    if (!canPlay(f.mime)) return;
    const key = `${f.height}p${f.fps > 30 ? f.fps : ""}`;
    const cur = best.get(key);
    // DASH (with a playable audio track) beats progressive at the same size; then codec rank
    const score = (muxed ? 0 : 10) + rank(f.vcodec);
    if (!cur || score > cur.score) best.set(key, { ...f, muxed, score, label: key });
  };
  if (audio) info.videoFormats.forEach((f) => consider(f, false));
  (info.muxedFormats || []).forEach((f) => consider(f, true));
  const options = [...best.values()].sort((a, b) => b.height - a.height || b.fps - a.fps);
  return { options, audio };
}

let routeSeq = 0; // bumps on every navigation so slow responses can't overwrite a newer page

async function showWatch(id) {
  const seq = routeSeq;
  const stale = () => seq !== routeSeq;
  view.innerHTML = `
    <div class="player" id="player"></div>
    <h2 id="title"></h2>
    <div class="toolbar" id="toolbar"><span class="meta">Loading…</span></div>
    <div class="desc" id="desc" hidden></div>`;

  // Official player doesn't depend on our extractor, so show it straight away.
  if (settings.adsEnabled) {
    $("#player").innerHTML = `<iframe src="https://www.youtube.com/embed/${id}?autoplay=1&playsinline=1"
      allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>`;
  }

  let info;
  try { info = await api(`/api/video/${id}`); }
  catch (err) {
    if (stale()) return;
    $("#toolbar").innerHTML = `<span class="meta">Couldn't load details: ${esc(err.message)}</span>`;
    if (!settings.adsEnabled) $("#player").innerHTML = `<p class="empty">Stream unavailable — turn on “Show ads” to use the official player.</p>`;
    return;
  }
  if (stale()) return;
  remember(info);

  $("#title").textContent = info.title || "";
  const desc = $("#desc");
  desc.textContent = info.description || "";
  desc.hidden = !info.description;

  const { options, audio } = playableOptions(info);
  const start = options.find((f) => f.height <= settings.maxHeight && f.fps <= settings.maxFps) || options.at(-1);

  $("#toolbar").innerHTML = `
    <span class="meta">${esc(info.channel)} · ${fmtViews(info.views)}</span>
    ${settings.adsEnabled ? `<span class="badge">Official player (ads on)</span>` : `
      <select id="quality" aria-label="Quality">${options.map((f, i) =>
        `<option value="${i}" ${f === start ? "selected" : ""}>${f.label} · ${esc(f.vcodec.split(".")[0])}</option>`).join("")}
      </select><span class="badge">No ads</span>`}
    <select id="dlQuality" aria-label="Download quality">
      <option value="2160">Download 4K60</option>
      <option value="1440">Download 1440p</option>
      <option value="1080">Download 1080p</option>
      <option value="720">Download 720p</option>
      <option value="audio">Download audio only</option>
    </select>
    <button id="dlBtn">⬇ Download</button>`;

  $("#dlBtn").onclick = () => {
    const q = $("#dlQuality").value;
    const qs = q === "audio" ? "audio_only=true" : `height=${q}&fps=60`;
    toast("Preparing download… large 4K files can take a while", 4000);
    const a = Object.assign(document.createElement("a"), { href: `/api/download/${id}?${qs}`, download: "" });
    document.body.append(a); a.click(); a.remove();
  };

  if (settings.adsEnabled) return;
  if (!start) {
    $("#player").innerHTML = `<p class="empty">No stream this browser can play — try “Show ads” or download it.</p>`;
    return;
  }
  const player = mountPlayer($("#player"), id, start, audio);
  $("#quality").onchange = (e) => player.switchTo(options[+e.target.value]);
}

// YouTube serves 1080p+ (and 60fps above 720p) as separate video and audio streams, so
// DASH formats play in a <video> + <audio> pair with the audio locked to the video.
// Progressive formats play in the <video> alone.
function mountPlayer(host, id, fmt, audioFmt) {
  const video = Object.assign(document.createElement("video"), { controls: true, autoplay: true, playsInline: true, preload: "auto" });
  const audio = Object.assign(document.createElement("audio"), { preload: "auto" });
  host.replaceChildren(video, audio);
  let separate = false;

  const sync = () => { if (separate && Math.abs(audio.currentTime - video.currentTime) > 0.25) audio.currentTime = video.currentTime; };
  const playAudio = () => { if (separate) { sync(); audio.play().catch(() => {}); } };
  video.addEventListener("play", playAudio);
  video.addEventListener("playing", playAudio);
  video.addEventListener("pause", () => audio.pause());
  video.addEventListener("waiting", () => audio.pause());
  video.addEventListener("seeked", sync);
  video.addEventListener("ratechange", () => { audio.playbackRate = video.playbackRate; });
  video.addEventListener("volumechange", () => { audio.volume = video.volume; audio.muted = video.muted; });
  const timer = setInterval(() => {
    if (!video.isConnected) { clearInterval(timer); video.pause(); audio.pause(); video.removeAttribute("src"); audio.removeAttribute("src"); }
    else if (!video.paused) sync();
  }, 1000);

  function load(f, resumeAt = 0, playing = true) {
    separate = !f.muxed && !!audioFmt;
    audio.pause();
    if (separate) audio.src = `/api/proxy/${id}/${audioFmt.id}`; else audio.removeAttribute("src");
    video.src = `/api/proxy/${id}/${f.id}`;
    video.addEventListener("loadedmetadata", () => {
      if (resumeAt) video.currentTime = resumeAt;
      if (playing) video.play().catch(() => {});
    }, { once: true });
  }
  load(fmt);
  return { switchTo: (f) => load(f, video.currentTime, !video.paused) };
}

// ---------- router ----------
function route() {
  routeSeq++;
  const h = location.hash || "#/";
  if (h.startsWith("#/watch/")) return showWatch(h.slice(8));
  if (h.startsWith("#/search")) return showSearch(new URLSearchParams(h.split("?")[1]).get("q") || "");
  showHome();
}
addEventListener("hashchange", route);

(async () => {
  settings = await api("/api/settings");
  applyBranding();
  route();
})();
