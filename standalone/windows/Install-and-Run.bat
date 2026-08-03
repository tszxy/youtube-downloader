@echo off
rem Kept so existing shortcuts and older instructions keep working. Installing
rem is no longer a separate first step: the GUI detects what is missing on
rem startup and offers to install it, so this just forwards to the one entry.
call "%~dp0YouTube-Downloader.bat" %*
exit /b %errorlevel%
