"""YTHelper backend: search, 4K60 streams, downloads and the customizable PWA shell."""
from __future__ import annotations

import io
import json
import re
import shutil
import tempfile
import time
from pathlib import Path

import httpx
import yt_dlp
from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
from starlette.background import BackgroundTask
from starlette.concurrency import run_in_threadpool

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)
SETTINGS_FILE = DATA / "settings.json"
ICON_DIR = DATA / "icons"
ICON_DIR.mkdir(exist_ok=True)

DEFAULTS = {
    "inAppName": "YTHelper",      # shown in the header / tab title
    "homeName": "YTHelper",       # shown under the Home Screen icon
    "adsEnabled": False,          # False = direct stream (no ads), True = official embed
    "maxHeight": 2160,
    "maxFps": 60,
}
ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
ICON_KINDS = ("inapp", "home")

app = FastAPI(title="YTHelper")


@app.exception_handler(yt_dlp.utils.DownloadError)
async def ytdlp_error(_req: Request, exc: yt_dlp.utils.DownloadError):
    return JSONResponse({"detail": str(exc).removeprefix("ERROR: ")}, status_code=502)


# ---------- settings ----------
def load_settings() -> dict:
    s = dict(DEFAULTS)
    if SETTINGS_FILE.exists():
        s.update(json.loads(SETTINGS_FILE.read_text()))
    s["iconVersion"] = s.get("iconVersion", 0)
    return s


def save_settings(s: dict) -> None:
    SETTINGS_FILE.write_text(json.dumps(s, indent=2))


@app.get("/api/settings")
def get_settings():
    return load_settings()


@app.post("/api/settings")
async def post_settings(req: Request):
    body = await req.json()
    s = load_settings()
    for key in ("inAppName", "homeName"):
        if key in body:
            val = str(body[key]).strip()[:40]
            s[key] = val or DEFAULTS[key]
    if "adsEnabled" in body:
        s["adsEnabled"] = bool(body["adsEnabled"])
    if "maxHeight" in body:
        s["maxHeight"] = int(body["maxHeight"])
    if "maxFps" in body:
        s["maxFps"] = int(body["maxFps"])
    save_settings(s)
    return s


@app.post("/api/icon/{kind}")
async def upload_icon(kind: str, file: UploadFile = File(...)):
    if kind not in ICON_KINDS:
        raise HTTPException(404)
    raw = await file.read()
    if len(raw) > 10 * 1024 * 1024:
        raise HTTPException(413, "Icon too large (max 10 MB)")
    try:
        img = Image.open(io.BytesIO(raw)).convert("RGBA")
    except Exception:
        raise HTTPException(400, "Not an image")
    # square-crop from the centre, then save a 512px master
    side = min(img.size)
    left, top = (img.width - side) // 2, (img.height - side) // 2
    img = img.crop((left, top, left + side, top + side)).resize((512, 512), Image.LANCZOS)
    img.save(ICON_DIR / f"{kind}.png")
    s = load_settings()
    s["iconVersion"] = s.get("iconVersion", 0) + 1
    save_settings(s)
    return s


@app.delete("/api/icon/{kind}")
def reset_icon(kind: str):
    if kind not in ICON_KINDS:
        raise HTTPException(404)
    (ICON_DIR / f"{kind}.png").unlink(missing_ok=True)
    s = load_settings()
    s["iconVersion"] = s.get("iconVersion", 0) + 1
    save_settings(s)
    return s


def default_icon() -> Image.Image:
    """Red rounded square with a white play triangle, drawn so the repo needs no binary assets."""
    from PIL import ImageDraw

    img = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, 511, 511), radius=112, fill=(255, 0, 51, 255))
    d.polygon([(200, 150), (200, 362), (372, 256)], fill=(255, 255, 255, 255))
    return img


