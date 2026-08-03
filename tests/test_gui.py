"""GUI smoke tests.

run_gui() blocks in mainloop, so these replace mainloop with a few manual
update() pumps. That builds every widget for real, runs the log-drain timer,
and lets button handlers be invoked -- without a human clicking anything.

Two things make it work outside a real desktop session:
  * the window is withdrawn before pumping, otherwise update() blocks forever
  * every widget is snapshotted into plain data while the window is still
    alive, because assertions run after it has been destroyed

Skipped automatically when there is no display or no tkinter.
"""

import importlib.util
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "standalone" / "youtube_downloader.py"

try:
    import tkinter
    from tkinter import messagebox
    _probe = tkinter.Tk()
    _probe.withdraw()
    _probe.update()
    _probe.destroy()
    DISPLAY = True
except Exception:  # noqa: BLE001 - any failure means we cannot open a window
    DISPLAY = False


def load_app():
    spec = importlib.util.spec_from_file_location("youtube_downloader_gui", APP)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def snapshot(widget, out):
    """Record what we need from a live widget before the window goes away."""
    entry = {"class": widget.winfo_class()}
    for option in ("text", "state", "values"):
        try:
            value = widget.cget(option)
        except Exception:  # noqa: BLE001 - option not supported by this widget
            continue
        if option == "values":
            entry[option] = list(value)
        else:
            entry[option] = str(value)
    out.append(entry)
    for child in widget.winfo_children():
        snapshot(child, out)
    return out


