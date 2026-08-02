"""Tests for standalone/youtube_downloader.py (standard library only)."""

import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "standalone" / "youtube_downloader.py"


def load_app():
    spec = importlib.util.spec_from_file_location("youtube_downloader", APP)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


yd = load_app()
RUNNER = ["yt-dlp"]
URL = "https://youtu.be/ID"


def args_for(**kwargs):
    kwargs.setdefault("output_dir", "/tmp/out")
    return yd.build_command(RUNNER, kwargs.pop("url", URL), **kwargs)


class TestUrlValidation(unittest.TestCase):
    def test_accepts_real_youtube_urls(self):
        for url in [
            "https://www.youtube.com/watch?v=abc",
            "https://youtube.com/watch?v=abc",
            "https://m.youtube.com/watch?v=abc",
            "https://music.youtube.com/watch?v=abc",
            "https://youtu.be/abc",
            "http://youtu.be/abc",
            "https://www.youtube.com/shorts/abc",
            "https://www.youtube.com/playlist?list=abc",
        ]:
            with self.subTest(url=url):
                self.assertTrue(args_for(url=url))

    def test_rejects_other_hosts(self):
        for url in [
            "https://vimeo.com/x",
            "ftp://youtube.com/x",
            "https://evil.com/youtube.com/x",
            "https://youtube.com.evil.io/x",
            "https://notyoutube.com/x",
            "javascript:alert(1)",
            "",
        ]:
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    args_for(url=url)


class TestCommandBuilding(unittest.TestCase):
    def test_rejects_unknown_mode_and_quality(self):
        with self.assertRaises(ValueError):
            args_for(mode="bogus")
        with self.assertRaises(ValueError):
            args_for(quality="4k")

    def test_defaults_to_single_video_mp4(self):
        args = args_for()
        self.assertIn("--no-playlist", args)
        self.assertIn("--merge-output-format", args)
        self.assertEqual(args[args.index("--format") + 1], yd.video_format("best"))
        self.assertEqual(args[-1], URL)

    def test_playlist_flag_removes_no_playlist(self):
        self.assertNotIn("--no-playlist", args_for(playlist=True))

    def test_quality_caps_height(self):
        for quality in ("1080", "720", "480"):
            with self.subTest(quality=quality):
                selector = args_for(quality=quality)[
                    args_for(quality=quality).index("--format") + 1]
                self.assertIn("height<={}".format(quality), selector)

    def test_audio_mode_extracts_mp3(self):
        args = args_for(mode="audio")
        self.assertIn("--extract-audio", args)
        self.assertEqual(args[args.index("--audio-format") + 1], "mp3")
        self.assertNotIn("--merge-output-format", args)

    def test_subtitles_mode_skips_download(self):
        args = args_for(mode="subtitles")
        self.assertIn("--skip-download", args)
        self.assertEqual(args[args.index("--convert-subs") + 1], "srt")

    def test_cookies_browser_is_passed_through(self):
        args = args_for(cookies_browser="firefox")
        self.assertEqual(args[args.index("--cookies-from-browser") + 1], "firefox")

    def test_no_cookies_flag_when_unset(self):
        self.assertNotIn("--cookies-from-browser", args_for())

    def test_concurrent_fragments_always_set(self):
        for mode in yd.MODES:
            with self.subTest(mode=mode):
                self.assertIn("--concurrent-fragments", args_for(mode=mode))

    def test_output_template_includes_directory(self):
        args = args_for(output_dir="/tmp/somewhere")
        template = args[args.index("--output") + 1]
        self.assertTrue(template.startswith("/tmp/somewhere"))
        self.assertIn("%(title)s", template)
        self.assertIn("%(id)s", template)

    def test_ffmpeg_location_only_when_given(self):
        self.assertNotIn("--ffmpeg-location", args_for())
        args = args_for(ffmpeg_dir="/opt/ffmpeg/bin")
        self.assertEqual(args[args.index("--ffmpeg-location") + 1], "/opt/ffmpeg/bin")

    def test_runner_prefix_is_preserved(self):
        args = yd.build_command(["python3", "-m", "yt_dlp"], URL, output_dir="/tmp")
        self.assertEqual(args[:3], ["python3", "-m", "yt_dlp"])


class TestProgressParsing(unittest.TestCase):
    def test_matches_yt_dlp_progress_lines(self):
        cases = {
            "[download]   0.0% of 10.00MiB at 1.00MiB/s": "0.0",
            "[download]  42.5% of 10.00MiB": "42.5",
            "[download] 100% of 10.00MiB": "100",
        }
        for line, expected in cases.items():
            with self.subTest(line=line):
                self.assertEqual(yd.PROGRESS.search(line).group(1), expected)

    def test_ignores_unrelated_lines(self):
        self.assertIsNone(yd.PROGRESS.search("[youtube] Extracting URL: https://x"))


class TestCli(unittest.TestCase):
    def run_cli(self, *argv):
        return subprocess.run(
            [sys.executable, str(APP)] + list(argv),
            capture_output=True, text=True,
        )

    def test_print_command_emits_one_argument_per_line(self):
        result = self.run_cli(URL, "--print-command", "-o", "/tmp/x")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().split("\n")
        self.assertIn("--no-playlist", lines)
        self.assertEqual(lines[-1], URL)
        # The output template contains a space and must survive as one line.
        template = lines[lines.index("--output") + 1]
        self.assertTrue(template.endswith("%(title)s [%(id)s].%(ext)s"))

    def test_url_flag_is_equivalent_to_positional(self):
        a = self.run_cli(URL, "--print-command", "-o", "/tmp/x").stdout
        b = self.run_cli("--url", URL, "--print-command", "-o", "/tmp/x").stdout
        self.assertEqual(a, b)

    def test_conflicting_urls_are_rejected(self):
        result = self.run_cli(URL, "--url", "https://youtu.be/OTHER", "--print-command")
        self.assertNotEqual(result.returncode, 0)

    def test_bad_url_exits_nonzero_without_creating_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "should-not-exist"
            result = self.run_cli("https://vimeo.com/x", "-o", str(target))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())


@unittest.skipIf(os.name == "nt", "POSIX process-group behaviour")
class TestCancellation(unittest.TestCase):
    def test_cancel_kills_child_processes(self):
        script = Path(tempfile.mkdtemp()) / "fake_yt_dlp.sh"
        script.write_text("#!/bin/sh\nsleep 600 &\necho child=$!\nsleep 600\n")
        script.chmod(0o755)

        job = yd.Download([str(script)])
        job.start()
        child = []

        def read():
            for line in job.lines():
                if line.startswith("child="):
                    child.append(int(line.split("=")[1]))

        threading.Thread(target=read, daemon=True).start()
        deadline = time.time() + 10
        while not child and time.time() < deadline:
            time.sleep(0.1)
        self.assertTrue(child, "stub never reported its child pid")

        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except OSError:
                return False

        self.assertTrue(alive(child[0]))
        job.cancel()
        deadline = time.time() + 10
        while alive(child[0]) and time.time() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive(child[0]), "ffmpeg-like child survived cancellation")


class TestToolDiscovery(unittest.TestCase):
    def test_find_runner_returns_list_or_none(self):
        runner = yd.find_runner()
        self.assertTrue(runner is None or isinstance(runner, list))

    def test_ffmpeg_hint_mentions_a_package_manager(self):
        self.assertTrue(any(word in yd.ffmpeg_hint() for word in ("brew", "apt", "install")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
