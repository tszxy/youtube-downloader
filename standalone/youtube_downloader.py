#!/usr/bin/env python3
"""Standalone YouTube downloader built on yt-dlp.

Run with no arguments for the graphical interface, or with arguments for the
command line. Nothing here depends on Codex or on any third-party Python
package: only the standard library plus the yt-dlp executable.

    python3 youtube_downloader.py                       # GUI
    python3 youtube_downloader.py URL                   # download video
    python3 youtube_downloader.py URL --mode audio      # extract MP3
    python3 youtube_downloader.py --install             # fetch yt-dlp locally
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile
from pathlib import Path

APP_TITLE = "YouTube 独立下载器"
HERE = Path(__file__).resolve().parent
TOOLS_DIR = HERE / "tools"

MODES = ("video", "audio", "subtitles")
QUALITIES = ("best", "1080", "720", "480")
BROWSERS = ("chrome", "edge", "firefox", "brave", "safari", "chromium", "opera", "vivaldi")
# Exact tags, not wildcards: see the --sub-langs comment in build_command.
SUB_LANGS = ("zh-Hans", "zh-Hant", "zh", "en")

YOUTUBE_URL = re.compile(r"^https?://([\w-]+\.)*(youtube\.com|youtu\.be)/", re.IGNORECASE)
PROGRESS = re.compile(r"\[download\]\s+(\d+(?:\.\d+)?)%")
# "Sign in to confirm you're not a bot" and "... confirm your age" are both
# fixed by the same thing: borrowing a logged-in browser's cookies.
BOT_CHECK = re.compile(r"sign in to confirm", re.IGNORECASE)

YT_DLP_RELEASE = "https://github.com/yt-dlp/yt-dlp/releases/latest/download"
FFMPEG_WINDOWS_ZIP = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"


# --------------------------------------------------------------------------
# Command construction -- the single source of truth for every yt-dlp flag.
# The GUI and the CLI both go through build_command, so they cannot drift.
# --------------------------------------------------------------------------

def video_format(quality: str) -> str:
    """Format selector preferring a widely playable MP4, optionally height-capped.

    H.264 (avc1) comes first on purpose: YouTube increasingly serves AV1, which
    is smaller but will not play on older phones, TVs and desktop players. Each
    fallback loosens one constraint, so a download never fails for lack of an
    exact match.
    """
    if quality == "best":
        return (
            "bv*[ext=mp4][vcodec^=avc1]+ba[ext=m4a]/"
            "bv*[ext=mp4]+ba[ext=m4a]/"
            "b[ext=mp4]/"
            "bv*+ba/b"
        )
    return (
        "bv*[height<={h}][ext=mp4][vcodec^=avc1]+ba[ext=m4a]/"
        "bv*[height<={h}][ext=mp4]+ba[ext=m4a]/"
        "b[height<={h}][ext=mp4]/"
        "bv*[height<={h}]+ba/b"
    ).format(h=quality)


def build_command(
    runner,
    url,
    mode="video",
    quality="best",
    output_dir=".",
    playlist=False,
    cookies_browser="",
    ffmpeg_dir=None,
):
    """Return the full argv for one yt-dlp invocation.

    Validation lives here rather than in the callers so that no code path can
    build a command for an unsupported URL, mode, or quality.
    """
    if not YOUTUBE_URL.match(url):
        raise ValueError("只支持 YouTube 链接：{}".format(url))
    if mode not in MODES:
        raise ValueError("unsupported mode: {} (use {})".format(mode, ", ".join(MODES)))
    if quality not in QUALITIES:
        raise ValueError("unsupported quality: {} (use {})".format(quality, ", ".join(QUALITIES)))

    template = str(Path(output_dir) / "%(title)s [%(id)s].%(ext)s")
    cmd = list(runner) + [
        "--no-overwrites",
        "--newline",
        # Keeps Chinese titles intact while staying safe on every filesystem;
        # --restrict-filenames would flatten them to ASCII.
        "--windows-filenames",
        "--trim-filenames", "200",
        # YouTube serves DASH fragments; parallel fetches are several times
        # faster than the default serial download.
        "--concurrent-fragments", "4",
        "--output", template,
    ]
    if not playlist:
        cmd.append("--no-playlist")
    if cookies_browser:
        cmd += ["--cookies-from-browser", cookies_browser]
    if ffmpeg_dir:
        cmd += ["--ffmpeg-location", str(ffmpeg_dir)]

    if mode == "video":
        cmd += ["--format", video_format(quality), "--merge-output-format", "mp4"]
    elif mode == "audio":
        cmd += ["--format", "ba/b", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0"]
    else:
        cmd += [
            "--skip-download", "--write-subs", "--write-auto-subs",
            # Exact tags, not wildcards: "zh.*,en.*" matches ~20 tracks on a
            # popular video, and each one is a separate request that reliably
            # trips YouTube's rate limiting.
            "--sub-langs", ",".join(SUB_LANGS),
            "--convert-subs", "srt",
        ]

    cmd.append(url)
    return cmd


# --------------------------------------------------------------------------
# Asking a video what it can actually deliver
#
# Every choice in the window is offered by YouTube, not by us: a video may have
# no track above 720p, no subtitles in any language we request, or no audio at
# all. Probing once up front is what lets the interface grey out the choices
# that would silently produce nothing.
# --------------------------------------------------------------------------

def probe_command(runner, url, cookies_browser=""):
    """Return the argv that asks yt-dlp to describe a video without downloading."""
    if not YOUTUBE_URL.match(url):
        raise ValueError("只支持 YouTube 链接：{}".format(url))
    cmd = list(runner) + [
        "--dump-single-json",
        "--no-warnings",
        "--skip-download",
        "--no-playlist",
    ]
    if cookies_browser:
        cmd += ["--cookies-from-browser", cookies_browser]
    cmd.append(url)
    return cmd


def probe_error(stderr, returncode=1):
    """The one line from a failed probe that is worth showing the user."""
    lines = [line.strip() for line in (stderr or "").splitlines() if line.strip()]
    for line in lines:
        if BOT_CHECK.search(line):
            return "YouTube 要求验证你不是机器人，先在「登录状态来源」里选一个浏览器"
        if line.startswith("ERROR:"):
            return line
    if lines:
        return lines[-1]
    return "yt-dlp 退出代码 {}".format(returncode)


def probe(url, cookies_browser="", timeout=90):
    """Return yt-dlp's JSON description of one video. Raises on any failure."""
    runner = find_runner()
    if runner is None:
        raise RuntimeError("找不到 yt-dlp，无法检测可用选项")
    kwargs = {}
    if os.name == "nt":
        # Without this a console window flashes on every keystroke-triggered probe.
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    result = subprocess.run(
        probe_command(runner, url, cookies_browser),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        **kwargs
    )
    if result.returncode != 0 or not (result.stdout or "").strip():
        raise RuntimeError(probe_error(result.stderr, result.returncode))
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise RuntimeError("yt-dlp 返回的不是 JSON")


