#!/usr/bin/env bash
# Backwards-compatible positional interface kept for existing scripts and docs:
#   youtube-downloader.sh URL [video|audio|subtitles] [OUTPUT_DIR] [best|1080|720|480]
#
# All behaviour lives in ../youtube_downloader.py; this only maps positional
# arguments onto its flags so there is exactly one place that builds a yt-dlp
# command.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app="$here/../youtube_downloader.py"

[[ -f "$app" ]] || { echo "找不到 $app" >&2; exit 1; }

url="${1:-}"
case "$url" in
  ""|-h|--help)
    cat >&2 <<EOF
用法: $0 URL [video|audio|subtitles] [OUTPUT_DIR] [best|1080|720|480] [其他参数...]

示例:
  $0 "URL" video "\$HOME/Downloads"
  $0 "URL" video "\$HOME/Downloads" 1080
  $0 "URL" video "\$HOME/Downloads" best --playlist

完整参数请看: python3 $app --help
EOF
    [[ -n "$url" ]] && exit 0
    exit 2 ;;
esac

mode="${2:-video}"
output_dir="${3:-$PWD}"
quality="${4:-best}"
shift $(( $# < 4 ? $# : 4 ))

exec python3 "$app" "$url" --mode "$mode" --output-dir "$output_dir" --quality "$quality" "$@"
