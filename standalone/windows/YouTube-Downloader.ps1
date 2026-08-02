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
    [switch]$PrintCommand
)

$ErrorActionPreference = "Stop"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolsDir = Join-Path $scriptDir "tools"
$script:activeProcess = $null
$script:logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:maxLogLines = 2000

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

function Set-Busy([bool]$busy, [string]$status) {
    $downloadButton.Enabled = -not $busy
    $installButton.Enabled = -not $busy
    $cancelButton.Enabled = $busy
    $statusLabel.Text = $status
}

function Start-ToolProcess([string]$fileName, [string[]]$arguments, [string]$busyStatus, [scriptblock]$onExit) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $fileName
    $startInfo.Arguments = ($arguments | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.EnableRaisingEvents = $true
    $process.add_OutputDataReceived({ if ($EventArgs.Data) { Add-Log $EventArgs.Data } })
    $process.add_ErrorDataReceived({ if ($EventArgs.Data) { Add-Log $EventArgs.Data } })
    $process.add_Exited({
        $exitCode = $process.ExitCode
        $form.BeginInvoke([Action]{ & $onExit $exitCode }) | Out-Null
    })

    Set-Busy $true $busyStatus
    try {
        [void]$process.Start()
    } catch {
        Set-Busy $false "启动失败"
        Add-Log "无法启动 $fileName：$($_.Exception.Message)"
        return $null
    }
    $script:activeProcess = $process
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
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
$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 120
$logTimer.Add_Tick({
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
    Add-Log "开始下载：$url"
    Start-ToolProcess $ytDlp $arguments "正在下载..." {
        param($exitCode)
        Set-Busy $false $(if ($exitCode -eq 0) { "下载完成" } else { "下载失败，退出代码：$exitCode" })
        if ($exitCode -eq 0) { $progressBar.Value = 100 }
        Add-Log $statusLabel.Text
    } | Out-Null
})

$form.Add_FormClosing({
    $logTimer.Stop()
    Stop-ProcessTree $script:activeProcess
})

[void]$form.ShowDialog()
