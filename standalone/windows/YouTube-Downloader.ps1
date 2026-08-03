[CmdletBinding()]
param(
    # -PrintCommand builds the yt-dlp argument list and exits without opening
    # the window. CI uses it to prove this script and the cross-platform
    # standalone/youtube_downloader.py agree on every flag.
    [string]$Url = "",
    [ValidateSet("video", "audio", "subtitles")][string]$Mode = "video",
    [ValidateSet("best", "1080", "720", "480")][string]$Quality = "best",
    [string]$OutputDir = ".",
    [switch]$Playlist,
    [string]$CookiesFromBrowser = "",
    [switch]$PrintCommand,
    # The same for the probe that asks a video which options it can deliver.
    [switch]$PrintProbeCommand,
    # Builds every control and exits instead of opening the window. -PrintCommand
    # returns before Add-Type, so without this the entire GUI half of this file
    # is never executed anywhere -- which is how a startup crash can ship.
    [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolsDir = Join-Path $scriptDir "tools"
$script:activeProcess = $null
$script:logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:maxLogLines = 2000
# Set by the output reader when yt-dlp hits YouTube's "Sign in to confirm
# you're not a bot" (or "... your age") wall; both are fixed by cookies.
$script:botCheck = $false
# What the probed video can deliver. Empty means nothing has been probed yet,
# and an option missing from the table counts as available.
$script:availableModes = @{}
$script:availableQualities = @{}
$script:updatingOptions = $false
$script:probeJob = $null
$script:probeStale = $false
$script:probedKey = ""
$script:probeOutput = New-Object System.Text.StringBuilder
$script:probeFailure = ""
$script:probeLastError = ""
# The download types still to run, and everything the next one needs.
$script:queueModes = @()
$script:queueTotal = 0
$script:queueIndex = 0
$script:queueCancelled = $false
$script:queueUrl = ""
$script:queueQuality = "best"
$script:queueOutputDir = ""
$script:queuePlaylist = $false
$script:queueBrowser = ""
$script:queueFfmpegDir = ""
$script:queueTool = ""
# Every running child, each with its own stdout/stderr taps and callbacks; see
# Update-ChildProcess for why the UI timer owns them rather than .NET events.
# There can be two at once: a download and the probe that asks a video which
# options it can deliver.
$script:jobs = @()
# Strict on purpose: GetString throws on invalid UTF-8 instead of quietly
# producing U+FFFD, which is what tells ConvertTo-LineText to fall back.
$script:strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$script:ansiEncoding = try {
    [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
} catch {
    # Encoding.Default is the ANSI codepage on 5.1 but UTF-8 on pwsh 7, so it
    # is only the last resort.
    [System.Text.Encoding]::Default
}

function Find-Executable([string]$name, [string]$portablePath) {
    if (Test-Path $portablePath) { return $portablePath }
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Resolve-FfmpegDirectory {
    # Install-Dependencies.ps1 records a path relative to tools\. Older installs
    # wrote an absolute path, which breaks as soon as the folder is moved, so
    # fall back to searching the extracted FFmpeg tree.
    $pathFile = Join-Path $toolsDir "ffmpeg-path.txt"
    if (Test-Path $pathFile) {
        $recorded = [System.IO.File]::ReadAllText($pathFile).Trim().TrimStart([char]0xFEFF)
        if ($recorded) {
            $candidate = if ([System.IO.Path]::IsPathRooted($recorded)) { $recorded } else { Join-Path $toolsDir $recorded }
            if (Test-Path (Join-Path $candidate "ffmpeg.exe")) { return $candidate }
        }
    }

    $extractPath = Join-Path $toolsDir "ffmpeg"
    if (Test-Path $extractPath) {
        $found = Get-ChildItem -Path $extractPath -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.DirectoryName }
    }
    return $null
}

function Stop-ProcessTree([System.Diagnostics.Process]$process) {
    # Process.Kill() in PowerShell 5.1 leaves the ffmpeg child running.
    if (-not $process -or $process.HasExited) { return }
    & taskkill.exe /PID $($process.Id) /T /F 2>&1 | Out-Null
    if (-not $process.HasExited) {
        # taskkill usually wins the race; Kill() is the fallback and can fail
        # harmlessly if the process exited in between.
        try { $process.Kill() } catch { Add-Log "结束进程时出错：$($_.Exception.Message)" }
    }
}

function Get-VideoFormat([string]$quality) {
    # H.264 (avc1) first on purpose: YouTube increasingly serves AV1, which is
    # smaller but will not play on older phones, TVs and desktop players. Each
    # fallback loosens one constraint so a download never fails outright.
    # Mirrors video_format() in standalone/youtube_downloader.py.
    if ($quality -eq "best") {
        return "bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
    }
    return "bv*[height<=$quality][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=$quality][ext=mp4]+ba[ext=m4a]/b[height<=$quality][ext=mp4]/bv*[height<=$quality]+ba/b"
}

function Build-YtDlpArgumentList {
    # Mirrors build_command() in standalone/youtube_downloader.py. CI compares
    # the two with -PrintCommand, so any change here must be made there too.
    param(
        [string]$Url,
        [string]$Mode = "video",
        [string]$Quality = "best",
        [string]$OutputDir = ".",
        [bool]$Playlist = $false,
        [string]$CookiesBrowser = "",
        [string]$FfmpegDir = ""
    )

    $arguments = @(
        "--no-overwrites",
        "--newline",
        "--windows-filenames",
        "--trim-filenames", "200",
        "--concurrent-fragments", "4",
        "--output", (Join-Path $OutputDir "%(title)s [%(id)s].%(ext)s"))
    if (-not $Playlist) { $arguments += "--no-playlist" }
    if ($CookiesBrowser) { $arguments += @("--cookies-from-browser", $CookiesBrowser) }
    if ($FfmpegDir) { $arguments += @("--ffmpeg-location", $FfmpegDir) }

    switch ($Mode) {
        "video"  { $arguments += @("--format", (Get-VideoFormat $Quality), "--merge-output-format", "mp4") }
        "audio"  { $arguments += @("--format", "ba/b", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0") }
        "subtitles" {
            $arguments += @("--skip-download", "--write-subs", "--write-auto-subs",
                            "--sub-langs", "zh-Hans,zh-Hant,zh,en", "--convert-subs", "srt")
        }
    }
    $arguments += $Url
    return $arguments
}

function Build-ProbeArgumentList {
    # Mirrors probe_command() in standalone/youtube_downloader.py: asks yt-dlp
    # what a video offers so the window can grey out what it cannot deliver.
    param(
        [string]$Url,
        [string]$CookiesBrowser = ""
    )
    $arguments = @("--dump-single-json", "--no-warnings", "--skip-download", "--no-playlist")
    if ($CookiesBrowser) { $arguments += @("--cookies-from-browser", $CookiesBrowser) }
    $arguments += $Url
    return $arguments
}

function Get-AvailableOption {
    # Mirrors available_options() in standalone/youtube_downloader.py.
    # Unknown counts as available: a probe that tells us nothing must never be
    # the reason a download the user could have had is refused.
    param($Info)

    $formats = @()
    if ($Info -and $Info.formats) { $formats = @($Info.formats) }

    $heights = @()
    $hasAudio = $false
    foreach ($format in $formats) {
        if ($null -ne $format.height -and $format.height -gt 0) { $heights += [int]$format.height }
        if ($format.acodec -and $format.acodec -ne "none") { $hasAudio = $true }
    }
    $heights = @($heights | Sort-Object -Unique)

    $hasVideo = $true
    if ($formats.Count -gt 0) {
        $hasVideo = $heights.Count -gt 0
    } else {
        $hasAudio = $true
    }

    $qualities = @{ "best" = $hasVideo }
    foreach ($cap in 1080, 720, 480) {
        # A cap is offered when the video reaches it (otherwise 1080p on a
        # 720p-only video would promise something YouTube cannot give) and has
        # a track at or below it. Unknown heights leave every cap enabled.
        $reaches = @($heights | Where-Object { $_ -ge $cap }).Count -gt 0
        $fits = @($heights | Where-Object { $_ -le $cap }).Count -gt 0
        $qualities["$cap"] = ($hasVideo -and $heights.Count -eq 0) -or ($reaches -and $fits)
    }

    $tracks = @()
    foreach ($set in @($Info.subtitles, $Info.automatic_captions)) {
        if ($set) { $tracks += @($set.PSObject.Properties.Name) }
    }
    $hasSubtitles = $false
    foreach ($language in "zh-Hans", "zh-Hant", "zh", "en") {
        if ($tracks -contains $language) { $hasSubtitles = $true }
    }

    return @{
        Title     = if ($Info -and $Info.title) { [string]$Info.title } else { "" }
        Heights   = $heights
        Modes     = @{ video = $hasVideo; audio = $hasAudio; subtitles = $hasSubtitles }
        Qualities = $qualities
    }
}

function Format-OptionSummary($Available) {
    # Mirrors options_summary() in standalone/youtube_downloader.py.
    $parts = @()
    if ($Available.Heights.Count -gt 0) {
        $parts += "最高 $($Available.Heights[-1])p"
    } else {
        $parts += "画质未知"
    }
    $parts += $(if ($Available.Modes.audio) { "有音频" } else { "无音频" })
    $parts += $(if ($Available.Modes.subtitles) { "有中/英字幕" } else { "无中/英字幕" })
    if ($Available.Title) {
        $title = $Available.Title
        if ($title.Length -gt 40) { $title = $title.Substring(0, 39) + "..." }
        $parts += $title
    }
    return ($parts -join " · ")
}

if ($PrintProbeCommand) {
    if (-not $Url) { Write-Error "-PrintProbeCommand 需要 -Url"; exit 2 }
    (Build-ProbeArgumentList -Url $Url -CookiesBrowser $CookiesFromBrowser) -join "`n"
    exit 0
}

if ($PrintCommand) {
    if (-not $Url) { Write-Error "-PrintCommand 需要 -Url"; exit 2 }
    $ffmpeg = Resolve-FfmpegDirectory
    $built = Build-YtDlpArgumentList -Url $Url -Mode $Mode -Quality $Quality -OutputDir $OutputDir `
        -Playlist $Playlist.IsPresent -CookiesBrowser $CookiesFromBrowser `
        -FfmpegDir $(if ($ffmpeg) { $ffmpeg } else { "" })
    $built -join "`n"
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function ConvertTo-QuotedArgument([string]$value) {
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Add-Log([string]$message) {
    # Called from background reader threads; the UI timer drains the queue.
    $script:logQueue.Enqueue($message)
}

function Receive-ToolOutput([string]$data) {
    # One line from yt-dlp. Matching here rather than in Add-Log keeps this
    # script's own messages out of the bot-check test.
    if (-not $data) { return }
    Add-Log $data
    if ($data -match '(?i)sign in to confirm') { $script:botCheck = $true }
}

function Set-Busy([bool]$busy, [string]$status) {
    $downloadButton.Enabled = -not $busy
    $installButton.Enabled = -not $busy
    $probeButton.Enabled = -not $busy
    $cancelButton.Enabled = $busy
    $statusLabel.Text = $status
}

function New-OutputTap([System.IO.Stream]$source) {
    # CopyToAsync is pure .NET, so draining the pipe needs no PowerShell code on
    # the threadpool thread that finishes it. bufferSize 1 keeps the writer from
    # holding lines back from the reader.
    $path = [System.IO.Path]::GetTempFileName()
    $target = New-Object System.IO.FileStream(
        $path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite, 1, $true)
    return [pscustomobject]@{
        Path    = $path
        Target  = $target
        Task    = $source.CopyToAsync($target)
        Offset  = [long]0
        Partial = New-Object byte[] 0
    }
}

function ConvertTo-LineText([byte[]]$bytes, [int]$index, [int]$count) {
    if ($count -le 0) { return "" }
    try {
        return $script:strictUtf8.GetString($bytes, $index, $count)
    } catch {
        # The child ignored the UTF-8 environment it was handed and wrote the
        # system codepage: a real yt-dlp run turned its own curly quote into
        # U+FFFD this way. Decoding per line keeps one bad line from
        # desynchronising the rest.
        return $script:ansiEncoding.GetString($bytes, $index, $count)
    }
}

function Read-TapOutput($tap) {
    # Splits on the LF byte and decodes one line at a time. A UTF-8 sequence can
    # never contain 0x0A, so line boundaries are safe to find before decoding,
    # and that is what lets a single mis-encoded line fall back on its own.
    # A trailing partial line stays in the tap until its newline arrives.
    $lines = @()
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $tap.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -le $tap.Offset) { return $lines }
        [void]$stream.Seek($tap.Offset, [System.IO.SeekOrigin]::Begin)
        $count = [int][Math]::Min(65536, $stream.Length - $tap.Offset)
        $buffer = New-Object byte[] $count
        $read = $stream.Read($buffer, 0, $count)
        $tap.Offset += $read
        if ($read -le 0) { return $lines }

        $combined = New-Object byte[] ($tap.Partial.Length + $read)
        [System.Buffer]::BlockCopy($tap.Partial, 0, $combined, 0, $tap.Partial.Length)
        [System.Buffer]::BlockCopy($buffer, 0, $combined, $tap.Partial.Length, $read)

        $start = 0
        for ($i = 0; $i -lt $combined.Length; $i++) {
            if ($combined[$i] -ne 0x0A) { continue }
            $end = $i
            if ($end -gt $start -and $combined[$end - 1] -eq 0x0D) { $end-- }
            $lines += (ConvertTo-LineText $combined $start ($end - $start))
            $start = $i + 1
        }
        $rest = New-Object byte[] ($combined.Length - $start)
        [System.Buffer]::BlockCopy($combined, $start, $rest, 0, $rest.Length)
        $tap.Partial = $rest
    } catch {
        # A tick that loses the race with the writer retries on the next one,
        # so drop whatever this pass read rather than emitting a partial line.
        $lines = @()
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    return $lines
}

function Close-OutputTap($Tap, [scriptblock]$Handler) {
    # Drains what is left, including a last line with no trailing newline, and
    # releases the temp file behind the tap.
    foreach ($line in (Read-TapOutput $Tap)) { & $Handler $line }
    if ($Tap.Partial.Length -gt 0) {
        & $Handler (ConvertTo-LineText $Tap.Partial 0 $Tap.Partial.Length)
        $Tap.Partial = New-Object byte[] 0
    }
    $Tap.Target.Dispose()
    Remove-Item -LiteralPath $Tap.Path -Force -ErrorAction SilentlyContinue
}

function Update-ChildProcess {
    # Driven by the UI timer, so everything here runs on the UI thread with a
    # runspace available. This replaced add_OutputDataReceived/add_Exited: those
    # fire on threadpool threads, where a PowerShell scriptblock has no runspace
    # and the resulting failure closed the whole window on the first click.
    if (-not $script:jobs -or $script:jobs.Count -eq 0) { return }

    $finished = @()
    foreach ($job in @($script:jobs)) {
        foreach ($line in (Read-TapOutput $job.Out)) { & $job.OnOutput $line }
        foreach ($line in (Read-TapOutput $job.Err)) { & $job.OnError $line }

        if (-not $job.Process.HasExited) { continue }
        # The pipes can still hold output after the process is gone.
        if (-not $job.Out.Task.IsCompleted -or -not $job.Err.Task.IsCompleted) { continue }

        Close-OutputTap $job.Out $job.OnOutput
        Close-OutputTap $job.Err $job.OnError
        $finished += $job
    }

    foreach ($job in $finished) {
        $script:jobs = @($script:jobs | Where-Object { -not [object]::ReferenceEquals($_, $job) })
        $exitCode = $job.Process.ExitCode
        if ($script:activeProcess -and [object]::ReferenceEquals($script:activeProcess, $job.Process)) {
            $script:activeProcess = $null
        }
        $job.Process.Dispose()
        # Last, and after the bookkeeping: the callback usually starts the next
        # child, and would otherwise be undone by the lines above.
        if ($job.OnExit) { & $job.OnExit $exitCode }
    }
}

function Start-ChildProcess {
    param(
        [string]$FileName,
        [string[]]$ArgumentList,
        [scriptblock]$OnOutput,
        [scriptblock]$OnError,
        [scriptblock]$OnExit
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = ($ArgumentList | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    # yt-dlp is Python, and with its output redirected it would otherwise encode
    # using the system codepage, so a Chinese title or even the curly quote in
    # yt-dlp's own "you're not a bot" message arrives as mojibake. PYTHONUTF8
    # is the one that actually takes effect in the frozen build; PYTHONIOENCODING
    # stays as the fallback for older yt-dlp releases.
    $startInfo.EnvironmentVariables["PYTHONUTF8"] = "1"
    $startInfo.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
    } catch {
        Add-Log "无法启动 $FileName：$($_.Exception.Message)"
        return $null
    }

    $job = [pscustomobject]@{
        Process  = $process
        Out      = (New-OutputTap $process.StandardOutput.BaseStream)
        Err      = (New-OutputTap $process.StandardError.BaseStream)
        OnOutput = $OnOutput
        OnError  = $OnError
        OnExit   = $OnExit
    }
    $script:jobs = @($script:jobs) + $job
    return $job
}

function Start-ToolProcess([string]$fileName, [string[]]$arguments, [string]$busyStatus, [scriptblock]$onExit) {
    # A download or the installer: its output goes to the log box, and it is the
    # one child the cancel button can reach.
    Set-Busy $true $busyStatus
    $job = Start-ChildProcess -FileName $fileName -ArgumentList $arguments `
        -OnOutput { param($line) Receive-ToolOutput $line } `
        -OnError { param($line) Receive-ToolOutput $line } `
        -OnExit $onExit
    if (-not $job) {
        Set-Busy $false "启动失败"
        return $null
    }
    $script:activeProcess = $job.Process
    return $job.Process
}

function Test-BrowserProfile([string]$name) {
    # Only used to grey out browsers that are not installed: picking a missing
    # one fails inside yt-dlp with a message most people cannot act on.
    if (-not $name) { return $true }   # 不使用 is always a valid choice.
    $local = $env:LOCALAPPDATA
    $roaming = $env:APPDATA
    $paths = switch ($name) {
        "chrome"  { @("$local\Google\Chrome\User Data") }
        "edge"    { @("$local\Microsoft\Edge\User Data") }
        "firefox" { @("$roaming\Mozilla\Firefox") }
        "brave"   { @("$local\BraveSoftware\Brave-Browser\User Data") }
        default   { @() }
    }
    foreach ($path in $paths) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { return $true }
    }
    return $false
}

function Get-SelectedMode {
    $selected = @()
    foreach ($mode in $script:modeChecks.Keys) {
        if ($script:modeChecks[$mode].Checked) { $selected += $mode }
    }
    return ,$selected   # The comma keeps a single choice an array.
}

function Get-ModeLabel([string]$mode) {
    if ($script:modeChecks.Contains($mode)) { return $script:modeChecks[$mode].Text }
    return $mode
}

function Get-SelectedQuality {
    foreach ($quality in $script:qualityRadios.Keys) {
        if ($script:qualityRadios[$quality].Checked) { return $quality }
    }
    return "best"
}

function Get-SelectedBrowser {
    foreach ($browser in $script:browserRadios.Keys) {
        if ($script:browserRadios[$browser].Checked) { return $browser }
    }
    return ""
}

function Test-OptionAvailable($table, [string]$key) {
    # Unknown reads as available, which is what keeps a failed probe from
    # taking away a download that would have worked.
    if ($table -and $table.Contains($key)) { return [bool]$table[$key] }
    return $true
}

function Update-OptionEnabled {
    # Re-entrant: clearing a check box below raises CheckedChanged, which lands
    # back here.
    if ($script:updatingOptions) { return }
    $script:updatingOptions = $true
    try {
        foreach ($mode in $script:modeChecks.Keys) {
            $enabled = Test-OptionAvailable $script:availableModes $mode
            $script:modeChecks[$mode].Enabled = $enabled
            if (-not $enabled) { $script:modeChecks[$mode].Checked = $false }
        }
        # The quality cap only affects the video download, so it greys out with it.
        $wantVideo = $script:modeChecks["video"].Checked
        foreach ($quality in $script:qualityRadios.Keys) {
            $enabled = Test-OptionAvailable $script:availableQualities $quality
            $script:qualityRadios[$quality].Enabled = ($wantVideo -and $enabled)
            if (-not $enabled -and $script:qualityRadios[$quality].Checked) {
                $script:qualityRadios["best"].Checked = $true
            }
        }
        foreach ($browser in $script:browserRadios.Keys) {
            $enabled = Test-BrowserProfile $browser
            $script:browserRadios[$browser].Enabled = $enabled
            if (-not $enabled -and $script:browserRadios[$browser].Checked) {
                $script:browserRadios[""].Checked = $true
            }
        }
    } finally {
        $script:updatingOptions = $false
    }
}

function Reset-OptionAvailability([string]$message) {
    $script:availableModes = @{}
    $script:availableQualities = @{}
    $probeLabel.Text = $message
    Update-OptionEnabled
}

function Request-VideoProbe {
    # Debounced, so pasting a link costs one probe rather than one per keystroke.
    $probeTimer.Stop()
    $probeTimer.Start()
}

function Receive-ProbeError([string]$line) {
    if (-not $line) { return }
    $script:probeLastError = $line
    if ($script:probeFailure) { return }
    # Mirrors probe_error() in standalone/youtube_downloader.py.
    if ($line -match '(?i)sign in to confirm') {
        $script:probeFailure = "YouTube 要求验证你不是机器人，先在「登录状态来源」里选一个浏览器"
    } elseif ($line -match '^ERROR:') {
        $script:probeFailure = $line
    }
}

function Start-VideoProbe {
    $probeTimer.Stop()
    $url = $urlBox.Text.Trim()
    if ($url -notmatch '^https?://([\w-]+\.)*(youtube\.com|youtu\.be)/') {
        $script:probedKey = ""
        Reset-OptionAvailability "可用选项：填入链接后自动检测"
        return
    }
    if ($script:activeProcess) {
        # A download or install is running; look again once it is out of the way
        # rather than competing with it for YouTube's patience.
        $probeTimer.Start()
        return
    }
    if ($script:probeJob) {
        # One probe at a time; the running one restarts itself when it finishes.
        $script:probeStale = $true
        return
    }
    $browser = Get-SelectedBrowser
    $key = "$url|$browser"
    if ($key -eq $script:probedKey) { return }

    $ytDlp = Find-Executable "yt-dlp" (Join-Path $toolsDir "yt-dlp.exe")
    if (-not $ytDlp) {
        Reset-OptionAvailability "可用选项：未找到 yt-dlp，先点安装/更新依赖"
        return
    }

    $script:probedKey = $key
    $script:probeStale = $false
    $script:probeOutput = New-Object System.Text.StringBuilder
    $script:probeFailure = ""
    $script:probeLastError = ""
    $probeLabel.Text = "正在检测这个视频能提供哪些选项..."
    $script:probeJob = Start-ChildProcess -FileName $ytDlp `
        -ArgumentList (Build-ProbeArgumentList -Url $url -CookiesBrowser $browser) `
        -OnOutput { param($line) [void]$script:probeOutput.Append($line) } `
        -OnError { param($line) Receive-ProbeError $line } `
        -OnExit { param($exitCode) Complete-VideoProbe $exitCode }
    if (-not $script:probeJob) {
        $script:probedKey = ""
        Reset-OptionAvailability "可用选项：检测无法启动"
    }
}

function Complete-VideoProbe([int]$exitCode) {
    $script:probeJob = $null
    if ($script:probeStale) {
        # The link or the browser changed while this probe was running.
        $script:probeStale = $false
        $script:probedKey = ""
        Start-VideoProbe
        return
    }

    $text = $script:probeOutput.ToString().Trim()
    if ($exitCode -ne 0 -or -not $text) {
        $reason = $script:probeFailure
        if (-not $reason) { $reason = $script:probeLastError }
        if (-not $reason) { $reason = "yt-dlp 退出代码 $exitCode" }
        Reset-OptionAvailability "检测失败：$reason（选项保持全部可选）"
        return
    }

    $info = $null
    try {
        $info = $text | ConvertFrom-Json
    } catch {
        Reset-OptionAvailability "检测失败：yt-dlp 返回的不是 JSON（选项保持全部可选）"
        return
    }
    $available = Get-AvailableOption -Info $info
    $script:availableModes = $available.Modes
    $script:availableQualities = $available.Qualities
    $probeLabel.Text = "可用选项：" + (Format-OptionSummary $available)
    Update-OptionEnabled
}

function Start-QueuedDownload {
    # yt-dlp takes one mode per run, so several ticked types run one after
    # another rather than as simultaneous requests for the same video.
    if ($script:queueModes.Count -eq 0) { return }
    $mode = $script:queueModes[0]
    $script:queueModes = @($script:queueModes | Select-Object -Skip 1)
    $script:queueIndex++

    $status = "正在下载..."
    if ($script:queueTotal -gt 1) {
        $label = Get-ModeLabel $mode
        Add-Log "=== $($script:queueIndex)/$($script:queueTotal)：$label"
        $status = "正在下载（$($script:queueIndex)/$($script:queueTotal)）：$label"
    }

    $arguments = Build-YtDlpArgumentList `
        -Url $script:queueUrl `
        -Mode $mode `
        -Quality $script:queueQuality `
        -OutputDir $script:queueOutputDir `
        -Playlist $script:queuePlaylist `
        -CookiesBrowser $script:queueBrowser `
        -FfmpegDir $script:queueFfmpegDir
    Start-ToolProcess $script:queueTool $arguments $status {
        param($exitCode)
        Complete-QueuedDownload $exitCode
    } | Out-Null
}

function Complete-QueuedDownload([int]$exitCode) {
    if ($exitCode -eq 0 -and -not $script:queueCancelled -and $script:queueModes.Count -gt 0) {
        $progressBar.Value = 0
        Start-QueuedDownload
        return
    }
    $script:queueModes = @()
    Set-Busy $false $(if ($exitCode -eq 0) { "下载完成" } else { "下载失败，退出代码：$exitCode" })
    if ($exitCode -eq 0) { $progressBar.Value = 100 }
    Add-Log $statusLabel.Text
    # Only after a failure: yt-dlp also mentions the bot check in warnings it
    # goes on to recover from.
    if ($exitCode -ne 0 -and $script:botCheck) {
        if ($script:queueBrowser) {
            Add-Log "YouTube 仍然要求验证：请确认 $($script:queueBrowser) 已登录 YouTube（并且已完全退出该浏览器，否则读不到 cookies），或换一个浏览器、稍后再试。"
        } else {
            Add-Log "YouTube 要求验证你不是机器人。请在「登录状态来源」里选择一个已登录 YouTube 的浏览器后重试。"
        }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "YouTube 独立下载器"
# Taller than it was: the option groups are laid out flat instead of hidden
# behind three dropdowns.
$form.Size = New-Object System.Drawing.Size(820, 790)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$form.MinimumSize = New-Object System.Drawing.Size(820, 700)

$urlLabel = New-Object System.Windows.Forms.Label
$urlLabel.Text = "YouTube 链接"
$urlLabel.Location = New-Object System.Drawing.Point(20, 22)
$urlLabel.AutoSize = $true
$form.Controls.Add($urlLabel)

$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.Location = New-Object System.Drawing.Point(20, 48)
$urlBox.Size = New-Object System.Drawing.Size(760, 30)
$urlBox.Anchor = "Top,Left,Right"
$form.Controls.Add($urlBox)

# Every choice sits on the page instead of inside a dropdown: closed combo
# boxes hid what was on offer, and left nowhere to show that a particular video
# cannot deliver some of it.
$modeGroup = New-Object System.Windows.Forms.GroupBox
$modeGroup.Text = "下载类型（可多选）"
$modeGroup.Location = New-Object System.Drawing.Point(20, 90)
$modeGroup.Size = New-Object System.Drawing.Size(180, 140)
$form.Controls.Add($modeGroup)

$script:modeChecks = [ordered]@{}
$modeIndex = 0
foreach ($mode in @(
    @{ Value = "video"; Text = "视频（MP4）" },
    @{ Value = "audio"; Text = "音频（MP3）" },
    @{ Value = "subtitles"; Text = "字幕（SRT）" })) {
    $check = New-Object System.Windows.Forms.CheckBox
    $check.Text = $mode.Text
    $check.Tag = $mode.Value
    $check.AutoSize = $true
    $check.Location = New-Object System.Drawing.Point(16, (30 + 32 * $modeIndex))
    $check.Checked = ($mode.Value -eq "video")
    # The quality group only applies to the video download, so it follows this.
    $check.Add_CheckedChanged({ Update-OptionEnabled })
    $modeGroup.Controls.Add($check)
    $script:modeChecks[$mode.Value] = $check
    $modeIndex++
}

$qualityGroup = New-Object System.Windows.Forms.GroupBox
$qualityGroup.Text = "视频画质（单选）"
$qualityGroup.Location = New-Object System.Drawing.Point(212, 90)
$qualityGroup.Size = New-Object System.Drawing.Size(170, 140)
$form.Controls.Add($qualityGroup)

$script:qualityRadios = [ordered]@{}
$qualityIndex = 0
foreach ($quality in @(
    @{ Value = "best"; Text = "最佳画质" },
    @{ Value = "1080"; Text = "最高 1080p" },
    @{ Value = "720"; Text = "最高 720p" },
    @{ Value = "480"; Text = "最高 480p" })) {
    $radio = New-Object System.Windows.Forms.RadioButton
    $radio.Text = $quality.Text
    $radio.Tag = $quality.Value
    $radio.AutoSize = $true
    $radio.Location = New-Object System.Drawing.Point(16, (26 + 27 * $qualityIndex))
    $radio.Checked = ($quality.Value -eq "best")
    $qualityGroup.Controls.Add($radio)
    $script:qualityRadios[$quality.Value] = $radio
    $qualityIndex++
}

$browserGroup = New-Object System.Windows.Forms.GroupBox
$browserGroup.Text = "登录状态来源（单选）"
$browserGroup.Location = New-Object System.Drawing.Point(394, 90)
$browserGroup.Size = New-Object System.Drawing.Size(210, 140)
$form.Controls.Add($browserGroup)

$script:browserRadios = [ordered]@{}
$browserIndex = 0
foreach ($browser in @(
    @{ Value = ""; Text = "不使用" },
    @{ Value = "chrome"; Text = "Chrome" },
    @{ Value = "edge"; Text = "Edge" },
    @{ Value = "firefox"; Text = "Firefox" },
    @{ Value = "brave"; Text = "Brave" })) {
    $radio = New-Object System.Windows.Forms.RadioButton
    $radio.Text = $browser.Text
    $radio.Tag = $browser.Value
    $radio.AutoSize = $true
    $radio.Location = New-Object System.Drawing.Point((16 + 100 * [int]($browserIndex -ge 3)), (26 + 27 * ($browserIndex % 3)))
    $radio.Checked = ($browser.Value -eq "")
    # Cookies can be what makes a probe succeed, so switching re-runs it --
    # unless the switch came from Update-OptionEnabled resetting a browser that
    # turns out not to be installed.
    $radio.Add_CheckedChanged({
        if ($this.Checked -and -not $script:updatingOptions) { Request-VideoProbe }
    })
    $browserGroup.Controls.Add($radio)
    $script:browserRadios[$browser.Value] = $radio
    $browserIndex++
}

$extraGroup = New-Object System.Windows.Forms.GroupBox
$extraGroup.Text = "其他"
$extraGroup.Location = New-Object System.Drawing.Point(616, 90)
$extraGroup.Size = New-Object System.Drawing.Size(164, 140)
$extraGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($extraGroup)

$playlistCheck = New-Object System.Windows.Forms.CheckBox
$playlistCheck.Text = "下载整个播放列表"
$playlistCheck.Location = New-Object System.Drawing.Point(16, 30)
$playlistCheck.AutoSize = $true
$extraGroup.Controls.Add($playlistCheck)

$probeButton = New-Object System.Windows.Forms.Button
$probeButton.Text = "重新检测"
$probeButton.Location = New-Object System.Drawing.Point(16, 66)
$probeButton.Size = New-Object System.Drawing.Size(120, 32)
$extraGroup.Controls.Add($probeButton)

$probeLabel = New-Object System.Windows.Forms.Label
$probeLabel.Text = "可用选项：填入链接后自动检测"
$probeLabel.Location = New-Object System.Drawing.Point(20, 240)
$probeLabel.Size = New-Object System.Drawing.Size(760, 22)
$probeLabel.Anchor = "Top,Left,Right"
$form.Controls.Add($probeLabel)

$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Text = "保存目录"
$folderLabel.Location = New-Object System.Drawing.Point(20, 272)
$folderLabel.AutoSize = $true
$form.Controls.Add($folderLabel)

$folderBox = New-Object System.Windows.Forms.TextBox
$folderBox.Location = New-Object System.Drawing.Point(20, 297)
$folderBox.Size = New-Object System.Drawing.Size(650, 30)
$folderBox.Anchor = "Top,Left,Right"
$folderBox.Text = [Environment]::GetFolderPath("MyVideos")
$form.Controls.Add($folderBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "浏览..."
$browseButton.Location = New-Object System.Drawing.Point(685, 295)
$browseButton.Size = New-Object System.Drawing.Size(95, 32)
$browseButton.Anchor = "Top,Right"
$form.Controls.Add($browseButton)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = "安装/更新依赖"
$installButton.Location = New-Object System.Drawing.Point(20, 347)
$installButton.Size = New-Object System.Drawing.Size(145, 38)
$form.Controls.Add($installButton)

$downloadButton = New-Object System.Windows.Forms.Button
$downloadButton.Text = "开始下载"
$downloadButton.Location = New-Object System.Drawing.Point(180, 347)
$downloadButton.Size = New-Object System.Drawing.Size(145, 38)
$downloadButton.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 220)
$downloadButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($downloadButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "取消"
$cancelButton.Location = New-Object System.Drawing.Point(340, 347)
$cancelButton.Size = New-Object System.Drawing.Size(100, 38)
$cancelButton.Enabled = $false
$form.Controls.Add($cancelButton)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(465, 349)
$progressBar.Size = New-Object System.Drawing.Size(315, 14)
$progressBar.Anchor = "Top,Left,Right"
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$form.Controls.Add($progressBar)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.Location = New-Object System.Drawing.Point(465, 369)
$statusLabel.Size = New-Object System.Drawing.Size(315, 22)
$statusLabel.Anchor = "Top,Left,Right"
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 405)
$logBox.Size = New-Object System.Drawing.Size(760, 290)
$logBox.Anchor = "Top,Bottom,Left,Right"
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
$logBox.ForeColor = [System.Drawing.Color]::Gainsboro
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($logBox)

# Draining the queue on a timer keeps a playlist's thousands of output lines
# from marshalling one UI call each, and caps how much the log box retains.
function Update-LogBox {
    $batch = New-Object System.Text.StringBuilder
    $line = $null
    $count = 0
    while ($count -lt 500 -and $script:logQueue.TryDequeue([ref]$line)) {
        [void]$batch.AppendLine($line)
        if ($line -match '\[download\]\s+(\d{1,3})(?:\.\d+)?%') {
            $progressBar.Value = [Math]::Min(100, [int]$Matches[1])
        }
        $count++
    }
    if ($count -eq 0) { return }

    if ($logBox.Lines.Count -gt $script:maxLogLines) {
        $keep = $logBox.Lines | Select-Object -Last ([int]($script:maxLogLines / 2))
        $logBox.Text = ($keep -join [Environment]::NewLine) + [Environment]::NewLine
    }
    $logBox.AppendText($batch.ToString())
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 120
$logTimer.Add_Tick({
    # Order matters: the child's output is queued first, so the status line the
    # exit callback logs lands after the output it refers to.
    Update-ChildProcess
    Update-LogBox
})
$logTimer.Start()

# One shot, restarted on every keystroke: the probe runs once the typing or
# pasting has stopped.
$probeTimer = New-Object System.Windows.Forms.Timer
$probeTimer.Interval = 700
$probeTimer.Add_Tick({ Start-VideoProbe })

$urlBox.Add_TextChanged({ Request-VideoProbe })
$probeButton.Add_Click({
    # Forget what was last probed so the same link is checked again.
    $script:probedKey = ""
    Start-VideoProbe
})

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $folderBox.Text
    if ($dialog.ShowDialog() -eq "OK") { $folderBox.Text = $dialog.SelectedPath }
})

$installButton.Add_Click({
    $installer = Join-Path $scriptDir "Install-Dependencies.ps1"
    if (-not (Test-Path $installer)) {
        [System.Windows.Forms.MessageBox]::Show("找不到 Install-Dependencies.ps1。", "缺少文件") | Out-Null
        return
    }
    $logBox.Clear()
    $progressBar.Value = 0
    Add-Log "正在安装/更新依赖，请稍候..."
    # Run redirected instead of Start-Process -Wait so the window stays responsive.
    Start-ToolProcess "powershell.exe" `
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installer) `
        "正在安装依赖..." `
        {
            param($exitCode)
            Set-Busy $false $(if ($exitCode -eq 0) { "依赖已就绪" } else { "依赖安装失败，退出代码：$exitCode" })
            Add-Log $statusLabel.Text
        } | Out-Null
})

$cancelButton.Add_Click({
    # Set first: killing only the running process would let the queue move
    # straight on to the next ticked download type.
    $script:queueCancelled = $true
    $script:queueModes = @()
    if ($script:activeProcess) {
        Stop-ProcessTree $script:activeProcess
        Add-Log "已取消当前任务。"
    }
})

$downloadButton.Add_Click({
    $url = $urlBox.Text.Trim()
    if ($url -notmatch '^https?://([\w-]+\.)*(youtube\.com|youtu\.be)/') {
        [System.Windows.Forms.MessageBox]::Show("请输入有效的 YouTube 链接。", "链接无效") | Out-Null
        return
    }
    $modes = Get-SelectedMode
    if ($modes.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("请至少勾选一种下载类型。", "缺少下载类型") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($folderBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("请选择保存目录。", "缺少目录") | Out-Null
        return
    }

    $ytDlp = Find-Executable "yt-dlp" (Join-Path $toolsDir "yt-dlp.exe")
    if (-not $ytDlp) {
        [System.Windows.Forms.MessageBox]::Show("未找到 yt-dlp。请先点击安装/更新依赖按钮。", "缺少依赖") | Out-Null
        return
    }

    try {
        New-Item -ItemType Directory -Force -Path $folderBox.Text | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("无法创建保存目录：$($_.Exception.Message)", "目录错误") | Out-Null
        return
    }

    $ffmpegDir = Resolve-FfmpegDirectory
    if (-not $ffmpegDir -and -not (Get-Command "ffmpeg" -ErrorAction SilentlyContinue)) {
        Add-Log "警告：未找到 FFmpeg，合并 MP4、转 MP3 和字幕转换可能失败。"
    }

    $logBox.Clear()
    $progressBar.Value = 0
    $script:botCheck = $false
    # Script-scoped: the exit callback runs in Start-ToolProcess's scope and
    # cannot see locals from this click handler.
    $script:queueModes = @($modes)
    $script:queueTotal = $modes.Count
    $script:queueIndex = 0
    $script:queueCancelled = $false
    $script:queueUrl = $url
    $script:queueQuality = Get-SelectedQuality
    $script:queueOutputDir = $folderBox.Text
    $script:queuePlaylist = $playlistCheck.Checked
    $script:queueBrowser = Get-SelectedBrowser
    $script:queueFfmpegDir = $(if ($ffmpegDir) { $ffmpegDir } else { "" })
    $script:queueTool = $ytDlp
    Add-Log "开始下载：$url"
    Start-QueuedDownload
})

$form.Add_FormClosing({
    $logTimer.Stop()
    $probeTimer.Stop()
    $script:queueCancelled = $true
    $script:queueModes = @()
    Stop-ProcessTree $script:activeProcess
    if ($script:probeJob) { Stop-ProcessTree $script:probeJob.Process }
    foreach ($job in $script:jobs) {
        foreach ($tap in @($job.Out, $job.Err)) {
            # Best effort: the window is going away, and a temp file left behind
            # is not worth blocking the close over.
            try { $tap.Target.Dispose() } catch { Write-Verbose $_.Exception.Message }
            Remove-Item -LiteralPath $tap.Path -Force -ErrorAction SilentlyContinue
        }
    }
})

# Before the window appears, so browsers that are not installed are already
# greyed out rather than failing later inside yt-dlp.
Update-OptionEnabled

if ($SmokeTest) {
    # Building the form proves nothing about the buttons: every one of them goes
    # through Start-ToolProcess, and that path taking the window down with it is
    # exactly what shipped. So run a real child process through the real
    # plumbing and pump the timer's work by hand.
    $logTimer.Stop()
    $failures = @()
    $observed = @{}

    Start-ToolProcess "cmd.exe" @("/c", "echo smoke-line& exit 7") "smoke" {
        param($exitCode)
        $observed["exitCode"] = $exitCode
    } | Out-Null

    $deadline = (Get-Date).AddSeconds(30)
    while (-not $observed.ContainsKey("exitCode") -and (Get-Date) -lt $deadline) {
        Update-ChildProcess
        Update-LogBox
        Start-Sleep -Milliseconds 50
    }

    if (-not $observed.ContainsKey("exitCode")) {
        $failures += "the exit callback never ran (output plumbing is stuck)"
    } elseif ($observed["exitCode"] -ne 7) {
        $failures += "exit code was $($observed['exitCode']), expected 7"
    }
    if ($logBox.Text -notmatch "smoke-line") {
        $failures += "child output never reached the log box"
    }
    if ($script:activeProcess) {
        $failures += "the finished process was not released"
    }

    $script:botCheck = $false
    Receive-ToolOutput "ERROR: [youtube] ID: Sign in to confirm you are not a bot."
    if (-not $script:botCheck) { $failures += "the bot-check line was not recognised" }

    # A child writing UTF-8 must survive the tap, the stateful decoder and the
    # log box intact: a real run showed yt-dlp's curly quote arriving as U+FFFD.
    # Assembled from a char code, and handed to the child through the
    # environment, so neither this file nor the generated one contains a smart
    # quote. U+2019 is the character yt-dlp actually emits.
    $sample = "标题 title with a curly quote: you" + [char]0x2019 + "re ok"
    $env:YTDL_SMOKE_SAMPLE = $sample
    # The child also reports PYTHONUTF8 back: Start-ToolProcess sets it through
    # StartInfo.EnvironmentVariables, and a real yt-dlp run wrote the system
    # codepage anyway, so whether the variable even arrives is worth knowing.
    # And it writes one line of raw non-UTF-8 bytes, which must come back
    # through the ANSI fallback rather than as U+FFFD.
    $ansiBytes = [byte[]](0x79, 0x6F, 0x75, 0x92, 0x72, 0x65)
    $ansiExpected = $script:ansiEncoding.GetString($ansiBytes)
    $childScript = Join-Path ([System.IO.Path]::GetTempPath()) "yt-dl-smoke-child.ps1"
    [System.IO.File]::WriteAllText(
        $childScript,
        ("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`r`n" +
         "Write-Output `"PYTHONUTF8=`$env:PYTHONUTF8`"`r`n" +
         "Write-Output `$env:YTDL_SMOKE_SAMPLE`r`n" +
         "`$raw = [System.Console]::OpenStandardOutput()`r`n" +
         "`$bytes = [byte[]](0x79,0x6F,0x75,0x92,0x72,0x65,0x0D,0x0A)`r`n" +
         "`$raw.Write(`$bytes, 0, `$bytes.Length)`r`n" +
         "`$raw.Flush()`r`n"),
        (New-Object System.Text.UTF8Encoding($true)))
    $observed.Remove("exitCode")
    Start-ToolProcess "powershell.exe" `
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $childScript) "smoke" {
        param($exitCode)
        $observed["exitCode"] = $exitCode
    } | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $observed.ContainsKey("exitCode") -and (Get-Date) -lt $deadline) {
        Update-ChildProcess
        Update-LogBox
        Start-Sleep -Milliseconds 50
    }
    Remove-Item -LiteralPath $childScript -Force -ErrorAction SilentlyContinue
    if ($logBox.Text -notmatch [regex]::Escape($sample)) {
        $failures += "UTF-8 child output was mangled; log box holds: $($logBox.Text)"
    }
    if ($logBox.Text -notmatch [regex]::Escape($ansiExpected)) {
        $failures += "non-UTF-8 line did not fall back to the ANSI codepage"
    }
    if ($logBox.Text -match [char]0xFFFD) {
        $failures += "a replacement character reached the log box"
    }
    # Reported, not asserted: it is a diagnosis, and the reader no longer
    # depends on the answer.
    $delivered = if ($logBox.Text -match "PYTHONUTF8=1") { "yes" } else { "no" }
    Write-Host "child environment delivery: PYTHONUTF8 arrived = $delivered"

    # This script's own Chinese, curly quotes included, must reach the box whole:
    # a real run appeared to stop at the opening quote of 登录状态来源.
    $hint = "YouTube 要求验证你不是机器人。请在「登录状态来源」里选择一个已登录 YouTube 的浏览器后重试。"
    Add-Log $hint
    Update-LogBox
    if ($logBox.Text -notmatch [regex]::Escape($hint)) {
        $failures += "the bot-check hint did not survive the log box intact"
    }

    # --- the flattened options ------------------------------------------
    # Every choice is a control the user can see, and a probe result has to be
    # able to switch each one off. Neither half was ever exercised by anything
    # but a human before.
    if ($script:modeChecks.Count -ne 3) { $failures += "expected 3 download-type check boxes" }
    if ($script:qualityRadios.Count -ne 4) { $failures += "expected 4 quality radio buttons" }
    if ($script:browserRadios.Count -ne 5) { $failures += "expected 5 login-source radio buttons" }
    if (-not $script:modeChecks["video"].Checked) { $failures += "video is not ticked by default" }
    if ((((Get-SelectedMode) -join ",")) -ne "video") { $failures += "Get-SelectedMode did not report the ticked type" }
    if ((Get-SelectedQuality) -ne "best") { $failures += "Get-SelectedQuality did not report 最佳画质" }
    if ((Get-SelectedBrowser) -ne "") { $failures += "Get-SelectedBrowser did not report 不使用" }

    # A 720p video with English subtitles: 1080p must go grey, and a selection
    # that is no longer on offer must fall back rather than silently stay.
    $sampleJson = '{"title":"probe sample","formats":[' +
        '{"height":720,"acodec":"none"},{"height":360,"acodec":"none"},' +
        '{"height":null,"acodec":"mp4a.40.2"}],' +
        '"subtitles":{"en":[{"ext":"vtt"}]},"automatic_captions":{}}'
    $available = Get-AvailableOption -Info ($sampleJson | ConvertFrom-Json)
    if (-not $available.Modes.video) { $failures += "sample video was reported as having no video" }
    if (-not $available.Modes.audio) { $failures += "sample video was reported as having no audio" }
    if (-not $available.Modes.subtitles) { $failures += "the English subtitle track was missed" }
    if ($available.Qualities["1080"]) { $failures += "1080p was offered for a 720p-only video" }
    if (-not $available.Qualities["720"]) { $failures += "720p was withheld from a 720p video" }
    if (-not $available.Qualities["480"]) { $failures += "480p was withheld from a 720p video" }
    if ((Format-OptionSummary $available) -notmatch "最高 720p") {
        $failures += "the summary did not report the highest available quality"
    }

    $script:qualityRadios["1080"].Checked = $true
    $script:availableModes = $available.Modes
    $script:availableQualities = $available.Qualities
    Update-OptionEnabled
    if ($script:qualityRadios["1080"].Enabled) { $failures += "the unavailable 1080p radio stayed enabled" }
    if (-not $script:qualityRadios["best"].Checked) {
        $failures += "an unavailable quality stayed selected instead of falling back"
    }

    # A video with no subtitles: the type itself has to go grey and untick.
    $noSubs = Get-AvailableOption -Info ('{"formats":[{"height":1080,"acodec":"mp4a.40.2"}]}' | ConvertFrom-Json)
    $script:modeChecks["subtitles"].Checked = $true
    $script:availableModes = $noSubs.Modes
    $script:availableQualities = $noSubs.Qualities
    Update-OptionEnabled
    if ($script:modeChecks["subtitles"].Enabled) { $failures += "字幕 stayed available on a video without any" }
    if ($script:modeChecks["subtitles"].Checked) { $failures += "字幕 stayed ticked after going unavailable" }

    # An empty probe must give everything back rather than lock the window down.
    Reset-OptionAvailability "smoke"
    foreach ($mode in $script:modeChecks.Keys) {
        if (-not $script:modeChecks[$mode].Enabled) { $failures += "$mode stayed disabled after a reset" }
    }

    # Unticking 视频 greys out the quality group, which only applies to it.
    $script:modeChecks["video"].Checked = $false
    if ($script:qualityRadios["best"].Enabled) {
        $failures += "the quality group stayed enabled with 视频 unticked"
    }
    $script:modeChecks["video"].Checked = $true

    $probeArguments = Build-ProbeArgumentList -Url "https://youtu.be/ID" -CookiesBrowser "chrome"
    if ($probeArguments[0] -ne "--dump-single-json" -or $probeArguments[-1] -ne "https://youtu.be/ID") {
        $failures += "the probe command is not shaped like yt-dlp expects"
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Host "smoke test FAILED: $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "smoke test ok: PowerShell $($PSVersionTable.PSVersion), $($form.Controls.Count) controls, child output and exit code observed"
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
