#!/bin/bash
# Double-click this file in Finder to open the downloader.
# If macOS refuses to run it: right-click -> Open, then confirm once.
cd "$(dirname "$0")" || exit 1

for python in python3 /usr/bin/python3 python; do
  if command -v "$python" >/dev/null 2>&1; then
    exec "$python" youtube_downloader.py "$@"
  fi
done

echo "找不到 Python 3。macOS 通常自带；若缺失请运行： xcode-select --install"
read -r -p "按回车关闭..." _
exit 1
