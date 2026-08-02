@echo off
setlocal
if not exist "%~dp0YouTube-Downloader.ps1" (
  echo Cannot find YouTube-Downloader.ps1 next to this file.
  echo Extract the whole ZIP first, then run this from the extracted folder.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0YouTube-Downloader.ps1"
exit /b 0
