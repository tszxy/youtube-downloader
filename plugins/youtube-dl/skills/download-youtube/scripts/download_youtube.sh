#!/usr/bin/env bash
# Codex skill entry point. Everything is delegated to the standalone
# downloader so the plugin and the standalone tool can never disagree about
# which yt-dlp flags to use.
#
# The dependency points plugin -> standalone on purpose: standalone/ must stay
# usable on its own, without this plugin or Codex.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app="$here/../../../../../standalone/youtube_downloader.py"

if [[ ! -f "$app" ]]; then
  echo "找不到独立下载器：$app" >&2
  exit 1
fi

exec python3 "$app" "$@"
