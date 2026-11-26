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
  $("#q").value = q;
  view.innerHTML = `<p class="empty">Searching…</p>`;
  try {
    const items = await api(`/api/search?q=${encodeURIComponent(q)}`);
    view.innerHTML = cards(items);
  } catch (err) { view.innerHTML = `<p class="empty">${esc(err.message)}</p>`; }
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

function playableVideoFormats(info) {
  // Keep the best playable format per (height, fps); prefer AV1 > VP9 > H.264 at equal size.
  const rank = (c) => (/^av01/.test(c) ? 3 : /^vp0?9/.test(c) ? 2 : 1);
  const best = new Map();
  for (const f of info.videoFormats) {
    if (!canPlay(f.mime)) continue;
    const key = `${f.height}p${f.fps > 30 ? f.fps : ""}`;
    const cur = best.get(key);
    if (!cur || rank(f.vcodec) > rank(cur.vcodec)) best.set(key, f);
  }
  return [...best.values()].sort((a, b) => b.height - a.height || b.fps - a.fps);
}

async function showWatch(id) {
  view.innerHTML = `<p class="empty">Loading…</p>`;
  let info;
  try { info = await api(`/api/video/${id}`); }
  catch (err) { view.innerHTML = `<p class="empty">${esc(err.message)}</p>`; return; }
  remember(info);

  const formats = playableVideoFormats(info);
  const audio = info.audioFormats.find((a) => canPlay(a.mime)) || info.audioFormats[0];
  const start = formats.find((f) => f.height <= settings.maxHeight && f.fps <= settings.maxFps) || formats.at(-1);

  view.innerHTML = `
    <div class="player" id="player"></div>
    <h2>${esc(info.title)}</h2>
    <div class="toolbar">
      <span class="meta">${esc(info.channel)} · ${fmtViews(info.views)}</span>
      ${settings.adsEnabled ? `<span class="badge">Official player (ads on)</span>` : `
        <select id="quality" aria-label="Quality">${formats.map((f) =>
          `<option value="${f.id}" ${f === start ? "selected" : ""}>${f.height}p${f.fps > 30 ? f.fps : ""} · ${f.vcodec.split(".")[0]}</option>`).join("")}
        </select><span class="badge">No ads</span>`}
      <select id="dlQuality" aria-label="Download quality">
        <option value="2160">Download 4K60</option>
        <option value="1440">Download 1440p</option>
        <option value="1080">Download 1080p</option>
        <option value="720">Download 720p</option>
        <option value="audio">Download audio only</option>
      </select>
      <button id="dlBtn">⬇ Download</button>
    </div>
    <div class="desc">${esc(info.description)}</div>`;

  $("#dlBtn").onclick = () => {
    const q = $("#dlQuality").value;
    const qs = q === "audio" ? "audio_only=true" : `height=${q}&fps=60`;
    toast("Preparing download… large 4K files can take a while", 4000);
    const a = Object.assign(document.createElement("a"), { href: `/api/download/${id}?${qs}`, download: "" });
    document.body.append(a); a.click(); a.remove();
  };

  if (settings.adsEnabled) {
    $("#player").innerHTML = `<iframe src="https://www.youtube.com/embed/${id}?autoplay=1&playsinline=1"
      allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>`;
    return;
  }
  if (!start || !audio) {
    $("#player").innerHTML = `<p class="empty">No playable stream found</p>`;
    return;
  }
  const player = mountSyncedPlayer($("#player"), id, start.id, audio.id);
  $("#quality").onchange = (e) => player.switchVideo(e.target.value);
}

// YouTube serves 1080p+ (and all 60fps above 720p) as separate video and audio
// streams, so we play them in two elements and keep the audio locked to the video.
function mountSyncedPlayer(host, id, videoFmt, audioFmt) {
  const video = Object.assign(document.createElement("video"), {
    controls: true, autoplay: true, playsInline: true, preload: "auto",
    src: `/api/proxy/${id}/${videoFmt}`,
  });
  const audio = Object.assign(document.createElement("audio"), { preload: "auto", src: `/api/proxy/${id}/${audioFmt}` });
  host.replaceChildren(video, audio);

  const sync = () => { if (Math.abs(audio.currentTime - video.currentTime) > 0.25) audio.currentTime = video.currentTime; };
  video.addEventListener("play", () => { sync(); audio.play().catch(() => {}); });
  video.addEventListener("pause", () => audio.pause());
  video.addEventListener("waiting", () => audio.pause());
  video.addEventListener("playing", () => { sync(); audio.play().catch(() => {}); });
  video.addEventListener("seeked", sync);
  video.addEventListener("ratechange", () => { audio.playbackRate = video.playbackRate; });
  video.addEventListener("volumechange", () => { audio.volume = video.volume; audio.muted = video.muted; });
  const timer = setInterval(() => { if (!video.isConnected) { clearInterval(timer); audio.pause(); audio.src = ""; } else if (!video.paused) sync(); }, 1000);

  return {
    switchVideo(fmt) {
      const t = video.currentTime, playing = !video.paused;
      video.src = `/api/proxy/${id}/${fmt}`;
      video.addEventListener("loadedmetadata", () => { video.currentTime = t; if (playing) video.play(); }, { once: true });
    },
  };
}

// ---------- router ----------
function route() {
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