def available_options(info):
    """Which of this program's choices the probed video can actually deliver.

    Unknown counts as available. A probe that tells us nothing about a video --
    an empty format list, a field yt-dlp stopped emitting -- must never be the
    reason a download the user could have had is refused.
    """
    formats = info.get("formats") or []
    # Positive only, matching Get-AvailableOption: a zero height is not a video
    # track, and counting it would offer 视频 for something that has none.
    heights = sorted({
        int(fmt["height"]) for fmt in formats
        if isinstance(fmt.get("height"), (int, float)) and fmt["height"] > 0
    })
    has_video = bool(heights) if formats else True
    has_audio = any(
        (fmt.get("acodec") or "none") != "none" for fmt in formats
    ) if formats else True

    qualities = {"best": has_video}
    for quality in QUALITIES[1:]:
        cap = int(quality)
        # A cap is offered when the video reaches it (otherwise 1080p on a
        # 720p-only video would promise something YouTube cannot give) and has
        # a track at or below it (so the cap can be met at all). Unknown
        # heights leave every cap enabled.
        qualities[quality] = (
            has_video and not heights
        ) or (
            any(height >= cap for height in heights)
            and any(height <= cap for height in heights)
        )

    tracks = set(info.get("subtitles") or ()) | set(info.get("automatic_captions") or ())
    return {
        "title": info.get("title") or "",
        "heights": heights,
        # The keys are the mode and quality names build_command already accepts.
        "modes": {
            "video": has_video,
            "audio": has_audio,
            "subtitles": any(lang in tracks for lang in SUB_LANGS),
        },
        "qualities": qualities,
    }


def options_summary(available):
    """One line describing what the probe found, for the status area."""
    heights = available["heights"]
    parts = ["最高 {}p".format(max(heights)) if heights else "画质未知"]
    parts.append("有音频" if available["modes"]["audio"] else "无音频")
    parts.append("有中/英字幕" if available["modes"]["subtitles"] else "无中/英字幕")
    title = available["title"]
    if title:
        parts.append(title if len(title) <= 40 else title[:39] + "…")
    return " · ".join(parts)


def browser_profile_paths(name):
    """Where the given browser keeps the profile yt-dlp would read cookies from.

    Only used to grey out browsers that are not installed; picking one that is
    missing fails inside yt-dlp with a message most people cannot act on.
    """
    home = Path.home()
    if sys.platform == "darwin":
        support = home / "Library" / "Application Support"
        table = {
            "chrome": [support / "Google/Chrome"],
            "edge": [support / "Microsoft Edge"],
            "firefox": [support / "Firefox"],
            "brave": [support / "BraveSoftware/Brave-Browser"],
            "safari": [home / "Library/Safari", home / "Library/Containers/com.apple.Safari"],
            "chromium": [support / "Chromium"],
            "opera": [support / "com.operasoftware.Opera"],
            "vivaldi": [support / "Vivaldi"],
        }
    elif os.name == "nt":
        local = Path(os.environ.get("LOCALAPPDATA") or home / "AppData/Local")
        roaming = Path(os.environ.get("APPDATA") or home / "AppData/Roaming")
        table = {
            "chrome": [local / "Google/Chrome/User Data"],
            "edge": [local / "Microsoft/Edge/User Data"],
            "firefox": [roaming / "Mozilla/Firefox"],
            "brave": [local / "BraveSoftware/Brave-Browser/User Data"],
            "safari": [],  # Discontinued on Windows in 2012.
            "chromium": [local / "Chromium/User Data"],
            "opera": [roaming / "Opera Software/Opera Stable"],
            "vivaldi": [local / "Vivaldi/User Data"],
        }
    else:
        config = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
        table = {
            "chrome": [config / "google-chrome"],
            "edge": [config / "microsoft-edge"],
            "firefox": [home / ".mozilla/firefox",
                        home / "snap/firefox/common/.mozilla/firefox",
                        config / "firefox"],
            "brave": [config / "BraveSoftware/Brave-Browser"],
            "safari": [],
            "chromium": [config / "chromium", home / "snap/chromium/common/chromium"],
            "opera": [config / "opera"],
            "vivaldi": [config / "vivaldi"],
        }
    return table.get(name, [])


