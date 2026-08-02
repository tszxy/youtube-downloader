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
# The running child's stdout/stderr taps and its completion callback; see
# Update-ToolProcess for why the UI timer owns both rather than .NET events.
$script:taps = @()
$script:onExitAction = $null

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
        Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
        Partial = ""
    }
}

function Read-TapOutput($tap) {
    # Whole lines only; a trailing partial line waits for the next tick. The
    # decoder carries state, so a UTF-8 sequence split across reads survives.
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
        $chars = New-Object char[] ($tap.Decoder.GetCharCount($buffer, 0, $read))
        [void]$tap.Decoder.GetChars($buffer, 0, $read, $chars, 0)
        $text = $tap.Partial + (-join $chars)
        $parts = $text -split '\r?\n'
        $tap.Partial = $parts[-1]
        if ($parts.Count -gt 1) { $lines = $parts[0..($parts.Count - 2)] }
    } catch {
        # A tick that loses the race with the writer retries on the next one,
        # so drop whatever this pass read rather than emitting a partial line.
        $lines = @()
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    return $lines
}

function Update-ToolProcess {
    # Driven by the UI timer, so everything here runs on the UI thread with a
    # runspace available. This replaced add_OutputDataReceived/add_Exited: those
    # fire on threadpool threads, where a PowerShell scriptblock has no runspace
    # and the resulting failure closed the whole window on the first click.
    if (-not $script:taps -or $script:taps.Count -eq 0) { return }
    foreach ($tap in $script:taps) {
        foreach ($line in (Read-TapOutput $tap)) { Receive-ToolOutput $line }
    }

    $process = $script:activeProcess
    if (-not $process -or -not $process.HasExited) { return }
    foreach ($tap in $script:taps) {
        if (-not $tap.Task.IsCompleted) { return }
    }

    foreach ($tap in $script:taps) {
        foreach ($line in (Read-TapOutput $tap)) { Receive-ToolOutput $line }
        if ($tap.Partial) {
            Receive-ToolOutput $tap.Partial
            $tap.Partial = ""
        }
        $tap.Target.Dispose()
        Remove-Item -LiteralPath $tap.Path -Force -ErrorAction SilentlyContinue
    }

    $exitCode = $process.ExitCode
    $onExit = $script:onExitAction
    $script:taps = @()
    $script:onExitAction = $null
    $script:activeProcess = $null
    $process.Dispose()
    if ($onExit) { & $onExit $exitCode }
}

