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
import sys
import tempfile
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
            root.withdraw()
            for _ in range(cycles):
                root.update()
            if action is not None:
                action(root)
                for _ in range(cycles):
                    root.update()
            self.widgets = snapshot(root, [])
            # The app cancels its drain timer in on_close, which this fake
            # mainloop bypasses. Clear anything still pending so Tcl does not
            # fire a callback against a destroyed window.
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

    def of_class(self, name):
        return [w for w in self.widgets if w["class"] == name]

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
        labels = self.texts()
        for expected in ["YouTube 链接", "下载类型", "视频画质", "登录状态",
                         "保存目录", "开始下载", "取消", "安装/更新依赖",
                         "下载整个播放列表", "浏览..."]:
            with self.subTest(label=expected):
                self.assertIn(expected, labels)

    def test_has_three_dropdowns_a_progress_bar_and_a_log(self):
        self.pump()
        self.assertEqual(len(self.of_class("TCombobox")), 3)
        self.assertEqual(len(self.of_class("TProgressbar")), 1)
        self.assertEqual(len(self.of_class("Text")), 1)

    def test_dropdowns_offer_the_documented_choices(self):
        self.pump()
        values = [w["values"] for w in self.of_class("TCombobox")]
        self.assertIn(["视频（MP4）", "音频（MP3）", "字幕（SRT）"], values)
        self.assertIn(["最佳画质", "最高 1080p", "最高 720p", "最高 480p"], values)
        browsers = [v for v in values if v and v[0] == "不使用"][0]
        self.assertEqual(len(browsers), len(self.yd.BROWSERS) + 1)

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

    def test_download_button_streams_yt_dlp_output_into_the_log(self):
        """The download button must reach run_download and pump its output.

        The GUI used to carry its own copy of that loop; this covers the path
        end to end so the copy cannot come back unnoticed.
        """
        marker = "STUB-RAN-OK"
        stub = Path(tempfile.mkdtemp()) / "stub.py"
        stub.write_text("print({!r})\n".format(marker), encoding="utf-8")
        self.yd.find_runner = lambda: [sys.executable, str(stub)]
        out_dir = tempfile.mkdtemp()
        captured = {}

        def widgets_of_class(widget, names, out):
            if widget.winfo_class() in names:
                out.append(widget)
            for child in widget.winfo_children():
                widgets_of_class(child, names, out)
            return out

        def action(root):
            entries = widgets_of_class(root, ("TEntry", "Entry"), [])
            self.assertGreaterEqual(len(entries), 2, "expected a URL and a folder entry")
            entries[0].insert(0, "https://youtu.be/ID")
            entries[1].delete(0, "end")
            entries[1].insert(0, out_dir)
            self.click(root, "开始下载")

            log = widgets_of_class(root, ("Text",), [])[0]
            # The download runs on a worker thread and reaches the log only via
            # the 120 ms drain timer, so pump until it shows up.
            deadline = time.time() + 20
            while time.time() < deadline:
                root.update()
                if marker in log.get("1.0", "end"):
                    break
                time.sleep(0.05)
            captured["log"] = log.get("1.0", "end")

        self.pump(action=action, cycles=5)
        self.assertIn(marker, captured.get("log", ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