def browser_available(name):
    if not name:
        return True  # "不使用" is always a valid choice.
    return any(path.is_dir() for path in browser_profile_paths(name))


# --------------------------------------------------------------------------
# Chrome keeps its cookie database locked while it runs
# --------------------------------------------------------------------------

# yt-dlp fails with "Could not copy Chrome cookie database" (yt-dlp #7271) for
# as long as Chrome is alive, and closing every window ends no Chrome process
# on any of the three platforms -- hence a process check, not a window check.
CHROME_QUIT_GRACE = 8.0

CHROME_QUIT_QUESTION = (
    "检测到 Chrome 正在运行。\n\n"
    "Chrome 运行时会独占 cookies 数据库，读取登录状态会失败"
    "（yt-dlp 已知问题 #7271）；关掉所有窗口并不等于退出。\n\n"
    "现在退出 Chrome 吗？未保存的网页内容会丢失，下载结束后可以重新打开。"
)

CHROME_STILL_RUNNING = (
    "Chrome 仍在运行。如果之后提示读取 cookies 失败，请先彻底退出 Chrome 再重试。"
)


def chrome_process_names():
    if sys.platform == "darwin":
        return ["Google Chrome"]
    if os.name == "nt":
        return ["chrome.exe"]
    return ["chrome", "google-chrome", "google-chrome-stable"]


def _run_quiet(cmd, timeout=15):
    """Run a small helper command. None when it could not be run at all."""
    kwargs = {}
    if os.name == "nt":
        # Same reason as probe(): no console window may flash into view.
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    try:
        return subprocess.run(
            cmd, capture_output=True, universal_newlines=True,
            encoding="utf-8", errors="replace", timeout=timeout, **kwargs
        )
    except (OSError, subprocess.SubprocessError):
        return None


def chrome_running():
    """True only when a Chrome process is definitely alive.

    "Cannot tell" answers False on purpose: offering to kill a browser that is
    not running is worse than the failure the offer prevents, and yt-dlp names
    that failure clearly enough on its own.
    """
    if os.name == "nt":
        result = _run_quiet(["tasklist", "/FI", "IMAGENAME eq chrome.exe", "/NH"])
        if result is None:
            return False
        return "chrome.exe" in (result.stdout or "").lower()
    for name in chrome_process_names():
        result = _run_quiet(["pgrep", "-x", name])
        if result is not None and result.returncode == 0:
            return True
    return False


def quit_chrome(grace=CHROME_QUIT_GRACE):
    """Close Chrome, politely first. True when nothing is left running.

    The polite request goes first on every platform: a forced kill loses
    unsaved tab content and makes Chrome offer to restore the session on its
    next launch. Only a Chrome that ignores it for `grace` seconds -- usually
    one holding a "leave site?" dialog -- is killed outright, which is what
    the user agreed to when they answered yes.
    """
    if sys.platform == "darwin":
        _run_quiet(["osascript", "-e", 'quit app "Google Chrome"'], timeout=grace)
    elif os.name == "nt":
        _run_quiet(["taskkill", "/IM", "chrome.exe"], timeout=grace)
    else:
        for name in chrome_process_names():
            _run_quiet(["pkill", "-x", name], timeout=grace)

    deadline = time.monotonic() + grace
    while True:
        if not chrome_running():
            return True
        if time.monotonic() >= deadline:
            break
        time.sleep(0.3)

    if os.name == "nt":
        _run_quiet(["taskkill", "/IM", "chrome.exe", "/T", "/F"])
    else:
        for name in chrome_process_names():
            _run_quiet(["pkill", "-9", "-x", name])
    time.sleep(1.0)
    return not chrome_running()


# --------------------------------------------------------------------------
# Locating the tools
# --------------------------------------------------------------------------

def _portable_yt_dlp():
    names = ["yt-dlp.exe"] if os.name == "nt" else ["yt-dlp_macos", "yt-dlp_linux", "yt-dlp"]
    for name in names:
        candidate = TOOLS_DIR / name
        if candidate.is_file():
            return candidate
    return None


def find_runner():
    """Return the argv prefix that runs yt-dlp, or None if it is unavailable."""
    portable = _portable_yt_dlp()
    if portable:
        return [str(portable)]
    found = shutil.which("yt-dlp")
    if found:
        return [found]
    try:
        subprocess.run(
            [sys.executable, "-c", "import yt_dlp"],
            check=True, capture_output=True,
        )
        return [sys.executable, "-m", "yt_dlp"]
    except (subprocess.CalledProcessError, OSError):
        return None


