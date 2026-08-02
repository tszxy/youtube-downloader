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
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import urllib.request
import zipfile
from pathlib import Path

APP_TITLE = "YouTube 独立下载器"
HERE = Path(__file__).resolve().parent
TOOLS_DIR = HERE / "tools"

MODES = ("video", "audio", "subtitles")
QUALITIES = ("best", "1080", "720", "480")
BROWSERS = ("chrome", "edge", "firefox", "brave", "safari", "chromium", "opera", "vivaldi")

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
            "--sub-langs", "zh-Hans,zh-Hant,zh,en",
            "--convert-subs", "srt",
        ]

    cmd.append(url)
    return cmd


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
        "图形界面在“浏览器登录状态”里选一个。"
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
    return parser


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
        if args.print_command:
            runner = find_runner() or ["yt-dlp"]
            options["ffmpeg_dir"] = find_ffmpeg_dir()
            # One argument per line: unambiguous even when a value contains
            # spaces, and directly comparable with the PowerShell version.
            print("\n".join(build_command(runner, args.url, **options)))
            return 0
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

    MODE_LABELS = [("视频（MP4）", "video"), ("音频（MP3）", "audio"), ("字幕（SRT）", "subtitles")]
    QUALITY_LABELS = [("最佳画质", "best"), ("最高 1080p", "1080"), ("最高 720p", "720"), ("最高 480p", "480")]
    BROWSER_LABELS = [("不使用", "")] + [(name.capitalize(), name) for name in BROWSERS]

    messages = queue.Queue()
    state = {"job": None, "busy": False, "timer": None}

    root = tk.Tk()
    root.title(APP_TITLE)
    root.geometry("860x640")
    root.minsize(760, 560)

    frame = ttk.Frame(root, padding=12)
    frame.pack(fill="both", expand=True)
    frame.columnconfigure(1, weight=1)

    ttk.Label(frame, text="YouTube 链接").grid(row=0, column=0, sticky="w", pady=(0, 4))
    url_var = tk.StringVar()
    url_entry = ttk.Entry(frame, textvariable=url_var)
    url_entry.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(0, 10))

    options = ttk.Frame(frame)
    options.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(0, 10))

    def labelled_combo(parent, title, pairs, column):
        ttk.Label(parent, text=title).grid(row=0, column=column, sticky="w", padx=(0 if column == 0 else 14, 0))
        var = tk.StringVar(value=pairs[0][0])
        combo = ttk.Combobox(parent, textvariable=var, state="readonly",
                             values=[label for label, _ in pairs], width=14)
        combo.grid(row=1, column=column, sticky="w", padx=(0 if column == 0 else 14, 0))
        return var

    mode_var = labelled_combo(options, "下载类型", MODE_LABELS, 0)
    quality_var = labelled_combo(options, "视频画质", QUALITY_LABELS, 1)
    browser_var = labelled_combo(options, "登录状态", BROWSER_LABELS, 2)

    playlist_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(options, text="下载整个播放列表", variable=playlist_var).grid(
        row=1, column=3, sticky="w", padx=(18, 0))

    ttk.Label(frame, text="保存目录").grid(row=3, column=0, sticky="w", pady=(0, 4))
    folder_var = tk.StringVar(value=str(Path.home() / "Downloads"))
    ttk.Entry(frame, textvariable=folder_var).grid(row=4, column=0, columnspan=2, sticky="ew")

    def choose_folder():
        chosen = filedialog.askdirectory(initialdir=folder_var.get() or str(Path.home()))
        if chosen:
            folder_var.set(chosen)

    ttk.Button(frame, text="浏览...", command=choose_folder).grid(row=4, column=2, sticky="e", padx=(8, 0))

    buttons = ttk.Frame(frame)
    buttons.grid(row=5, column=0, columnspan=3, sticky="ew", pady=(12, 6))

    status_var = tk.StringVar(value="就绪")
    progress = ttk.Progressbar(frame, mode="determinate", maximum=100)
    progress.grid(row=6, column=0, columnspan=3, sticky="ew")
    ttk.Label(frame, textvariable=status_var).grid(row=7, column=0, columnspan=3, sticky="w", pady=(4, 8))

    log = tk.Text(frame, height=16, wrap="none", background="#1a1a1a",
                  foreground="#dcdcdc", insertbackground="#dcdcdc")
    log.grid(row=8, column=0, columnspan=3, sticky="nsew")
    frame.rowconfigure(8, weight=1)
    scrollbar = ttk.Scrollbar(frame, orient="vertical", command=log.yview)
    scrollbar.grid(row=8, column=3, sticky="ns")
    log.configure(yscrollcommand=scrollbar.set, state="disabled")

    def append(text):
        messages.put(text)

    def selected(var, pairs):
        label = var.get()
        for text, value in pairs:
            if text == label:
                return value
        return pairs[0][1]

    def set_busy(busy, status):
        state["busy"] = busy
        download_button.configure(state="disabled" if busy else "normal")
        install_button.configure(state="disabled" if busy else "normal")
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
        folder = folder_var.get().strip()
        if not folder:
            messagebox.showwarning("缺少目录", "请选择保存目录。")
            return
        if find_runner() is None:
            messagebox.showwarning("缺少依赖", "未找到 yt-dlp，请先点击“安装/更新依赖”。")
            return

        log.configure(state="normal")
        log.delete("1.0", "end")
        log.configure(state="disabled")
        progress["value"] = 0
        set_busy(True, "正在下载...")
        append("开始下载：{}".format(url))

        # Every widget is read here, on the main thread: Tk variables are not
        # thread-safe, and reading them from the worker raises "main thread is
        # not in main loop".
        options = dict(
            mode=selected(mode_var, MODE_LABELS),
            quality=selected(quality_var, QUALITY_LABELS),
            output_dir=folder,
            playlist=playlist_var.get(),
            cookies_browser=selected(browser_var, BROWSER_LABELS),
        )

        def task():
            # Shares run_download with the CLI so the two cannot drift; on_job
            # hands the running process to the cancel button.
            def on_job(job):
                state["job"] = job

            return run_download(url, on_line=append, on_job=on_job, **options)

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
            if isinstance(item, tuple) and item and item[0] == "done":
                code = item[1]
                state["job"] = None
                if code == 0:
                    progress["value"] = 100
                    set_busy(False, "完成")
                else:
                    set_busy(False, "失败，退出代码：{}".format(code))
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

    def on_close():
        # Cancel the pending drain first: letting it fire after the window is
        # gone makes Tcl raise "invalid command name ...drain".
        timer = state.get("timer")
        if timer is not None:
            root.after_cancel(timer)
            state["timer"] = None
        job = state.get("job")
        if job is not None:
            job.cancel()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    url_entry.focus_set()
    state["timer"] = root.after(120, drain)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
