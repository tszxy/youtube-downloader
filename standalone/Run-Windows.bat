@echo off
rem Double-click to open the downloader. Requires Python 3.
rem Windows users without Python can use windows\Run-Downloader.bat instead,
rem which needs nothing beyond Windows itself.
setlocal
cd /d "%~dp0"

where py >nul 2>&1
if %errorlevel%==0 (
  py -3 youtube_downloader.py %*
  goto :done
)

where python >nul 2>&1
if %errorlevel%==0 (
  python youtube_downloader.py %*
  goto :done
)

echo Python 3 not found.
echo Install it from https://www.python.org/downloads/ and tick "Add python.exe to PATH",
echo or use the PowerShell version in the windows folder, which needs no Python:
echo     windows\Run-Downloader.bat
pause
exit /b 1

:done
if errorlevel 1 pause
exit /b %errorlevel%
