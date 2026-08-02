[CmdletBinding()]
param(
    [switch]$Force,
    # Exercises the pure helpers below and exits, without touching the network
    # or writing anything. CI runs it under both PowerShell editions, which is
    # the only way to catch the byte[] behaviour described in Get-ResponseText.
    [switch]$SelfTest,
    # Same parsing, against the live SHA2-256SUMS instead of a sample. Proves
    # the byte[] claim on a real response and that the checksum is still found
    # end to end. Needs the network, so CI runs it without gating on it.
    [switch]$CheckPublished
)

$ErrorActionPreference = "Stop"

# Invoke-WebRequest redraws its progress bar on every buffer, which makes large
# downloads roughly an order of magnitude slower on Windows PowerShell 5.1.
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Join-Path $scriptDir "tools"

function Get-ResponseText($content) {
    # Invoke-WebRequest returns a byte[] whenever the server does not declare a
    # text content type, and GitHub serves SHA2-256SUMS as
    # application/octet-stream. Splitting those bytes as if they were lines of
    # text matched nothing, so verification silently turned itself off.
    #
    # Measured by -CheckPublished on CI: Windows PowerShell 5.1 and pwsh 7.6
    # BOTH hand back System.Byte[] here. What differs is the response, not the
    # edition -- the FFmpeg checksum next to it is served as text/plain and
    # arrives as a string, which is why only yt-dlp was affected.
    if ($content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($content)
    }
    return [string]$content
}

function Get-PublishedChecksum([string]$text, [string]$fileName) {
    # Exact name match, mirroring the Python implementation: yt-dlp.exe,
    # yt-dlp_x86.exe and yt-dlp_arm64.exe all live in the same list.
    if (-not $text) { return $null }
    foreach ($line in ($text -split '\r?\n')) {
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -eq 2 -and $parts[1] -eq $fileName) { return $parts[0] }
    }
    return $null
}

if ($SelfTest) {
    $list = "aaa  yt-dlp`nbbb  yt-dlp.exe`nccc  yt-dlp_x86.exe`n"
    # Precomputed: a comma inside a hashtable value is ambiguous to the parser.
    $crlf = $list -replace "`n", "`r`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($list)
    $failures = @()
    $cases = @(
        @{ label = "byte[] (application/octet-stream, e.g. SHA2-256SUMS)"; content = $bytes },
        @{ label = "string (text/plain, e.g. the FFmpeg .sha256)"; content = $list },
        @{ label = "CRLF line endings"; content = $crlf }
    )
    foreach ($case in $cases) {
        $found = Get-PublishedChecksum (Get-ResponseText $case.content) "yt-dlp.exe"
        if ($found -ne "bbb") {
            $failures += "$($case.label): expected bbb, got '$found'"
        }
    }
    if (Get-PublishedChecksum (Get-ResponseText $list) "yt-dlp_arm64.exe") {
        $failures += "matched a name that is not in the list"
    }
    if ($failures.Count -gt 0) {
        # Write-Host, not Write-Error: $ErrorActionPreference is Stop, so the
        # first Write-Error would hide the remaining failures.
        $failures | ForEach-Object { Write-Host "self-test FAILED: $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "self-test ok"
    exit 0
}

if ($CheckPublished) {
    $raw = (Invoke-WebRequest -UseBasicParsing `
        -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS").Content
    Write-Host "PowerShell $($PSVersionTable.PSVersion) received: $($raw.GetType().FullName)"
    $found = Get-PublishedChecksum (Get-ResponseText $raw) "yt-dlp.exe"
    if (-not $found) {
        Write-Host "FAILED: yt-dlp.exe not found in the published list" -ForegroundColor Red
        exit 1
    }
    Write-Host "found published checksum for yt-dlp.exe: $found"
    exit 0
}

New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

function Get-RemoteText([string]$uri) {
    try {
        return Get-ResponseText (Invoke-WebRequest -UseBasicParsing -Uri $uri).Content
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

$sums = Get-RemoteText "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
$expectedYtDlp = Get-PublishedChecksum $sums "yt-dlp.exe"
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