@unittest.skipUnless(DISPLAY, "no display or tkinter available")
class TestGuiBuilds(unittest.TestCase):
    def setUp(self):
        self.yd = load_app()
        self.widgets = []
        self.warnings = []
        self._mainloop = tkinter.Tk.mainloop
        self._showwarning = messagebox.showwarning
        messagebox.showwarning = lambda *a, **k: self.warnings.append(a)

    def tearDown(self):
        tkinter.Tk.mainloop = self._mainloop
        messagebox.showwarning = self._showwarning

    def pump(self, action=None, cycles=10):
        def fake_mainloop(root):
            try:
                root.withdraw()
                for _ in range(cycles):
                    root.update()
                if action is not None:
                    action(root)
                    for _ in range(cycles):
                        root.update()
                self.widgets = snapshot(root, [])
            finally:
                # Always, even if action blew up: a window left alive with
                # pending callbacks deadlocks the next test's Tk() on macOS,
                # which reads as a hung CI job rather than a failed test.
                for pending in root.tk.splitlist(root.tk.call("after", "info")):
                    try:
                        root.after_cancel(pending)
                    except Exception:  # noqa: BLE001 - already fired
                        pass
                root.destroy()

        tkinter.Tk.mainloop = fake_mainloop
        self.assertEqual(self.yd.run_gui(), 0)

    def texts(self):
        return [w["text"] for w in self.widgets if w.get("text")]

    def states(self):
        return {w["text"]: w["state"] for w in self.widgets if w.get("text") and "state" in w}

    def of_class(self, name):
        return [w for w in self.widgets if w["class"] == name]

    @staticmethod
    def state_of(root, label):
        """A live widget's state, for polling while the window is still up."""
        def visit(widget):
            try:
                if widget.cget("text") == label:
                    return str(widget.cget("state"))
            except Exception:  # noqa: BLE001 - widget has no text or state
                pass
            for child in widget.winfo_children():
                found = visit(child)
                if found:
                    return found
            return None
        return visit(root)

    @staticmethod
    def click(root, label):
        def visit(widget):
            try:
                if widget.cget("text") == label:
                    widget.invoke()
                    return True
            except Exception:  # noqa: BLE001 - not a button
                pass
            return any(visit(child) for child in widget.winfo_children())
        return visit(root)

    def test_window_builds_with_every_control(self):
        self.pump()
        labels = " ".join(self.texts())
        for expected in ["YouTube 链接", "下载类型", "视频画质", "登录状态来源",
                         "保存目录", "开始下载", "取消", "安装/更新依赖",
                         "下载整个播放列表", "浏览...", "重新检测"]:
            with self.subTest(label=expected):
                self.assertIn(expected, labels)

    def test_has_a_progress_bar_and_a_log(self):
        self.pump()
        self.assertEqual(len(self.of_class("TProgressbar")), 1)
        self.assertEqual(len(self.of_class("Text")), 1)

    def test_every_choice_is_on_the_page_rather_than_in_a_dropdown(self):
        self.pump()
        self.assertEqual(self.of_class("TCombobox"), [], "a dropdown is still hiding choices")
        labels = self.texts()
        for expected in ["视频（MP4）", "音频（MP3）", "字幕（SRT）",
                         "最佳画质", "最高 1080p", "最高 720p", "最高 480p",
                         "不使用", "Chrome", "Firefox"]:
            with self.subTest(label=expected):
                self.assertIn(expected, labels)

    def test_download_types_are_ticks_and_the_rest_are_single_choice(self):
        self.pump()
        # Three download types plus 下载整个播放列表.
        self.assertEqual(len(self.of_class("TCheckbutton")), 4)
        # Four quality caps plus 不使用 and every browser yt-dlp accepts.
        self.assertEqual(len(self.of_class("TRadiobutton")), 4 + len(self.yd.BROWSERS) + 1)

    def test_choices_start_enabled_before_anything_is_probed(self):
        self.pump()
        states = self.states()
        for label in ["视频（MP4）", "音频（MP3）", "字幕（SRT）",
                      "最佳画质", "最高 1080p", "最高 720p", "最高 480p"]:
            with self.subTest(label=label):
                self.assertEqual(states[label], "normal")

    def test_probe_greys_out_what_the_video_cannot_deliver(self):
        """The point of the probe: 1080p on a 720p video is not on offer.

        yt-dlp is replaced by its answer, so this stays hermetic; the JSON is
        the same sample the PowerShell smoke test uses.
        """
        self.yd.probe = lambda url, cookies_browser="", **kwargs: {
            "title": "probe sample",
            "formats": [
                {"height": 720, "acodec": "none"},
                {"height": 360, "acodec": "none"},
                {"height": None, "acodec": "mp4a.40.2"},
            ],
            "subtitles": {},
            "automatic_captions": {},
        }

        def action(root):
            def entries_of(widget, out):
                if widget.winfo_class() in ("TEntry", "Entry"):
                    out.append(widget)
                for child in widget.winfo_children():
                    entries_of(child, out)
                return out

            entries_of(root, [])[0].insert(0, "https://youtu.be/ID")
            # The probe is debounced and answered on a worker thread, so spin
            # the event loop until the window has caught up.
            deadline = time.time() + 15
            while time.time() < deadline:
                root.update()
                if self.state_of(root, "最高 1080p") == "disabled":
                    return
                time.sleep(0.05)

        self.pump(action=action)
        states = self.states()
        self.assertEqual(states["最高 1080p"], "disabled", "1080p offered for a 720p video")
        self.assertEqual(states["字幕（SRT）"], "disabled", "subtitles offered for a video without any")
        self.assertEqual(states["最高 720p"], "normal")
        self.assertEqual(states["视频（MP4）"], "normal")
        self.assertIn("最高 720p", " ".join(self.texts()), "the probe result was not reported")

    def test_cancel_starts_disabled(self):
        self.pump()
        cancel = [w for w in self.widgets if w.get("text") == "取消"]
        self.assertTrue(cancel, "cancel button not found")
        self.assertIn("disabled", cancel[0]["state"])

    def test_download_button_rejects_an_empty_url(self):
        self.pump(action=lambda root: self.click(root, "开始下载"))
        self.assertTrue(self.warnings, "empty URL should have raised a warning")
        self.assertIn("链接无效", self.warnings[0][0])

    def test_download_button_rejects_a_non_youtube_url(self):
        def action(root):
            def visit(widget):
                if widget.winfo_class() in ("TEntry", "Entry"):
                    widget.insert(0, "https://vimeo.com/12345")
                    return True
                return any(visit(child) for child in widget.winfo_children())
            visit(root)
            self.click(root, "开始下载")

        self.pump(action=action)
        self.assertTrue(self.warnings)
        self.assertIn("链接无效", self.warnings[0][0])

    def test_download_button_delegates_to_run_download(self):
        """Two properties at once, both regressions that actually happened.

        The GUI used to carry its own copy of run_download's loop, and it read
        the mode/quality/playlist/browser widgets from the worker thread, which
        Tk forbids -- that raises inside the worker, so run_download is never
        reached and the log gets an 错误 line instead.

        No real subprocess here on purpose: driving one through Tk's event loop
        hung for 15 minutes on the macOS CI runner. run_download's own process
        handling is covered by TestBotCheck in test_downloader.py.
        """
        done = threading.Event()
        captured = {}

        def fake_run_download(url, **kwargs):
            captured["url"] = url
            captured["kwargs"] = kwargs
            done.set()
            return 0

        self.yd.run_download = fake_run_download
        self.yd.find_runner = lambda: ["yt-dlp"]
        out_dir = tempfile.mkdtemp()

        def entries_of(widget, out):
            if widget.winfo_class() in ("TEntry", "Entry"):
                out.append(widget)
            for child in widget.winfo_children():
                entries_of(child, out)
            return out

        def action(root):
            entries = entries_of(root, [])
            if len(entries) < 2:
                return
            entries[0].insert(0, "https://youtu.be/ID")
            entries[1].delete(0, "end")
            entries[1].insert(0, out_dir)
            self.click(root, "开始下载")
            # The handler hands off to a worker thread; wait for it rather than
            # spinning the event loop, so a failure fails fast instead of hanging.
            captured["finished"] = done.wait(10)

        self.pump(action=action)

        self.assertTrue(captured.get("finished"), "run_download was never reached")
        self.assertEqual(captured["url"], "https://youtu.be/ID")
        self.assertEqual(captured["kwargs"]["output_dir"], out_dir)
        for key in ("mode", "quality", "playlist", "cookies_browser"):
            self.assertIn(key, captured["kwargs"], "widget value never made it through")
        self.assertEqual(captured["kwargs"]["mode"], "video")
        self.assertEqual(captured["kwargs"]["quality"], "best")

    def run_ticked(self, extra_labels, exit_codes, timeout=10):
        """Tick more download types, press 开始下载, and report the modes run.

        yt-dlp is never started: run_download is replaced by its exit code, and
        the probe by a failure, so nothing here touches the network.
        """
        modes = []
        done = threading.Event()
        codes = list(exit_codes)

        def fake_run_download(url, **kwargs):
            modes.append(kwargs["mode"])
            code = codes.pop(0) if codes else 0
            if not codes:
                done.set()
            return code

        self.yd.run_download = fake_run_download
        self.yd.find_runner = lambda: ["yt-dlp"]
        self.yd.probe = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("no probe in tests"))
        out_dir = tempfile.mkdtemp()

        def entries_of(widget, out):
            if widget.winfo_class() in ("TEntry", "Entry"):
                out.append(widget)
            for child in widget.winfo_children():
                entries_of(child, out)
            return out

        def action(root):
            entries = entries_of(root, [])
            entries[0].insert(0, "https://youtu.be/ID")
            entries[1].delete(0, "end")
            entries[1].insert(0, out_dir)
            for label in extra_labels:
                self.click(root, label)
            self.click(root, "开始下载")
            done.wait(timeout)

        self.pump(action=action)
        return modes

    def test_every_ticked_type_is_downloaded_in_turn(self):
        """The point of the tick boxes: three types, three runs, one at a time.

        yt-dlp takes a single --mode, so this is a loop in the window rather
        than anything the command builder can express.
        """
        modes = self.run_ticked(["音频（MP3）", "字幕（SRT）"], [0, 0, 0])
        self.assertEqual(modes, ["video", "audio", "subtitles"])

    def test_a_failure_stops_the_rest_of_the_queue(self):
        # Downloading the subtitles after the video already failed would bury
        # the error, and usually fails again for the same reason.
        modes = self.run_ticked(["音频（MP3）", "字幕（SRT）"], [1])
        self.assertEqual(modes, ["video"])

    def test_nothing_ticked_is_refused_before_any_download_starts(self):
        # Unticking the only ticked type; nothing to wait for, so don't.
        modes = self.run_ticked(["视频（MP4）"], [0], timeout=0.5)
        self.assertEqual(modes, [])
        self.assertTrue(self.warnings, "no warning was shown for an empty selection")


if __name__ == "__main__":
    unittest.main(verbosity=2)
