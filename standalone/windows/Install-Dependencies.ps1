[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Invoke-WebRequest redraws its progress bar on every buffer, which makes large
# downloads roughly an order of magnitude slower on Windows PowerShell 5.1.
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Join-Path $scriptDir "tools"
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

function Get-RemoteText([string]$uri) {
    try {
        return (Invoke-WebRequest -UseBasicParsing -Uri $uri).Content
    } catch {
        Write-Host "Could not fetch $uri ($($_.Exception.Message))" -ForegroundColor Yellow
        return $null
    }
}

function Assert-Checksum([string]$path, [string]$expected, [string]$label) {
    if (-not $expected) {
        Write-Host "  no published checksum for $label, skipping verification" -ForegroundColor Yellow
        return
    }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
    if ($actual -ne $expected.ToUpperInvariant()) {
        Remove-Item -Force $path -ErrorAction SilentlyContinue
        throw "Checksum mismatch for $label. Expected $expected but got $actual. The download was deleted."
    }
    Write-Host "  checksum ok" -ForegroundColor DarkGray
}

Write-Host "[1/3] Downloading yt-dlp..." -ForegroundColor Cyan
$ytDlpPath = Join-Path $toolsDir "yt-dlp.exe"
Invoke-WebRequest -UseBasicParsing `
    -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" `
    -OutFile $ytDlpPath

$expectedYtDlp = $null
$sums = Get-RemoteText "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
if ($sums) {
    $line = $sums -split "`n" | Where-Object { $_ -match '\s+yt-dlp\.exe\s*$' } | Select-Object -First 1
    if ($line) { $expectedYtDlp = ($line.Trim() -split '\s+')[0] }
}
Assert-Checksum $ytDlpPath $expectedYtDlp "yt-dlp.exe"

$extractPath = Join-Path $toolsDir "ffmpeg"
$existingFfmpeg = $null
if (Test-Path $extractPath) {
    $existingFfmpeg = Get-ChildItem -Path $extractPath -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

if ($existingFfmpeg -and -not $Force) {
    Write-Host "[2/3] FFmpeg already installed, skipping. Use -Force to reinstall." -ForegroundColor Cyan
    $ffmpegExe = $existingFfmpeg
} else {
    Write-Host "[2/3] Downloading FFmpeg essentials..." -ForegroundColor Cyan
    $zipPath = Join-Path $toolsDir "ffmpeg.zip"
    $zipUri = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $zipUri -OutFile $zipPath

    $expectedZip = $null
    $rawSum = Get-RemoteText "$zipUri.sha256"
    if ($rawSum) { $expectedZip = ($rawSum.Trim() -split '\s+')[0] }
    Assert-Checksum $zipPath $expectedZip "ffmpeg-release-essentials.zip"

    if (Test-Path $extractPath) {
        Remove-Item -Recurse -Force $extractPath
    }
    Expand-Archive -Force -Path $zipPath -DestinationPath $extractPath
    Remove-Item -Force $zipPath

    $ffmpegExe = Get-ChildItem -Path $extractPath -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
    if (-not $ffmpegExe) {
        throw "FFmpeg download completed but ffmpeg.exe was not found."
    }

    # The essentials build ships ffplay (~100 MB) and an HTML manual (~12 MB)
    # that this downloader never touches.
    Get-ChildItem -Path $extractPath -Filter "ffplay.exe" -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $extractPath -Directory -Filter "doc" -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[3/3] Recording FFmpeg location..." -ForegroundColor Cyan
# Stored relative to tools\ so the folder can be moved or copied, and written
# without a BOM so non-PowerShell readers get a clean path.
$relative = $ffmpegExe.DirectoryName.Substring($toolsDir.Length).TrimStart('\', '/')
[System.IO.File]::WriteAllText(
    (Join-Path $toolsDir "ffmpeg-path.txt"),
    $relative,
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Dependencies installed in: $toolsDir" -ForegroundColor Green
