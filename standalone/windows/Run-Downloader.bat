@echo off
rem Kept so existing shortcuts keep working. YouTube-Downloader.bat is the one
rem entry point now; this only forwards to it.
call "%~dp0YouTube-Downloader.bat" %*
exit /b %errorlevel%
