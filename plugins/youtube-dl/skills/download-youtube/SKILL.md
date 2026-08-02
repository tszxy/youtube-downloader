---
name: download-youtube
description: Download YouTube videos, Shorts, playlists, audio, and subtitles with yt-dlp. Use when a user provides a YouTube URL and asks to download, save, extract MP3/audio, obtain captions, use Chrome login cookies, select quality, or create a local media file.
---

# Download YouTube

Use `scripts/download_youtube.sh` for deterministic downloads.

## Workflow

1. Infer the requested mode. Default to `video`.
2. Save into the current workspace unless the user names another directory.
3. Use browser cookies only when authentication is required or the user says they are logged in.
4. Run the script and verify the result with `ffprobe` or `ls -lh`.
5. Return clickable absolute paths for downloaded artifacts.

## Commands

```bash
scripts/download_youtube.sh --url URL --output-dir DIR --mode video
scripts/download_youtube.sh --url URL --output-dir DIR --mode audio
scripts/download_youtube.sh --url URL --output-dir DIR --mode subtitles
scripts/download_youtube.sh --url URL --output-dir DIR --mode video --cookies-from-browser chrome
```

- `video`: download the best MP4-compatible video and audio.
- `audio`: download the best audio and convert it to MP3.
- `subtitles`: download manual and automatic subtitles as SRT, preferring Chinese and English.

Add `--playlist` only when the user explicitly requests the entire playlist.

## Safety

- Never request or expose passwords or cookie files.
- Use `--cookies-from-browser chrome` for an existing Chrome session when required.
- Respect access controls and download only content the user is authorized to access.
- Do not overwrite existing files.
- If yt-dlp is missing, report the dependency instead of installing it unless authorized.
