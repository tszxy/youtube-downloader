#!/usr/bin/env bash
# Proves that the PowerShell GUI and the cross-platform Python downloader hand
# yt-dlp exactly the same arguments. They are two implementations only because
# the PowerShell one must run on a Windows box with no Python installed; any
# behavioural drift between them is a bug.
#
# Usage: tests/compare_implementations.sh [path-to-pwsh]
set -uo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/.." && pwd)"
pwsh_bin="${1:-pwsh}"
python_bin="${PYTHON:-python3}"

if ! command -v "$pwsh_bin" >/dev/null 2>&1; then
  echo "找不到 pwsh（传入路径或安装 PowerShell）" >&2
  exit 127
fi

# --ffmpeg-location is resolved from a per-platform tools directory, so it is
# environment-dependent by design and excluded from the comparison.
strip_env() {
  awk '
    $0 == "--ffmpeg-location" { skip = 1; next }
    skip { skip = 0; next }
    { print }
  '
}

failures=0
compare() {
  local desc="$1"; shift
  local py_args=() ps_args=()
  while [[ "$1" != "--" ]]; do py_args+=("$1"); shift; done
  shift
  ps_args=("$@")

  local py ps
  py=$("$python_bin" "$root/standalone/youtube_downloader.py" --print-command \
        -o /tmp/compare "${py_args[@]}" 2>&1 | tail -n +2 | strip_env)
  ps=$("$pwsh_bin" -NoProfile -File "$root/standalone/windows/YouTube-Downloader.ps1" \
        -PrintCommand -OutputDir /tmp/compare "${ps_args[@]}" 2>&1 | strip_env)

  printf '%-28s ' "$desc"
  if [[ "$py" == "$ps" ]]; then
    echo "一致"
  else
    echo "不一致"
    diff <(printf '%s\n' "$ps") <(printf '%s\n' "$py") | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

compare_probe() {
  # The probe is what the window uses to decide which options a video can
  # deliver, so the two windows must ask yt-dlp the same question.
  local desc="$1" browser="$2"
  local py ps
  py=$("$python_bin" "$root/standalone/youtube_downloader.py" --print-probe-command \
        "$URL" --cookies-from-browser "$browser" 2>&1 | tail -n +2)
  ps=$("$pwsh_bin" -NoProfile -File "$root/standalone/windows/YouTube-Downloader.ps1" \
        -PrintProbeCommand -Url "$URL" -CookiesFromBrowser "$browser" 2>&1)

  printf '%-28s ' "$desc"
  if [[ "$py" == "$ps" ]]; then
    echo "一致"
  else
    echo "不一致"
    diff <(printf '%s\n' "$ps") <(printf '%s\n' "$py") | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

URL="https://youtu.be/ID"

compare "video best"      "$URL" -- -Url "$URL"
compare "video 1080"      "$URL" --quality 1080 -- -Url "$URL" -Quality 1080
compare "video 720"       "$URL" --quality 720  -- -Url "$URL" -Quality 720
compare "video 480"       "$URL" --quality 480  -- -Url "$URL" -Quality 480
compare "audio"           "$URL" --mode audio -- -Url "$URL" -Mode audio
compare "subtitles"       "$URL" --mode subtitles -- -Url "$URL" -Mode subtitles
compare "playlist"        "$URL" --playlist -- -Url "$URL" -Playlist
compare "cookies chrome"  "$URL" --cookies-from-browser chrome -- -Url "$URL" -CookiesFromBrowser chrome
compare "cookies firefox" "$URL" --cookies-from-browser firefox -- -Url "$URL" -CookiesFromBrowser firefox
compare "720 + playlist"  "$URL" --quality 720 --playlist -- -Url "$URL" -Quality 720 -Playlist

compare_probe "probe"         ""
compare_probe "probe + chrome" "chrome"

echo
if [[ $failures -eq 0 ]]; then
  echo "两份实现生成的 yt-dlp 参数完全一致"
else
  echo "$failures 个场景不一致"
fi
exit $((failures > 0))
