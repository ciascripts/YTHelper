# YTHelper IPA

A modded YouTube app for iPhone and iPad, built by GitHub Actions from **your own** decrypted
YouTube IPA. This repo never contains the YouTube app; the workflow downloads it from your
link for each build.

## What you get

| Feature | Where |
|---|---|
| **Block ads** (video, feed, Shorts, shopping) | YouTube Settings → YTHelper. Restart the app after changing. |
| **In-app name**: shown instead of the YouTube logo | YouTube Settings → YTHelper |
| **In-app logo**: a picture from Photos instead of the YouTube logo | YouTube Settings → YTHelper |
| **Home Screen name** | Set when you build (`display_name`) |
| **Home Screen icon** | Set when you build (`icon_url`). Extra icons (`alt_icon_urls`) can be switched in YouTube Settings → YTHelper. |
| **Download videos** (H.264 + AAC MP4, up to 1080p60, or audio only) | Download button on the video player. Quality is set in YouTube Settings → YTHelper. |
| **4K / 60 fps** | YTUHD, in YouTube Settings → Video quality preferences |

## Build the IPA

1. Keep this repository **private**.
2. Go to **Actions → Build YTHelper IPA → Run workflow** and fill in:
   - `ipa_url`: a direct download link to a decrypted YouTube IPA, for example
     `https://archive.org/download/com.google.ios.youtube_21.41.5_und3fined/com.google.ios.youtube_21.41.5_und3fined.ipa`
   - `ipa_sha256` (optional): the file's SHA-256, so a changed download is rejected.
     Every run prints the SHA-256 of the file it downloaded.
   - `display_name`: the name under the Home Screen icon.
   - `icon_url` (optional): direct link to a square PNG or JPG.
   - `alt_icon_urls` (optional): `Dark=https://…/dark.png, Retro=https://…/retro.png`
   - `bundle_id` (optional): change it to keep the real YouTube app installed next to this one.
   - `include_4k`: adds YTUHD.
3. Wait for the run to finish (expect 20+ minutes; it compiles video decoders). Open the finished run and download **YTHelper-ipa** under
   *Artifacts*. It's a .zip containing `YTHelper.ipa`. Artifacts are deleted after 7 days.

## Install

Sideload `YTHelper.ipa` with SideStore, AltStore, Sideloadly or TrollStore. Apps signed with a
free Apple ID must be refreshed every 7 days.

## Things to know

- **Home Screen name and icon** are part of the app bundle. To change them, build again.
  The alternate icons from `alt_icon_urls` can be switched any time; iOS shows a short notice when you do.
- **Downloads** use the stream links the YouTube app already has. If YouTube sends a video in its newer
  streaming format (SABR), there are no links and the downloader says it can't download that video.
- **4K on sideloaded apps** usually uses software VP9/AV1 decoding, which uses more battery.
- **Hooks are tied to YouTube versions.** Written for YouTube 21.41.5 and not yet tested on a device. A newer YouTube may
  need updated pinned commits in the workflow.

## Layout

- `.github/workflows/build-ipa.yml`: the build.
- `tweak/`: the YTHelper tweak (Logos/Objective-C, Theos).
- `scripts/patch_app.py`: sets the Home Screen name and icons.
- `NOTICE`: third-party code and licences.