@app.get("/icons/{kind}-{size}.png")
def icon(kind: str, size: int):
    if kind not in ICON_KINDS or size not in (32, 180, 192, 512):
        raise HTTPException(404)
    src = ICON_DIR / f"{kind}.png"
    img = Image.open(src).convert("RGBA") if src.exists() else default_icon()
    if kind == "home" or size == 180:
        # Home Screen icons must not be transparent (iOS fills transparency with black)
        bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
        bg.alpha_composite(img)
        img = bg.convert("RGB")
    img = img.resize((size, size), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return Response(buf.getvalue(), media_type="image/png", headers={"Cache-Control": "no-cache"})


@app.get("/manifest.webmanifest")
def manifest():
    s = load_settings()
    v = s["iconVersion"]
    return JSONResponse(
        {
            "name": s["homeName"],
            "short_name": s["homeName"],
            "start_url": "/",
            "display": "standalone",
            "background_color": "#0f0f0f",
            "theme_color": "#0f0f0f",
            "icons": [
                {"src": f"/icons/home-192.png?v={v}", "sizes": "192x192", "type": "image/png"},
                {"src": f"/icons/home-512.png?v={v}", "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
            ],
        },
        media_type="application/manifest+json",
        headers={"Cache-Control": "no-cache"},
    )


@app.get("/", response_class=HTMLResponse)
def index():
    """Serve index.html with the names/icons baked in, because iOS reads
    apple-mobile-web-app-title and apple-touch-icon from the HTML at install time."""
    s = load_settings()
    html = (WEB / "index.html").read_text()
    esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")
    html = (
        html.replace("{{IN_APP_NAME}}", esc(s["inAppName"]))
        .replace("{{HOME_NAME}}", esc(s["homeName"]))
        .replace("{{ICON_V}}", str(s["iconVersion"]))
    )
    return HTMLResponse(html, headers={"Cache-Control": "no-cache"})


# ---------- YouTube ----------
YDL_BASE = {"quiet": True, "no_warnings": True, "skip_download": True}


def check_id(vid: str) -> str:
    if not ID_RE.match(vid):
        raise HTTPException(400, "Bad video id")
    return vid


@app.get("/api/search")
def search(q: str, n: int = 20):
    n = max(1, min(n, 50))
    with yt_dlp.YoutubeDL({**YDL_BASE, "extract_flat": True}) as ydl:
        res = ydl.extract_info(f"ytsearch{n}:{q}", download=False)
    out = []
    for e in res.get("entries") or []:
        if not e or not e.get("id") or not ID_RE.match(e["id"]):
            continue
        out.append(
            {
                "id": e["id"],
                "title": e.get("title"),
                "channel": e.get("channel") or e.get("uploader"),
                "duration": e.get("duration"),
                "views": e.get("view_count"),
                "thumb": f"https://i.ytimg.com/vi/{e['id']}/hqdefault.jpg",
            }
        )
    return out


_INFO_CACHE: dict[str, tuple[float, dict]] = {}
INFO_TTL = 60 * 60  # stream URLs last ~6h; refresh hourly


def get_info(vid: str) -> dict:
    """Extract video info once and reuse it, since every Range request of the
    player hits /api/proxy and extraction takes seconds."""
    now = time.time()
    hit = _INFO_CACHE.get(vid)
    if hit and now - hit[0] < INFO_TTL:
        return hit[1]
    with yt_dlp.YoutubeDL(YDL_BASE) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={vid}", download=False)
    if len(_INFO_CACHE) > 200:
        _INFO_CACHE.clear()
    _INFO_CACHE[vid] = (now, info)
    return info


def mime_of(f: dict) -> str:
    ext = f.get("ext")
    codec = f.get("vcodec") if f.get("vcodec") not in (None, "none") else f.get("acodec")
    container = "video" if f.get("vcodec") not in (None, "none") else "audio"
    return f'{container}/{"mp4" if ext in ("mp4", "m4a") else ext}; codecs="{codec}"'


@app.get("/api/video/{vid}")
def video(vid: str):
    info = get_info(check_id(vid))
    videos, audios = [], []
    for f in info.get("formats") or []:
        if f.get("protocol") not in ("https", "http") or not f.get("url"):
            continue
        has_v = f.get("vcodec") not in (None, "none")
        has_a = f.get("acodec") not in (None, "none")
        entry = {"id": f["format_id"], "ext": f.get("ext"), "mime": mime_of(f), "tbr": f.get("tbr") or 0}
        if has_v and not has_a:
            videos.append({**entry, "height": f.get("height") or 0, "fps": f.get("fps") or 30, "vcodec": f.get("vcodec")})
        elif has_a and not has_v:
            audios.append({**entry, "acodec": f.get("acodec"), "abr": f.get("abr") or 0})
    videos.sort(key=lambda f: (f["height"], f["fps"], f["tbr"]), reverse=True)
    audios.sort(key=lambda f: f["abr"], reverse=True)
    return {
        "id": vid,
        "title": info.get("title"),
        "channel": info.get("channel") or info.get("uploader"),
        "description": info.get("description"),
        "duration": info.get("duration"),
        "views": info.get("view_count"),
        "thumb": info.get("thumbnail"),
        "videoFormats": videos,
        "audioFormats": audios,
    }


@app.get("/api/proxy/{vid}/{fmt}")
async def proxy(vid: str, fmt: str, request: Request):
    """Stream one DASH format through the server with Range support.
    Needed because googlevideo URLs are bound to the server's IP."""
    check_id(vid)
    info = await run_in_threadpool(get_info, vid)  # yt-dlp is blocking
    f = next((f for f in info.get("formats") or [] if f["format_id"] == fmt), None)
    if not f:
        raise HTTPException(404, "Format not found")
    headers = dict(f.get("http_headers") or {})
    if rng := request.headers.get("range"):
        headers["Range"] = rng
    client = httpx.AsyncClient(timeout=None, follow_redirects=True)
    upstream = await client.send(client.build_request("GET", f["url"], headers=headers), stream=True)
    passthru = {
        k: v for k, v in upstream.headers.items()
        if k.lower() in ("content-length", "content-range", "accept-ranges", "content-type")
    }
    passthru.setdefault("Accept-Ranges", "bytes")

    async def close():
        await upstream.aclose()
        await client.aclose()

    return StreamingResponse(
        upstream.aiter_raw(), status_code=upstream.status_code, headers=passthru, background=BackgroundTask(close)
    )


@app.get("/api/download/{vid}")
def download(vid: str, height: int = 2160, fps: int = 60, audio_only: bool = False):
    check_id(vid)
    if not shutil.which("ffmpeg"):
        raise HTTPException(500, "ffmpeg is required for downloads")
    tmp = Path(tempfile.mkdtemp(prefix="yth-"))
    fmt = "ba/b" if audio_only else f"bv*[height<={height}][fps<={fps}]+ba/b[height<={height}]"
    opts = {
        "quiet": True,
        "no_warnings": True,
        "format": fmt,
        "outtmpl": str(tmp / "%(title).80s [%(id)s].%(ext)s"),
        "merge_output_format": "mp4" if not audio_only else None,
        "postprocessors": [] if not audio_only else [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}],
    }
    opts = {k: v for k, v in opts.items() if v is not None}
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([f"https://www.youtube.com/watch?v={vid}"])
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    files = [p for p in tmp.iterdir() if p.is_file()]
    if not files:
        shutil.rmtree(tmp, ignore_errors=True)
        raise HTTPException(500, "Download produced no file")
    out = max(files, key=lambda p: p.stat().st_size)
    return FileResponse(
        out, filename=out.name, background=BackgroundTask(shutil.rmtree, tmp, ignore_errors=True)
    )


app.mount("/", StaticFiles(directory=WEB), name="web")
