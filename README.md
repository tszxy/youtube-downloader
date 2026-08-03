# YouTube 下载器

基于 [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) 的独立下载器：视频、MP3、字幕、播放列表。

**不需要 Codex**。`standalone/` 目录可以单独拷出来使用，不依赖本仓库其他任何东西。
仓库里另外附带一个可选的 Codex 插件，是对同一个下载器的封装。

## 功能

- 视频合并为 MP4，可限制 1080p / 720p / 480p
- 音频提取为 MP3
- 中英文人工字幕和自动字幕，转换为 SRT
- YouTube Shorts、播放列表
- 可选读取浏览器登录状态（Chrome / Edge / Firefox / Brave / Safari 等）
- 图形界面里所有选项平铺可见，填入链接后自动检测这个视频能提供什么，
  给不出的选项直接置灰（详见[图形界面](#图形界面)）
- 下载类型可多选：视频、音频、字幕勾几个就依次下几个
- 分片并发下载，明显快于串行
- 默认不覆盖已有文件
- 取消时连同 ffmpeg 子进程一起结束，不留孤儿进程

## 快速开始

### macOS

```bash
brew install yt-dlp ffmpeg          # 依赖
cd standalone
./Run-macOS.command                 # 图形界面（也可在访达里双击）
```

命令行：

```bash
python3 standalone/youtube_downloader.py "https://youtu.be/VIDEO_ID" -o ~/Downloads
```

> 首次双击 `.command` 时 macOS 可能拦截：右键 → 打开 → 确认一次即可。

### Windows

两种方式，任选其一。

**A. 不需要装任何东西**（PowerShell 图形版）

1. 打开 `standalone\windows\`
2. 双击 `YouTube-Downloader.bat` —— **每次都是它，没有第二个要选**

界面打开后会自检 yt-dlp 和 FFmpeg：缺哪个就问你要不要现在装（下载到 `tools\`，
校验 SHA-256），都齐了就直接进主界面，不打扰。所以第一次和以后没有区别。

> `Install-and-Run.bat` 和 `Run-Downloader.bat` 仍然保留，只是转发到上面那个，
> 免得旧的快捷方式失效。新用户认准 `YouTube-Downloader.bat` 就行。

安装时每个下载都应该打印 `checksum ok`。如果看到黄色的
`no published checksum for ..., skipping verification`，说明校验没做成，
请提 issue —— 这不是正常输出。手动补验：

```powershell
cd standalone\windows
powershell -File Install-Dependencies.ps1 -CheckPublished   # 官方发布的哈希
(Get-FileHash -Algorithm SHA256 tools\yt-dlp.exe).Hash      # 你下到的哈希
```

**B. 已经装了 Python**（跨平台版，功能相同）

```
standalone\Run-Windows.bat
```

如果 Windows 拦下 `.bat`：右键 → 属性 → 勾选"解除锁定"。

> 第一次下载多半会撞上 `Sign in to confirm you're not a bot`。
> 解决办法是在「登录状态来源」里选 Chrome，**并且先彻底退出 Chrome 进程**——
> 关窗口不算。详见[下面这一节](#遇到-sign-in-to-confirm-youre-not-a-bot)。

### Linux

```bash
sudo apt install ffmpeg python3-tk   # tkinter 用于图形界面
pipx install yt-dlp                  # 发行版自带的 yt-dlp 往往过旧
cd standalone
./run-linux.sh                       # 图形界面
./run-linux.sh "https://youtu.be/VIDEO_ID" -o ~/Downloads   # 命令行
```

## 图形界面

三个平台的窗口布局一致（macOS/Linux 是 Python 版，Windows 另有一份 PowerShell 版）：

- **下载类型（可多选）**：视频（MP4）、音频（MP3）、字幕（SRT）。勾多个就按顺序
  一个一个下——yt-dlp 一次只接受一种类型，同时请求同一个视频反而更容易触发限流。
  中途取消会连同还没开始的那几个一起停掉。
- **视频画质（单选）**：只作用于视频下载，没勾「视频」时整组置灰。
- **登录状态来源（单选）**：默认「不使用」。系统里没装的浏览器直接置灰，
  免得选了之后在 yt-dlp 内部报一句看不懂的错。
- **其他**：整个播放列表、「重新检测」。

选项不再藏在下拉框里，因为关着的下拉框既看不见有什么，也没地方标注某个选项对这个
视频不可用。

**自动检测**：链接填好（或粘贴完）约 0.7 秒后，会用 `--dump-single-json` 问一次
yt-dlp 这个视频有什么，然后把给不出的选项置灰：只有 720p 的视频不会让你选 1080p，
没有中英字幕的视频不会让你勾字幕。切换登录状态来源会重新检测，因为 cookies 有时
正是检测能不能成功的关键。手动重来点「重新检测」。

**检测不出来一律算「可用」**：检测失败、超时、或者 yt-dlp 没报告某项信息时，
选项保持全部可选，绝不会因为检测不出来而挡掉一个本来能成功的下载。
检测结果和失败原因显示在选项下方那一行。

## 命令行参数

```
python3 standalone/youtube_downloader.py URL [选项]

  -m, --mode video|audio|subtitles   下载类型（默认 video）
  -q, --quality best|1080|720|480    画质上限（默认 best）
  -o, --output-dir DIR               保存目录（默认当前目录）
      --playlist                     下载整个播放列表
      --cookies-from-browser NAME    使用浏览器登录状态
      --install                      下载便携版 yt-dlp 到 tools/
      --print-command                只打印将要执行的参数，不下载
      --print-probe-command          只打印图形界面用来检测可用选项的参数，不下载
```

例子：

```bash
P=standalone/youtube_downloader.py
python3 $P "https://youtu.be/ID" --mode audio -o ~/Music
python3 $P "https://youtu.be/ID" --quality 720
python3 $P "https://youtu.be/PLAYLIST_URL" --playlist
python3 $P "https://youtu.be/ID" --cookies-from-browser chrome
```

`--quality` 是**上限**不是精确匹配：填 1080 而视频只有 720p 时，下 720p，不会失败。

## 依赖

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| Python 3.8+ | 跨平台版本体 | Windows 可改用 PowerShell 版，无需 Python |
| tkinter | 图形界面 | 命令行仍可用；Linux 装 `python3-tk` |
| yt-dlp | 下载 | 运行 `--install` 自动获取，或 brew / pipx 安装 |
| ffmpeg | 合并 MP4、转 MP3、转字幕 | 会明确警告；纯单流下载仍可用 |

下载突然失败时，第一件事是升级 yt-dlp——YouTube 经常改接口。

## 遇到 "Sign in to confirm you're not a bot"

这是最常见的失败，日志长这样：

```
ERROR: [youtube] XXXXXXXXXXX: Sign in to confirm you're not a bot.
Use --cookies-from-browser or --cookies for the authentication.
下载失败，退出代码：1
```

**这不是程序出错**，是 YouTube 认为请求来自机器人，要求你证明是登录用户。家庭宽带、
公司网络、云主机、VPN 出口都可能触发，同一个链接在另一台机器上往往就没事。
下载因此失败时，工具会在日志最后一行直接把解决办法打出来。

办法是借用浏览器里已登录的身份：

- **图形界面**：在「登录状态来源」里选 Chrome（默认是「不使用」），再点开始下载
- **命令行**：加 `--cookies-from-browser chrome`

```bash
python3 standalone/youtube_downloader.py "URL" --cookies-from-browser chrome
```

可选值：`chrome` / `edge` / `firefox` / `brave` / `safari` / `chromium` / `opera` / `vivaldi`。

### 前提一：那个浏览器里确实登录了 YouTube

打开 youtube.com 看右上角是不是你的头像。没登录的话，读到的 cookies 是匿名的，
和不加这个选项没区别。

### 前提二：必须彻底退出浏览器进程（最容易卡住的一步）

Chrome 运行时会独占 cookies 数据库，yt-dlp 读不到。**关掉所有窗口不等于退出**——
Chrome 默认还会在后台常驻。

> **图形界面会替你处理这一步。** 启动时如果检测到 Chrome 正在运行，会弹窗问你
> 要不要现在退出它；选「是」就自动退出，选「否」则什么都不做。命令行只在
> 加了 `--cookies-from-browser chrome` 且在终端里交互运行时才会问，管道和
> 定时任务里不会卡住等输入。
>
> 退出是先礼后兵：先正常请求退出（不丢已保存的会话），只有 Chrome 在 8 秒内
> 没反应——通常是卡在「确定要离开此页面吗」的弹窗上——才强制结束。
> 无论哪种方式，未保存的网页内容都会丢失。

下面是手动退出的办法，选「否」或想自己动手时用得上。

**Windows：**

1. 关掉所有 Chrome 窗口
2. 看**任务栏右下角的托盘区**（可能要点那个 `^` 展开）：有 Chrome 图标就右键 → 退出
3. 打开**任务管理器**（`Ctrl+Shift+Esc`），在「进程」里搜 `chrome`，
   还有残留就选中 → 结束任务

命令行一步到位：

```powershell
taskkill /IM chrome.exe /F
```

想根治，把这个后台常驻关掉：Chrome → 设置 → 系统 →
**关闭「Google Chrome 关闭时继续运行后台应用」**。关掉之后，关窗口就是真退出。

**macOS：** `Cmd+Q` 退出，不是点窗口左上角的红叉。菜单栏还有 Chrome 图标就是没退。

**Linux：** 同样确认没有残留进程，`pkill chrome` 即可。

### 前提三：换个浏览器往往更省事

**Firefox 通常不需要退出**就能读到 cookies，是最省心的选择。
Windows 上 Edge 和 Chrome 的行为一样，也要彻底退出。

### 还是不行

- 隔几分钟或换个网络再试，机器人校验有时是临时的
- 升级 yt-dlp：`Install-and-Run.bat` 会重下最新版；macOS/Linux 用 `brew upgrade yt-dlp` 或 `pipx upgrade yt-dlp`
- 确认系统时间正确，时间偏差会让 cookies 失效

### 安全提醒

cookies 等同于你的登录凭证。这个工具只是把它交给 yt-dlp 用于本次下载，不会保存、
不会上传。但请不要把 `--cookies-from-browser` 用在别人的机器上，也不要把导出的
cookies 文件发给任何人——拿到它就等于拿到你的 YouTube 账号。

## 项目结构

```
standalone/
  youtube_downloader.py      唯一的实现：GUI + CLI，所有 yt-dlp 参数在此定义
  Run-macOS.command          macOS 双击启动
  Run-Windows.bat            Windows 双击启动（需 Python）
  run-linux.sh               Linux 启动
  unix/youtube-downloader.sh 旧的位置参数接口，转发给上面的 Python
  windows/                   PowerShell 图形版，供没有 Python 的 Windows 使用
plugins/                     可选的 Codex 插件，同样转发给 standalone/
tests/                       单元测试 + 两份实现的等价性验证
```

只有两处会构造 yt-dlp 命令：`youtube_downloader.py` 的 `build_command()` /
`probe_command()`，和 PowerShell 版的 `Build-YtDlpArgumentList` /
`Build-ProbeArgumentList`。后者存在的唯一理由是让没装 Python 的 Windows 用户也能
双击运行。`tests/compare_implementations.sh` 在 CI 中逐场景比对两者生成的参数
（下载和检测都比），任何不一致都会让构建失败。

判断哪些选项可用的逻辑同样是两份：`available_options()` 和 `Get-AvailableOption`。
两边用同一组 JSON 样本断言同样的结果——Python 在 `tests/test_downloader.py`，
PowerShell 在 `YouTube-Downloader.ps1 -SmokeTest` 里，两个窗口因此置灰同样的东西。

## 测试

```bash
python3 -m unittest discover -s tests -v     # 61 个测试（含 GUI 冒烟测试）
./tests/compare_implementations.sh pwsh      # 两份实现的等价性（需要 pwsh）
```

## 可选：作为 Codex 插件使用

```bash
codex plugin marketplace add "$PWD"
codex plugin add youtube-dl@youtube-dl-marketplace
codex plugin list        # 应显示 installed, enabled
```

装好后新建一个 Codex 任务让技能加载，然后直接说：

```text
下载这个视频：https://youtu.be/VIDEO_ID
把这个下载成 MP3：https://youtu.be/VIDEO_ID
下 720p 就行：https://youtu.be/VIDEO_ID
```

不想要插件的话，删掉 `plugins/` 和 `.agents/` 即可，`standalone/` 不受影响。

## 许可

MIT，见 [LICENSE](LICENSE)。请只下载你有权获取的内容。
