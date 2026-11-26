# YTHelper

A self-hosted YouTube client you install to your Home Screen as a PWA. It has a settings menu (⚙) for:

| Setting | Where it shows |
|---|---|
| **In-app name** | Header and tab title |
| **Home Screen name** | Under the icon (`manifest.short_name`, `apple-mobile-web-app-title`) |
| **In-app picture** | Header logo and favicon |
| **Home Screen picture** | Installed app icon (`apple-touch-icon`, manifest icons) |
| **Show ads** | Off: direct stream, no ads. On: the official YouTube embed player |
| **Max quality / fps** | Up to 4K (2160p) at 60 fps |

On the watch page you can also **download** a video in 4K60, 1440p, 1080p or 720p, or as audio only.

## Run

```bash
pip install -r requirements.txt   # ffmpeg must be on PATH for downloads
uvicorn server.main:app --host 0.0.0.0 --port 8000
```

Or with Docker:

```bash
docker build -t ythelper . && docker run -p 8000:8000 -v ythelper-data:/app/data ythelper
```

Then open `http://<server>:8000`. Installing to the Home Screen needs HTTPS, so put it behind a reverse proxy such as Caddy, or a Cloudflare Tunnel.

## How it works

- **Backend** (`server/main.py`, FastAPI + yt-dlp): search, format lists, a `/api/proxy` that passes Range requests through (googlevideo URLs are bound to the server's IP), downloads merged with ffmpeg, settings and icons stored in `data/`, and a manifest and `index.html` generated from the settings.
- **Frontend** (`web/`): vanilla JS. YouTube serves 1080p+ and 60 fps as separate video and audio streams, so the player plays a video-only `<video>` and an `<audio>` element and keeps the audio locked to the video. The quality list only shows codecs the browser can decode: AV1 or VP9 for 4K, H.264 up to 1080p.

## Notes

- **Home Screen name or picture changes:** iOS and Android cache these when the app is installed. Remove the app and add it to the Home Screen again to see the change. The in-app name and picture update right away.
- **4K on iPhone:** Safari only plays 4K if the device decodes VP9 or AV1. If it can't, the quality list stops at the highest resolution it can play.
- **Personal use:** only download videos you have the right to save. Downloading may break YouTube's Terms of Service.
