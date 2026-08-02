# YouTube DL for Codex

一个基于 [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) 的 Codex 插件。向 Codex 发送 YouTube 链接，即可下载视频、提取 MP3、获取字幕或下载播放列表。

## 功能

- 最佳兼容画质视频，优先合并为 MP4
- 最佳音质转 MP3
- 中文及英文人工字幕和自动字幕，转换为 SRT
- YouTube Shorts 和播放列表
- 可选读取本机 Chrome 登录状态
- 默认不覆盖已有文件

## 系统要求

必须具备：

- Codex 桌面版或支持本地插件的 Codex CLI
- `yt-dlp`
- `ffmpeg`：合并视频音频、转 MP3、转换字幕时需要
- Bash：macOS/Linux 自带；Windows 推荐 Git Bash 或 WSL
- 网络可以访问 YouTube

建议使用当前稳定版本的 `yt-dlp` 和 `ffmpeg`。YouTube 经常调整接口；下载突然失败时，首先升级 `yt-dlp`。

## 安装依赖

### macOS

```bash
brew install yt-dlp ffmpeg
yt-dlp --version
ffmpeg -version
```

### Windows

使用 Windows Package Manager：

```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg
```

关闭并重新打开终端，然后验证：

```powershell
yt-dlp --version
ffmpeg -version
```

脚本是 Bash 脚本；请在 Git Bash 或 WSL 中运行。通过 Codex 使用时，也需要系统存在可用的 Bash 环境。

### Ubuntu/Debian Linux

发行版仓库中的 `yt-dlp` 可能较旧，推荐使用 `pipx`：

```bash
sudo apt update
sudo apt install -y ffmpeg pipx
pipx install yt-dlp
pipx ensurepath
```

重新打开终端后验证：

```bash
yt-dlp --version
ffmpeg -version
```

也可以按照 yt-dlp 官方文档选择其他安装方式。

## 安装 Codex 插件

克隆仓库：

```bash
git clone https://github.com/tszxy/youtube-dl-codex-plugin.git
cd youtube-dl-codex-plugin
```

添加 Marketplace 并安装插件：

```bash
codex plugin marketplace add "$PWD"
codex plugin add youtube-dl@youtube-dl-marketplace
```

验证：

```bash
codex plugin list
```

应看到 `youtube-dl@youtube-dl-marketplace` 为 `installed, enabled`。安装或升级后，请新建一个 Codex 任务，使技能被重新加载。

如果命令提示 Marketplace 已存在，可以先查看现有配置，不必重复添加；直接运行插件安装命令即可。

## 在 Codex 中使用

直接发送自然语言：

```text
下载这个视频：https://www.youtube.com/watch?v=VIDEO_ID
把这个视频下载成 MP3：https://youtu.be/VIDEO_ID
下载这个视频的中英文字幕：https://youtu.be/VIDEO_ID
下载整个播放列表：https://www.youtube.com/playlist?list=PLAYLIST_ID
我已在 Chrome 登录，请使用登录状态下载：https://youtu.be/VIDEO_ID
```

也可以显式调用技能：

```text
使用 $download-youtube 下载这个链接，并保存为最高画质 MP4。
```

默认保存到当前 Codex 工作目录。可以在提示词中指定其他目录。

## 直接运行脚本

```bash
SCRIPT="plugins/youtube-dl/skills/download-youtube/scripts/download_youtube.sh"

"$SCRIPT" --url "https://youtu.be/VIDEO_ID" --output-dir ./downloads --mode video
"$SCRIPT" --url "https://youtu.be/VIDEO_ID" --output-dir ./downloads --mode audio
"$SCRIPT" --url "https://youtu.be/VIDEO_ID" --output-dir ./downloads --mode subtitles
```

下载完整播放列表：

```bash
"$SCRIPT" --url "PLAYLIST_URL" --output-dir ./downloads --mode video --playlist
```

默认只下载单个视频，即使 URL 中包含播放列表参数。

## 使用 Chrome 登录状态

仅在年龄限制、会员内容或需要账号验证时使用：

```bash
"$SCRIPT" --url "VIDEO_URL" --output-dir ./downloads --mode video --cookies-from-browser chrome
```

要求：

- 必须在执行下载的同一台机器上登录 Chrome。
- Codex/终端进程必须有权限读取 Chrome 配置目录。
- macOS 可能弹出“钥匙串”访问请求，需要允许。
- Windows/Linux 的 Chrome 用户数据目录必须可被当前用户读取。
- Chrome Cookie 不会上传到本插件或 GitHub；它仅由本机 `yt-dlp` 读取。
- 不要导出、提交或分享 `cookies.txt`。仓库已通过 `.gitignore` 排除该文件。

如果 Chrome 正在锁定 Cookie 数据库，可先完全退出 Chrome，再重试。具体行为取决于系统和 Chrome/yt-dlp 版本。

## 输出规则

文件名格式：

```text
视频标题 [YouTube_ID].扩展名
```

为保证跨平台兼容，文件名会移除不安全字符。插件使用 `--no-overwrites`，同名文件存在时不会覆盖。

模式说明：

| 模式 | 输出 | 主要依赖 |
|---|---|---|
| `video` | MP4 或最佳可用视频容器 | yt-dlp、ffmpeg |
| `audio` | MP3 | yt-dlp、ffmpeg |
| `subtitles` | SRT | yt-dlp、ffmpeg |

## 常见问题

### `yt-dlp is not installed`

按照上面的系统安装步骤安装，并确保 `yt-dlp` 位于 `PATH`：

```bash
command -v yt-dlp
```

### `ffmpeg not found`

安装 `ffmpeg`，重新打开终端，并验证 `ffmpeg -version`。

### `Sign in to confirm you’re not a bot`

先在 Chrome 登录 YouTube，再使用 `--cookies-from-browser chrome`。仍失败时升级 `yt-dlp`。

### `Requested format is not available`

升级 `yt-dlp` 后重试。某些视频不提供 MP4 音视频组合，脚本会回退到最佳可用格式并由 ffmpeg 合并。

### 下载速度慢或失败

检查网络、代理、防火墙和 YouTube 的地区限制。插件不会绕过 DRM、付费权限或平台访问控制。

### 插件安装后没有触发

确认 `codex plugin list` 显示插件已启用，然后新建一个 Codex 任务。旧任务不会自动重新加载新技能。

## 更新

```bash
cd youtube-dl-codex-plugin
git pull
codex plugin add youtube-dl@youtube-dl-marketplace
```

同时建议更新下载器：

```bash
yt-dlp -U
```

如果通过 Homebrew 安装：

```bash
brew upgrade yt-dlp ffmpeg
```

## 安全与合规

- 仅下载你有权访问和保存的内容。
- 遵守 YouTube 服务条款、版权规则和当地法律。
- 插件不包含账号、密码、Cookie 或遥测服务。
- 不支持绕过 DRM、付费墙或账号权限。

## 许可证

本插件采用 MIT License。`yt-dlp` 和 `ffmpeg` 分别遵循其自身许可证。