def find_ffmpeg_dir():
    """Directory containing a portable ffmpeg, or None to rely on PATH."""
    if TOOLS_DIR.is_dir():
        pattern = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"
        for candidate in sorted(TOOLS_DIR.rglob(pattern)):
            if candidate.is_file():
                return candidate.parent
    return None


def ffmpeg_available():
    return find_ffmpeg_dir() is not None or shutil.which("ffmpeg") is not None


def ffmpeg_hint():
    if sys.platform == "darwin":
        return "缺少 ffmpeg：brew install ffmpeg"
    if os.name == "nt":
        return "缺少 ffmpeg：运行 --install 自动下载"
    return "缺少 ffmpeg：sudo apt install ffmpeg"


# --------------------------------------------------------------------------
# Dependency bootstrap
# --------------------------------------------------------------------------

def _download(url, target, log):
    log("下载 {} ...".format(url))
    with urllib.request.urlopen(url, timeout=120) as response, open(target, "wb") as handle:
        shutil.copyfileobj(response, handle)


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _yt_dlp_asset():
    if os.name == "nt":
        return "yt-dlp.exe"
    if sys.platform == "darwin":
        return "yt-dlp_macos"
    return "yt-dlp_linux"


def install_dependencies(log=print):
    """Download a portable yt-dlp (and ffmpeg on Windows) into tools/."""
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    asset = _yt_dlp_asset()
    target = TOOLS_DIR / asset

    _download("{}/{}".format(YT_DLP_RELEASE, asset), target, log)

    try:
        with urllib.request.urlopen(YT_DLP_RELEASE + "/SHA2-256SUMS", timeout=60) as response:
            sums = response.read().decode("utf-8", "replace")
        expected = None
        for line in sums.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1] == asset:
                expected = parts[0].lower()
                break
        if expected is None:
            log("警告：校验和列表中没有 {}，跳过校验".format(asset))
        else:
            actual = _sha256(target)
            if actual != expected:
                target.unlink(missing_ok=True)
                raise RuntimeError("{} 校验和不匹配，已删除下载文件".format(asset))
            log("校验和通过")
    except OSError as exc:
        log("警告：无法获取校验和（{}），跳过校验".format(exc))

    target.chmod(0o755)
    log("yt-dlp 已安装到 {}".format(target))

    if os.name == "nt":
        _install_ffmpeg_windows(log)
    elif not ffmpeg_available():
        log(ffmpeg_hint())

    return target


def _install_ffmpeg_windows(log):
    if find_ffmpeg_dir():
        log("ffmpeg 已存在，跳过下载")
        return
    archive = TOOLS_DIR / "ffmpeg.zip"
    _download(FFMPEG_WINDOWS_ZIP, archive, log)
    extract_to = TOOLS_DIR / "ffmpeg"
    if extract_to.exists():
        shutil.rmtree(extract_to)
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(extract_to)
    archive.unlink()

    # The essentials build ships ffplay (~100 MB) and an HTML manual we never use.
    for junk in list(extract_to.rglob("ffplay.exe")):
        junk.unlink(missing_ok=True)
    for doc in list(extract_to.rglob("doc")):
        if doc.is_dir():
            shutil.rmtree(doc, ignore_errors=True)

    found = find_ffmpeg_dir()
    if not found:
        raise RuntimeError("ffmpeg 下载完成但没有找到 ffmpeg.exe")
    log("ffmpeg 已安装到 {}".format(found))


# --------------------------------------------------------------------------
# Running a download
# --------------------------------------------------------------------------

class Download:
    """One yt-dlp run whose whole process group can be cancelled.

    yt-dlp spawns ffmpeg as a child; killing only yt-dlp would leave it behind,
    so the process gets its own group (POSIX) or is killed with taskkill /T.
    """

    def __init__(self, cmd):
        self.cmd = cmd
        self.process = None

    def start(self):
        kwargs = {}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
        else:
            kwargs["start_new_session"] = True
        self.process = subprocess.Popen(
            self.cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True,
            bufsize=1,
            encoding="utf-8",
            errors="replace",
            **kwargs
        )
        return self.process

    def lines(self):
        assert self.process is not None and self.process.stdout is not None
        for line in self.process.stdout:
            yield line.rstrip("\n")

    def close(self):
        """Release the stdout pipe; safe to call more than once."""
        if self.process is not None and self.process.stdout is not None:
            try:
                self.process.stdout.close()
            except OSError:
                pass

    def cancel(self):
        process = self.process
        if process is None or process.poll() is not None:
            self.close()
            return
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    capture_output=True,
                )
            else:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except (OSError, subprocess.SubprocessError):
            process.kill()
        finally:
            self.close()


def bot_check_hint(cookies_browser=""):
    """What to do about YouTube's "prove you are not a bot" refusal.

    yt-dlp's own message names the flags but not which browser to pick, and it
    scrolls past in the log, so the advice is repeated at the end of the run.
    """
    if cookies_browser:
        return (
            "YouTube 仍然要求验证：请确认 {} 已登录 YouTube（并且已完全退出该浏览器，"
            "否则读不到 cookies），或换一个浏览器、稍后再试。".format(cookies_browser)
        )
    return (
        "YouTube 要求验证你不是机器人。用已登录的浏览器身份重试："
        "命令行加 --cookies-from-browser chrome（edge / firefox / safari 等同理），"
        "图形界面在「登录状态来源」里选一个。"
    )