function Start-ToolProcess([string]$fileName, [string[]]$arguments, [string]$busyStatus, [scriptblock]$onExit) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $fileName
    $startInfo.Arguments = ($arguments | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join " "
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

    Set-Busy $true $busyStatus
    try {
        [void]$process.Start()
    } catch {
        Set-Busy $false "启动失败"
        Add-Log "无法启动 $fileName：$($_.Exception.Message)"
        return $null
    }

    $script:taps = @(
        (New-OutputTap $process.StandardOutput.BaseStream),
        (New-OutputTap $process.StandardError.BaseStream)
    )
    $script:onExitAction = $onExit
    $script:activeProcess = $process
    return $process
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "YouTube 独立下载器"
$form.Size = New-Object System.Drawing.Size(820, 650)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$form.MinimumSize = New-Object System.Drawing.Size(780, 600)

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

$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = "下载类型"
$modeLabel.Location = New-Object System.Drawing.Point(20, 95)
$modeLabel.AutoSize = $true
$form.Controls.Add($modeLabel)

$modeBox = New-Object System.Windows.Forms.ComboBox
$modeBox.DropDownStyle = "DropDownList"
$modeBox.Location = New-Object System.Drawing.Point(20, 120)
$modeBox.Size = New-Object System.Drawing.Size(190, 30)
[void]$modeBox.Items.AddRange(@("视频（MP4）", "音频（MP3）", "字幕（SRT）"))
$modeBox.SelectedIndex = 0
$form.Controls.Add($modeBox)

$qualityLabel = New-Object System.Windows.Forms.Label
$qualityLabel.Text = "视频画质"
$qualityLabel.Location = New-Object System.Drawing.Point(230, 95)
$qualityLabel.AutoSize = $true
$form.Controls.Add($qualityLabel)

$qualityBox = New-Object System.Windows.Forms.ComboBox
$qualityBox.DropDownStyle = "DropDownList"
$qualityBox.Location = New-Object System.Drawing.Point(230, 120)
$qualityBox.Size = New-Object System.Drawing.Size(160, 30)
[void]$qualityBox.Items.AddRange(@("最佳画质", "最高 1080p", "最高 720p", "最高 480p"))
$qualityBox.SelectedIndex = 0
$form.Controls.Add($qualityBox)

$browserLabel = New-Object System.Windows.Forms.Label
$browserLabel.Text = "登录状态来源"
$browserLabel.Location = New-Object System.Drawing.Point(410, 95)
$browserLabel.AutoSize = $true
$form.Controls.Add($browserLabel)

$browserBox = New-Object System.Windows.Forms.ComboBox
$browserBox.DropDownStyle = "DropDownList"
$browserBox.Location = New-Object System.Drawing.Point(410, 120)
$browserBox.Size = New-Object System.Drawing.Size(150, 30)
[void]$browserBox.Items.AddRange(@("不使用", "Chrome", "Edge", "Firefox", "Brave"))
$browserBox.SelectedIndex = 0
$form.Controls.Add($browserBox)

$playlistCheck = New-Object System.Windows.Forms.CheckBox
$playlistCheck.Text = "下载整个播放列表"
$playlistCheck.Location = New-Object System.Drawing.Point(585, 122)
$playlistCheck.AutoSize = $true
$form.Controls.Add($playlistCheck)

$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Text = "保存目录"
$folderLabel.Location = New-Object System.Drawing.Point(20, 175)
$folderLabel.AutoSize = $true
$form.Controls.Add($folderLabel)

$folderBox = New-Object System.Windows.Forms.TextBox
$folderBox.Location = New-Object System.Drawing.Point(20, 200)
$folderBox.Size = New-Object System.Drawing.Size(650, 30)
$folderBox.Anchor = "Top,Left,Right"
$folderBox.Text = [Environment]::GetFolderPath("MyVideos")
$form.Controls.Add($folderBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "浏览..."
$browseButton.Location = New-Object System.Drawing.Point(685, 198)
$browseButton.Size = New-Object System.Drawing.Size(95, 32)
$browseButton.Anchor = "Top,Right"
$form.Controls.Add($browseButton)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = "安装/更新依赖"
$installButton.Location = New-Object System.Drawing.Point(20, 250)
$installButton.Size = New-Object System.Drawing.Size(145, 38)
$form.Controls.Add($installButton)

$downloadButton = New-Object System.Windows.Forms.Button
$downloadButton.Text = "开始下载"
$downloadButton.Location = New-Object System.Drawing.Point(180, 250)
$downloadButton.Size = New-Object System.Drawing.Size(145, 38)
$downloadButton.BackColor = [System.Drawing.Color]::FromArgb(40, 120, 220)
$downloadButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($downloadButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "取消"
$cancelButton.Location = New-Object System.Drawing.Point(340, 250)
$cancelButton.Size = New-Object System.Drawing.Size(100, 38)
$cancelButton.Enabled = $false
$form.Controls.Add($cancelButton)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(465, 252)
$progressBar.Size = New-Object System.Drawing.Size(315, 14)
$progressBar.Anchor = "Top,Left,Right"
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$form.Controls.Add($progressBar)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.Location = New-Object System.Drawing.Point(465, 272)
$statusLabel.Size = New-Object System.Drawing.Size(315, 22)
$statusLabel.Anchor = "Top,Left,Right"
$form.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(20, 310)
$logBox.Size = New-Object System.Drawing.Size(760, 285)
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
    Update-ToolProcess
    Update-LogBox
})
$logTimer.Start()

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

    $arguments = Build-YtDlpArgumentList `
        -Url $url `
        -Mode @("video", "audio", "subtitles")[$modeBox.SelectedIndex] `
        -Quality @("best", "1080", "720", "480")[$qualityBox.SelectedIndex] `
        -OutputDir $folderBox.Text `
        -Playlist $playlistCheck.Checked `
        -CookiesBrowser $(if ($browserBox.SelectedIndex -gt 0) { $browserBox.SelectedItem.ToString().ToLowerInvariant() } else { "" }) `
        -FfmpegDir $(if ($ffmpegDir) { $ffmpegDir } else { "" })

    $logBox.Clear()
    $progressBar.Value = 0
    $script:botCheck = $false
    # Script-scoped: the exit callback runs in Start-ToolProcess's scope and
    # cannot see locals from this click handler.
    $script:cookieBrowser = if ($browserBox.SelectedIndex -gt 0) { $browserBox.SelectedItem.ToString() } else { "" }
    Add-Log "开始下载：$url"
    Start-ToolProcess $ytDlp $arguments "正在下载..." {
        param($exitCode)
        Set-Busy $false $(if ($exitCode -eq 0) { "下载完成" } else { "下载失败，退出代码：$exitCode" })
        if ($exitCode -eq 0) { $progressBar.Value = 100 }
        Add-Log $statusLabel.Text
        # Only after a failure: yt-dlp also mentions the bot check in warnings
        # it goes on to recover from.
        if ($exitCode -ne 0 -and $script:botCheck) {
            if ($script:cookieBrowser) {
                Add-Log "YouTube 仍然要求验证：请确认 $($script:cookieBrowser) 已登录 YouTube（并且已完全退出该浏览器，否则读不到 cookies），或换一个浏览器、稍后再试。"
            } else {
                Add-Log "YouTube 要求验证你不是机器人。请在「浏览器登录状态」里选择一个已登录 YouTube 的浏览器后重试。"
            }
        }
    } | Out-Null
})

$form.Add_FormClosing({
    $logTimer.Stop()
    Stop-ProcessTree $script:activeProcess
    foreach ($tap in $script:taps) {
        # Best effort: the window is going away, and a temp file left behind is
        # not worth blocking the close over.
        try { $tap.Target.Dispose() } catch { Write-Verbose $_.Exception.Message }
        Remove-Item -LiteralPath $tap.Path -Force -ErrorAction SilentlyContinue
    }
})

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
        Update-ToolProcess
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
    $childScript = Join-Path ([System.IO.Path]::GetTempPath()) "yt-dl-smoke-child.ps1"
    [System.IO.File]::WriteAllText(
        $childScript,
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`r`nWrite-Output `$env:YTDL_SMOKE_SAMPLE`r`n",
        (New-Object System.Text.UTF8Encoding($true)))
    $observed.Remove("exitCode")
    Start-ToolProcess "powershell.exe" `
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $childScript) "smoke" {
        param($exitCode)
        $observed["exitCode"] = $exitCode
    } | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $observed.ContainsKey("exitCode") -and (Get-Date) -lt $deadline) {
        Update-ToolProcess
        Update-LogBox
        Start-Sleep -Milliseconds 50
    }
    Remove-Item -LiteralPath $childScript -Force -ErrorAction SilentlyContinue
    if ($logBox.Text -notmatch [regex]::Escape($sample)) {
        $failures += "UTF-8 child output was mangled; log box holds: $($logBox.Text)"
    }

    # This script's own Chinese, curly quotes included, must reach the box whole:
    # a real run appeared to stop at the opening quote of 浏览器登录状态.
    $hint = "YouTube 要求验证你不是机器人。请在「浏览器登录状态」里选择一个已登录 YouTube 的浏览器后重试。"
    Add-Log $hint
    Update-LogBox
    if ($logBox.Text -notmatch [regex]::Escape($hint)) {
        $failures += "the bot-check hint did not survive the log box intact"
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
