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
2. 第一次双击 `Install-and-Run.bat` —— 自动下载 yt-dlp 和 FFmpeg 到 `tools\`，校验 SHA-256 后打开界面
3. 以后双击 `Run-Downloader.bat`

**B. 已经装了 Python**（跨平台版，功能相同）

```
standalone\Run-Windows.bat
```

如果 Windows 拦下 `.bat`：右键 → 属性 → 勾选"解除锁定"。

### Linux

```bash
sudo apt install ffmpeg python3-tk   # tkinter 用于图形界面
pipx install yt-dlp                  # 发行版自带的 yt-dlp 往往过旧
cd standalone
./run-linux.sh                       # 图形界面
./run-linux.sh "https://youtu.be/VIDEO_ID" -o ~/Downloads   # 命令行
```

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

### 遇到 "Sign in to confirm you're not a bot"

YouTube 对部分 IP 会要求验证。下载因此失败时，工具会在日志末尾直接把解决办法打出来。
加上浏览器登录状态即可：

```bash
python3 standalone/youtube_downloader.py "URL" --cookies-from-browser chrome
```

读取 cookie 前请**完全退出浏览器**（macOS 上是 Cmd+Q，不是关窗口），否则数据库被锁。

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

只有两处会构造 yt-dlp 命令：`youtube_downloader.py` 的 `build_command()` 和
PowerShell 版的 `Build-YtDlpArgumentList`。后者存在的唯一理由是让没装 Python 的
Windows 用户也能双击运行。`tests/compare_implementations.sh` 在 CI 中逐场景比对
两者生成的参数，任何不一致都会让构建失败。

## 测试

```bash
python3 -m unittest discover -s tests -v     # 37 个测试（含 GUI 冒烟测试）
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