def run_download(url, on_line=print, on_job=None, **options):
    """Blocking download. Returns the yt-dlp exit code.

    on_job receives the Download as soon as it starts, so a caller with a
    cancel button can reach the running process.
    """
    runner = find_runner()
    if runner is None:
        raise RuntimeError(
            "找不到 yt-dlp。运行 `{} {} --install` 自动安装，"
            "或用 brew/pipx 自行安装。".format(Path(sys.executable).name, Path(__file__).name)
        )

    output_dir = Path(options.get("output_dir", "."))
    options["output_dir"] = output_dir
    options.setdefault("ffmpeg_dir", find_ffmpeg_dir())
    # Built before any side effects so a bad URL cannot create a directory.
    cmd = build_command(runner, url, **options)

    output_dir.mkdir(parents=True, exist_ok=True)
    if not ffmpeg_available():
        on_line("警告：{}（合并 MP4、转 MP3、转字幕会失败）".format(ffmpeg_hint()))

    job = Download(cmd)
    job.start()
    if on_job is not None:
        on_job(job)
    blocked = False
    try:
        for line in job.lines():
            if BOT_CHECK.search(line):
                blocked = True
            on_line(line)
    except KeyboardInterrupt:
        job.cancel()
        on_line("已取消。")
        return 130
    finally:
        job.close()

    code = job.process.wait()
    # Only after a failure: yt-dlp mentions the bot check in warnings it then
    # recovers from, and advice on a finished download is just noise.
    if code != 0 and blocked:
        on_line(bot_check_hint(options.get("cookies_browser", "")))
    return code


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog=Path(__file__).name,
        description="独立的 YouTube 下载器（不带参数运行则打开图形界面）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  %(prog)s https://youtu.be/ID\n"
            "  %(prog)s https://youtu.be/ID --mode audio -o ~/Downloads\n"
            "  %(prog)s https://youtu.be/ID --quality 1080\n"
            "  %(prog)s PLAYLIST_URL --playlist\n"
            "  %(prog)s https://youtu.be/ID --cookies-from-browser chrome\n"
        ),
    )
    parser.add_argument("url", nargs="?", help="YouTube 链接")
    parser.add_argument("--url", dest="url_flag", metavar="URL",
                        help="YouTube 链接（与位置参数等价）")
    parser.add_argument("-m", "--mode", choices=MODES, default="video", help="下载类型（默认 video）")
    parser.add_argument("-q", "--quality", choices=QUALITIES, default="best", help="画质上限（默认 best）")
    parser.add_argument("-o", "--output-dir", default=".", help="保存目录（默认当前目录）")
    parser.add_argument("--playlist", action="store_true", help="下载整个播放列表")
    parser.add_argument("--cookies-from-browser", default="", choices=("",) + BROWSERS,
                        metavar="BROWSER", help="使用浏览器登录状态：" + " / ".join(BROWSERS))
    parser.add_argument("--install", action="store_true", help="下载便携版 yt-dlp 到 tools/ 后退出")
    parser.add_argument("--gui", action="store_true", help="强制打开图形界面")
    parser.add_argument("--print-command", action="store_true",
                        help="只打印将要执行的 yt-dlp 参数（每行一个），不下载")
    parser.add_argument("--print-probe-command", action="store_true",
                        help="只打印检测可用选项用的 yt-dlp 参数，不下载")
    return parser


