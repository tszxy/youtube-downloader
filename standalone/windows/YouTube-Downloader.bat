@echo off
rem The single entry point. The GUI checks for yt-dlp and FFmpeg on startup and
rem offers to install whatever is missing, so there is nothing to run first and
rem no second launcher to pick between.
setlocal
if not exist "%~dp0YouTube-Downloader.ps1" (
  echo Cannot find YouTube-Downloader.ps1 next to this file.
  echo Extract the whole ZIP first, then run this from the extracted folder.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0YouTube-Downloader.ps1"
exit /b 0
