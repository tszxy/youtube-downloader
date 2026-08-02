#!/usr/bin/env bash
# Opens the downloader. Pass arguments to use the command line instead:
#   ./run-linux.sh https://youtu.be/ID --mode audio -o ~/Downloads
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
  echo "找不到 python3。Debian/Ubuntu: sudo apt install python3 python3-tk" >&2
  exit 1
fi

if [[ $# -eq 0 ]] && ! python3 -c "import tkinter" >/dev/null 2>&1; then
  echo "缺少 tkinter，无法打开图形界面。" >&2
  echo "Debian/Ubuntu: sudo apt install python3-tk" >&2
  echo "或直接用命令行：./run-linux.sh https://youtu.be/ID -o ~/Downloads" >&2
  exit 1
fi

exec python3 youtube_downloader.py "$@"