def offer_chrome_quit_cli(cookies_browser, ask=None, out=print):
    """The GUI's startup question, for a terminal. True when Chrome was closed.

    Narrower than the GUI on purpose. Only a run that actually asked for Chrome
    cookies is interrupted, and only when someone is there to answer: a piped
    or cron-driven run must not block forever on input() over a browser it may
    not even be using.
    """
    if cookies_browser != "chrome" or not chrome_running():
        return False
    if ask is None:
        if not (sys.stdin and sys.stdin.isatty()):
            out(CHROME_STILL_RUNNING)
            return False
        ask = input
    out(CHROME_QUIT_QUESTION)
    try:
        answer = ask("现在退出 Chrome？[y/N] ")
    except (EOFError, KeyboardInterrupt):
        out("")
        out(CHROME_STILL_RUNNING)
        return False
    if (answer or "").strip().lower() not in ("y", "yes", "是"):
        out(CHROME_STILL_RUNNING)
        return False
    out("正在退出 Chrome...")
    if quit_chrome():
        out("Chrome 已退出。")
        return True
    out("Chrome 没能退出，请手动退出后重试。")
    return False


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.url and args.url_flag and args.url != args.url_flag:
        parser.error("位置参数和 --url 给了两个不同的链接")
    args.url = args.url_flag or args.url

    if args.install:
        try:
            install_dependencies()
        except Exception as exc:  # noqa: BLE001 - surfaced to the user verbatim
            print("安装失败：{}".format(exc), file=sys.stderr)
            return 1
        return 0

    if args.gui or args.url is None:
        return run_gui()

    options = dict(
        mode=args.mode,
        quality=args.quality,
        output_dir=args.output_dir,
        playlist=args.playlist,
        cookies_browser=args.cookies_from_browser,
    )

    try:
        if args.print_probe_command:
            runner = find_runner() or ["yt-dlp"]
            print("\n".join(probe_command(runner, args.url, args.cookies_from_browser)))
            return 0
        if args.print_command:
            runner = find_runner() or ["yt-dlp"]
            options["ffmpeg_dir"] = find_ffmpeg_dir()
            # One argument per line: unambiguous even when a value contains
            # spaces, and directly comparable with the PowerShell version.
            print("\n".join(build_command(runner, args.url, **options)))
            return 0
        offer_chrome_quit_cli(args.cookies_from_browser)
        return run_download(args.url, on_line=print, **options)
    except (ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


# --------------------------------------------------------------------------
# Graphical interface
# --------------------------------------------------------------------------

def run_gui():
    try:
        import tkinter as tk
        from tkinter import filedialog, messagebox, ttk
    except ImportError:
        print(
            "这个 Python 没有 tkinter，无法打开图形界面。\n"
            "改用命令行，例如：\n"
            "  {} {} https://youtu.be/ID -o ~/Downloads".format(
                Path(sys.executable).name, Path(__file__).name),
            file=sys.stderr,
        )
        return 1

    import queue

    MODE_LABELS = [("video", "视频（MP4）"), ("audio", "音频（MP3）"), ("subtitles", "字幕（SRT）")]
    QUALITY_LABELS = [("best", "最佳画质"), ("1080", "最高 1080p"),
                      ("720", "最高 720p"), ("480", "最高 480p")]
    BROWSER_LABELS = [("", "不使用")] + [(name, name.capitalize()) for name in BROWSERS]

    messages = queue.Queue()
    state = {
        "job": None, "busy": False, "timer": None, "cancelled": False,
        # Probe bookkeeping: the debounce timer, what was last probed, and a
        # counter that lets a late reply from a superseded probe be discarded.
        "probe_timer": None, "probed": None, "probe_token": 0,
    }

    root = tk.Tk()
    root.title(APP_TITLE)
    # Wide enough for the four option groups side by side; below the minimum
    # the rightmost one starts to clip.
    root.geometry("900x680")
    root.minsize(820, 600)

    frame = ttk.Frame(root, padding=12)
    frame.pack(fill="both", expand=True)
    frame.columnconfigure(1, weight=1)

    ttk.Label(frame, text="YouTube 链接").grid(row=0, column=0, sticky="w", pady=(0, 4))
    url_var = tk.StringVar()
    url_entry = ttk.Entry(frame, textvariable=url_var)
    url_entry.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(0, 10))

    # Every choice sits on the page instead of inside a dropdown: closed
    # comboboxes hid what was on offer, and there was nowhere to show that a
    # particular video cannot deliver some of it.
    options = ttk.Frame(frame)
    options.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(0, 6))

    mode_group = ttk.Labelframe(options, text="下载类型（可多选）", padding=(10, 6))
    mode_group.grid(row=0, column=0, sticky="nsew")
    mode_vars = {}
    mode_buttons = {}
    for row, (value, label) in enumerate(MODE_LABELS):
        var = tk.BooleanVar(value=(value == "video"))
        button = ttk.Checkbutton(mode_group, text=label, variable=var,
                                 command=lambda: refresh_options())
        button.grid(row=row, column=0, sticky="w")
        mode_vars[value] = var
        mode_buttons[value] = button

    quality_group = ttk.Labelframe(options, text="视频画质（单选）", padding=(10, 6))
    quality_group.grid(row=0, column=1, sticky="nsew", padx=(12, 0))
    quality_var = tk.StringVar(value="best")
    quality_buttons = {}
    for row, (value, label) in enumerate(QUALITY_LABELS):
        button = ttk.Radiobutton(quality_group, text=label, value=value, variable=quality_var)
        button.grid(row=row, column=0, sticky="w")
        quality_buttons[value] = button

    browser_group = ttk.Labelframe(options, text="登录状态来源（单选）", padding=(10, 6))
    browser_group.grid(row=0, column=2, sticky="nsew", padx=(12, 0))
    browser_var = tk.StringVar(value="")
    browser_buttons = {}
    for index, (value, label) in enumerate(BROWSER_LABELS):
        button = ttk.Radiobutton(browser_group, text=label, value=value, variable=browser_var,
                                 command=lambda: schedule_probe())
        button.grid(row=index % 3, column=index // 3, sticky="w", padx=(0, 12))
        browser_buttons[value] = button

    extra_group = ttk.Labelframe(options, text="其他", padding=(10, 6))
    extra_group.grid(row=0, column=3, sticky="nsew", padx=(12, 0))
    playlist_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(extra_group, text="下载整个播放列表", variable=playlist_var).grid(
        row=0, column=0, sticky="w")
    probe_button = ttk.Button(extra_group, text="重新检测", command=lambda: force_probe())
    probe_button.grid(row=1, column=0, sticky="w", pady=(6, 0))

    probe_var = tk.StringVar(value="可用选项：填入链接后自动检测")
    ttk.Label(frame, textvariable=probe_var).grid(
        row=3, column=0, columnspan=3, sticky="w", pady=(0, 8))

    ttk.Label(frame, text="保存目录").grid(row=4, column=0, sticky="w", pady=(0, 4))
    folder_var = tk.StringVar(value=str(Path.home() / "Downloads"))
    ttk.Entry(frame, textvariable=folder_var).grid(row=5, column=0, columnspan=2, sticky="ew")

    def choose_folder():
        chosen = filedialog.askdirectory(initialdir=folder_var.get() or str(Path.home()))
        if chosen:
            folder_var.set(chosen)

    ttk.Button(frame, text="浏览...", command=choose_folder).grid(row=5, column=2, sticky="e", padx=(8, 0))

    buttons = ttk.Frame(frame)
    buttons.grid(row=6, column=0, columnspan=3, sticky="ew", pady=(12, 6))

    status_var = tk.StringVar(value="就绪")
    progress = ttk.Progressbar(frame, mode="determinate", maximum=100)
    progress.grid(row=7, column=0, columnspan=3, sticky="ew")
    ttk.Label(frame, textvariable=status_var).grid(row=8, column=0, columnspan=3, sticky="w", pady=(4, 8))

    log = tk.Text(frame, height=16, wrap="none", background="#1a1a1a",
                  foreground="#dcdcdc", insertbackground="#dcdcdc")
    log.grid(row=9, column=0, columnspan=3, sticky="nsew")
    frame.rowconfigure(9, weight=1)
    scrollbar = ttk.Scrollbar(frame, orient="vertical", command=log.yview)
    scrollbar.grid(row=9, column=3, sticky="ns")
    log.configure(yscrollcommand=scrollbar.set, state="disabled")

    def append(text):
        messages.put(text)

    def label_for(pairs, wanted):
        return dict(pairs).get(wanted, wanted)

    # --- what this video, and this machine, can actually offer ------------
    # Empty means "nothing known yet", and unknown always reads as available:
    # a probe that fails must never be why a possible download is refused.
    availability = {"modes": {}, "qualities": {}}
    browser_ok = {value: browser_available(value) for value, _ in BROWSER_LABELS}

    def enable(widget, on):
        # configure(), not state(): only the option form is readable back with
        # cget("state"), which is how the tests see a greyed-out choice.
        widget.configure(state="normal" if on else "disabled")

    def refresh_options():
        for value, button in mode_buttons.items():
            ok = availability["modes"].get(value, True)
            enable(button, ok)
            if not ok:
                mode_vars[value].set(False)
        # The quality cap only affects the video download, so it greys out with it.
        want_video = mode_vars["video"].get()
        for value, button in quality_buttons.items():
            enable(button, want_video and availability["qualities"].get(value, True))
        if not availability["qualities"].get(quality_var.get(), True):
            quality_var.set("best")
        for value, button in browser_buttons.items():
            enable(button, browser_ok[value])

    def reset_availability(message):
        availability["modes"] = {}
        availability["qualities"] = {}
        probe_var.set(message)
        refresh_options()

    def schedule_probe(*_):
        timer = state.get("probe_timer")
        if timer is not None:
            root.after_cancel(timer)
        # Debounced, so pasting a link costs one probe rather than one per
        # character of the paste.
        state["probe_timer"] = root.after(700, probe_now)

    def probe_now():
        state["probe_timer"] = None
        url = url_var.get().strip()
        if not YOUTUBE_URL.match(url):
            state["probed"] = None
            reset_availability("可用选项：填入链接后自动检测")
            return
        if state["busy"]:
            state["probe_timer"] = root.after(1500, probe_now)
            return
        cookies = browser_var.get()
        if (url, cookies) == state["probed"]:
            return
        state["probed"] = (url, cookies)
        state["probe_token"] += 1
        token = state["probe_token"]
        probe_var.set("正在检测这个视频能提供哪些选项...")

        def work():
            try:
                messages.put(("probe", token, available_options(probe(url, cookies_browser=cookies)), ""))
            except Exception as exc:  # noqa: BLE001 - shown next to the options
                messages.put(("probe", token, None, str(exc)))

        threading.Thread(target=work, daemon=True).start()

    def force_probe():
        timer = state.get("probe_timer")
        if timer is not None:
            root.after_cancel(timer)
            state["probe_timer"] = None
        state["probed"] = None
        probe_now()

    def handle_probe(token, found, error):
        if token != state["probe_token"]:
            return  # A newer probe is already on its way; this reply is stale.
        if found is None:
            reset_availability("检测失败：{}（选项保持全部可选）".format(error))
            return
        availability["modes"] = found["modes"]
        availability["qualities"] = found["qualities"]
        probe_var.set("可用选项：" + options_summary(found))
        refresh_options()

    def set_busy(busy, status):
        state["busy"] = busy
        download_button.configure(state="disabled" if busy else "normal")
        install_button.configure(state="disabled" if busy else "normal")
        probe_button.configure(state="disabled" if busy else "normal")
        cancel_button.configure(state="normal" if busy else "disabled")
        status_var.set(status)

    def worker(target):
        def wrapped():
            try:
                code = target()
            except Exception as exc:  # noqa: BLE001 - reported in the log pane
                append("错误：{}".format(exc))
                code = 1
            messages.put(("done", code))
        threading.Thread(target=wrapped, daemon=True).start()

    def start_download():
        url = url_var.get().strip()
        if not YOUTUBE_URL.match(url):
            messagebox.showwarning("链接无效", "请输入有效的 YouTube 链接。")
            return
        modes = [value for value, _ in MODE_LABELS if mode_vars[value].get()]
        if not modes:
            messagebox.showwarning("缺少下载类型", "请至少勾选一种下载类型。")
            return
        folder = folder_var.get().strip()
        if not folder:
            messagebox.showwarning("缺少目录", "请选择保存目录。")
            return
        if find_runner() is None:
            messagebox.showwarning("缺少依赖", "未找到 yt-dlp，请先点击「安装/更新依赖」。")
            return

        log.configure(state="normal")
        log.delete("1.0", "end")
        log.configure(state="disabled")
        progress["value"] = 0
        state["cancelled"] = False
        set_busy(True, "正在下载...")
        append("开始下载：{}".format(url))

        # Every widget is read here, on the main thread: Tk variables are not
        # thread-safe, and reading them from the worker raises "main thread is
        # not in main loop".
        options = dict(
            quality=quality_var.get(),
            output_dir=folder,
            playlist=playlist_var.get(),
            cookies_browser=browser_var.get(),
        )

        def task():
            # Shares run_download with the CLI so the two cannot drift; on_job
            # hands the running process to the cancel button.
            def on_job(job):
                state["job"] = job

            code = 0
            # Ticked types run one after another: yt-dlp takes a single mode,
            # and downloading the video and its subtitles at once would mean
            # two simultaneous requests for the same video.
            for index, mode in enumerate(modes, 1):
                if state["cancelled"]:
                    return 130
                step = label_for(MODE_LABELS, mode)
                if len(modes) > 1:
                    append("=== {}/{}：{}".format(index, len(modes), step))
                    messages.put(("status", "正在下载（{}/{}）：{}".format(index, len(modes), step)))
                code = run_download(url, on_line=append, on_job=on_job, mode=mode, **options)
                if code != 0:
                    return code
            return code

        worker(task)

    def start_install():
        log.configure(state="normal")
        log.delete("1.0", "end")
        log.configure(state="disabled")
        set_busy(True, "正在安装依赖...")
        append("正在下载 yt-dlp，请稍候...")

        def task():
            install_dependencies(log=append)
            return 0

        worker(task)

    def cancel():
        # Set first: cancelling only the running process would let the worker
        # move straight on to the next ticked download type.
        state["cancelled"] = True
        job = state.get("job")
        if job is not None:
            job.cancel()
            append("已取消。")

    install_button = ttk.Button(buttons, text="安装/更新依赖", command=start_install)
    install_button.pack(side="left")
    download_button = ttk.Button(buttons, text="开始下载", command=start_download)
    download_button.pack(side="left", padx=(10, 0))
    cancel_button = ttk.Button(buttons, text="取消", command=cancel, state="disabled")
    cancel_button.pack(side="left", padx=(10, 0))

    MAX_LINES = 2000

    def drain():
        wrote = False
        for _ in range(400):
            try:
                item = messages.get_nowait()
            except queue.Empty:
                break
            if isinstance(item, tuple) and item:
                if item[0] == "done":
                    code = item[1]
                    state["job"] = None
                    if code == 0:
                        progress["value"] = 100
                        set_busy(False, "完成")
                    else:
                        set_busy(False, "失败，退出代码：{}".format(code))
                elif item[0] == "status":
                    status_var.set(item[1])
                elif item[0] == "probe":
                    handle_probe(*item[1:])
                continue
            match = PROGRESS.search(item)
            if match:
                progress["value"] = min(100.0, float(match.group(1)))
            log.configure(state="normal")
            log.insert("end", item + "\n")
            wrote = True
        if wrote:
            excess = int(log.index("end-1c").split(".")[0]) - MAX_LINES
            if excess > 0:
                log.delete("1.0", "{}.0".format(excess + 1))
            log.see("end")
            log.configure(state="disabled")
        state["timer"] = root.after(120, drain)

    def offer_chrome_quit():
        """Startup question: Chrome cannot be running when cookies are read.

        Asked once, before any URL is typed, because the alternative is
        discovering it minutes later as a yt-dlp error partway through a run.
        """
        if not chrome_running():
            return
        if not messagebox.askyesno("Chrome 正在运行", CHROME_QUIT_QUESTION, parent=root):
            append(CHROME_STILL_RUNNING)
            return
        append("正在退出 Chrome...")

        def task():
            # Off the main thread: quit_chrome waits seconds for Chrome to go,
            # and waiting inline would freeze the window that asked.
            if quit_chrome():
                append("Chrome 已退出，现在可以读取登录状态了。")
            else:
                append("Chrome 没能退出，请手动退出后重试。")

        threading.Thread(target=task, daemon=True).start()

    def on_close():
        # Cancel the pending drain first: letting it fire after the window is
        # gone makes Tcl raise "invalid command name ...drain".
        for key in ("timer", "probe_timer"):
            timer = state.get(key)
            if timer is not None:
                root.after_cancel(timer)
                state[key] = None
        state["cancelled"] = True
        job = state.get("job")
        if job is not None:
            job.cancel()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    refresh_options()
    # Registered last: the callback closes over everything defined above.
    url_var.trace_add("write", schedule_probe)
    url_entry.focus_set()
    state["timer"] = root.after(120, drain)
    # Deferred rather than called here: the window has to be on screen first,
    # or the dialog appears in front of nothing and cannot be placed properly.
    root.after(300, offer_chrome_quit)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
