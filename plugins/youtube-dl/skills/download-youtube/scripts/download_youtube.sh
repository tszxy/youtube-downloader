#!/usr/bin/env bash
set -euo pipefail

url=""
output_dir="."
mode="video"
cookies_browser=""
playlist="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) url="${2:?missing URL}"; shift 2 ;;
    --output-dir) output_dir="${2:?missing output directory}"; shift 2 ;;
    --mode) mode="${2:?missing mode}"; shift 2 ;;
    --cookies-from-browser) cookies_browser="${2:?missing browser}"; shift 2 ;;
    --playlist) playlist="true"; shift ;;
    -h|--help)
      echo "Usage: $0 --url URL [--output-dir DIR] [--mode video|audio|subtitles] [--cookies-from-browser chrome] [--playlist]"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$url" ]] || { echo "--url is required" >&2; exit 2; }
[[ "$url" == https://www.youtube.com/* || "$url" == https://youtube.com/* || "$url" == https://youtu.be/* || "$url" == https://m.youtube.com/* ]] || {
  echo "Only YouTube URLs are supported" >&2
  exit 2
}

mkdir -p "$output_dir"

if command -v yt-dlp >/dev/null 2>&1; then
  runner=(yt-dlp)
elif python3 -c 'import yt_dlp' >/dev/null 2>&1; then
  runner=(python3 -m yt_dlp)
else
  echo "yt-dlp is not installed. See the repository README." >&2
  exit 127
fi

common=(--no-overwrites --restrict-filenames --newline --output "$output_dir/%(title)s [%(id)s].%(ext)s")
[[ "$playlist" == "true" ]] || common+=(--no-playlist)
[[ -z "$cookies_browser" ]] || common+=(--cookies-from-browser "$cookies_browser")

case "$mode" in
  video)
    "${runner[@]}" "${common[@]}" --format "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b" --merge-output-format mp4 "$url"
    ;;
  audio)
    "${runner[@]}" "${common[@]}" --format "ba/b" --extract-audio --audio-format mp3 --audio-quality 0 "$url"
    ;;
  subtitles)
    "${runner[@]}" "${common[@]}" --skip-download --write-subs --write-auto-subs --sub-langs "zh-Hans,zh-Hant,zh.*,en.*" --convert-subs srt "$url"
    ;;
  *) echo "Unsupported mode: $mode (use video, audio, or subtitles)" >&2; exit 2 ;;
esac
