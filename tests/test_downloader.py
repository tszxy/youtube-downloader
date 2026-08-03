"""Tests for standalone/youtube_downloader.py (standard library only)."""

import importlib.util
import os
import re
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

    def test_subtitle_languages_are_exact_tags(self):
        # Wildcards like "en.*" match ~20 tracks on a popular video, and each
        # one is a request that trips YouTube's rate limiting.
        langs = args_for(mode="subtitles")
        langs = langs[langs.index("--sub-langs") + 1].split(",")
        self.assertLessEqual(len(langs), 6)
        for tag in langs:
            with self.subTest(tag=tag):
                self.assertNotIn("*", tag)
        self.assertIn("en", langs)
        self.assertIn("zh-Hans", langs)

    def test_video_prefers_h264_before_falling_back(self):
        # AV1 plays badly on older devices, so avc1 must be tried first, and
        # the chain must still end in an unconstrained fallback.
        for quality in yd.QUALITIES:
            with self.subTest(quality=quality):
                tiers = yd.video_format(quality).split("/")
                self.assertIn("vcodec^=avc1", tiers[0])
                self.assertEqual(tiers[-1], "b")
                unconstrained = [t for t in tiers if "[" not in t]
                self.assertTrue(unconstrained, "no unconstrained fallback tier")

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
        # Compare through Path so the separator matches the host OS.
        target = Path("/tmp/somewhere")
        args = args_for(output_dir=str(target))
        template = args[args.index("--output") + 1]
        self.assertTrue(template.startswith(str(target)), template)
        self.assertIn("%(title)s", template)
        self.assertIn("%(id)s", template)
        self.assertEqual(Path(template).parent, target)

    def test_ffmpeg_location_only_when_given(self):
        self.assertNotIn("--ffmpeg-location", args_for())
        args = args_for(ffmpeg_dir="/opt/ffmpeg/bin")
        self.assertEqual(args[args.index("--ffmpeg-location") + 1], "/opt/ffmpeg/bin")

    def test_runner_prefix_is_preserved(self):
        args = yd.build_command(["python3", "-m", "yt_dlp"], URL, output_dir="/tmp")
        self.assertEqual(args[:3], ["python3", "-m", "yt_dlp"])


class TestProbeCommand(unittest.TestCase):
    def test_asks_for_json_without_downloading(self):
        args = yd.probe_command(RUNNER, URL)
        self.assertIn("--dump-single-json", args)
        self.assertIn("--skip-download", args)
        self.assertIn("--no-playlist", args)
        self.assertEqual(args[-1], URL)

    def test_rejects_other_hosts(self):
        with self.assertRaises(ValueError):
            yd.probe_command(RUNNER, "https://vimeo.com/x")

    def test_cookies_browser_is_passed_through(self):
        args = yd.probe_command(RUNNER, URL, "firefox")
        self.assertEqual(args[args.index("--cookies-from-browser") + 1], "firefox")

    def test_bot_check_becomes_actionable_advice(self):
        message = yd.probe_error("ERROR: [youtube] ID: Sign in to confirm you are not a bot.")
        self.assertIn("登录状态来源", message)

    def test_other_failures_are_reported_verbatim(self):
        self.assertIn("Video unavailable", yd.probe_error("ERROR: Video unavailable"))
        self.assertIn("退出代码", yd.probe_error("", 42))


class TestAvailableOptions(unittest.TestCase):
    """What the window may offer for a given video.

    The same JSON shapes are asserted in the PowerShell smoke test, so the two
    windows grey out the same things.
    """

    SAMPLE_720 = {
        "title": "probe sample",
        "formats": [
            {"height": 720, "acodec": "none"},
            {"height": 360, "acodec": "none"},
            {"height": None, "acodec": "mp4a.40.2"},
        ],
        "subtitles": {"en": [{"ext": "vtt"}]},
        "automatic_captions": {},
    }

    def test_a_cap_above_the_video_is_not_offered(self):
        available = yd.available_options(self.SAMPLE_720)
        self.assertFalse(available["qualities"]["1080"])
        self.assertTrue(available["qualities"]["720"])
        self.assertTrue(available["qualities"]["480"])
        self.assertTrue(available["qualities"]["best"])

    def test_modes_follow_the_tracks_that_exist(self):
        available = yd.available_options(self.SAMPLE_720)
        self.assertTrue(available["modes"]["video"])
        self.assertTrue(available["modes"]["audio"])
        self.assertTrue(available["modes"]["subtitles"])

    def test_subtitles_only_count_in_the_languages_we_ask_for(self):
        # --sub-langs is an exact list, so a Japanese-only video would download
        # nothing at all.
        japanese = dict(self.SAMPLE_720, subtitles={}, automatic_captions={"ja": []})
        self.assertFalse(yd.available_options(japanese)["modes"]["subtitles"])
        for language in yd.SUB_LANGS:
            with self.subTest(language=language):
                one = dict(self.SAMPLE_720, subtitles={language: []}, automatic_captions={})
                self.assertTrue(yd.available_options(one)["modes"]["subtitles"])

    def test_audio_only_video_offers_no_video(self):
        podcast = {"formats": [{"height": None, "acodec": "mp4a.40.2"}]}
        available = yd.available_options(podcast)
        self.assertFalse(available["modes"]["video"])
        self.assertTrue(available["modes"]["audio"])
        self.assertFalse(available["qualities"]["best"])

    def test_a_zero_height_is_not_a_video_track(self):
        # Get-AvailableOption takes only positive heights; both halves have to
        # agree, or the two windows grey out different things.
        available = yd.available_options({"formats": [{"height": 0, "acodec": "mp4a.40.2"}]})
        self.assertFalse(available["modes"]["video"])
        self.assertTrue(available["modes"]["audio"])

    def test_a_cap_with_nothing_at_or_below_it_is_not_offered(self):
        # A single 1080p track cannot be capped to 720p.
        available = yd.available_options({"formats": [{"height": 1080, "acodec": "none"}]})
        self.assertTrue(available["qualities"]["1080"])
        self.assertFalse(available["qualities"]["720"])

    def test_a_probe_that_says_nothing_takes_nothing_away(self):
        for info in ({}, {"formats": []}, {"formats": None}):
            with self.subTest(info=info):
                available = yd.available_options(info)
                self.assertTrue(all(available["modes"][mode] for mode in ("video", "audio")))
                self.assertTrue(all(available["qualities"].values()))

    def test_summary_names_the_best_height(self):
        summary = yd.options_summary(yd.available_options(self.SAMPLE_720))
        self.assertIn("最高 720p", summary)
        self.assertIn("有音频", summary)
        self.assertIn("有中/英字幕", summary)


class TestBrowserDetection(unittest.TestCase):
    def test_no_browser_is_always_a_valid_choice(self):
        self.assertTrue(yd.browser_available(""))

    def test_every_supported_browser_has_a_place_to_look(self):
        # Safari is the exception: it does not exist off macOS.
        for name in yd.BROWSERS:
            with self.subTest(browser=name):
                paths = yd.browser_profile_paths(name)
                if name == "safari" and sys.platform != "darwin":
                    self.assertEqual(paths, [])
                else:
                    self.assertTrue(paths, "nowhere to look for {}".format(name))

    def test_a_missing_profile_reads_as_unavailable(self):
        original = yd.browser_profile_paths
        yd.browser_profile_paths = lambda name: [Path(tempfile.gettempdir()) / "no-such-browser"]
        try:
            self.assertFalse(yd.browser_available("chrome"))
        finally:
            yd.browser_profile_paths = original

    def test_an_existing_profile_reads_as_available(self):
        original = yd.browser_profile_paths
        with tempfile.TemporaryDirectory() as tmp:
            yd.browser_profile_paths = lambda name: [Path(tmp)]
            try:
                self.assertTrue(yd.browser_available("chrome"))
            finally:
                yd.browser_profile_paths = original


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

    def test_print_probe_command_asks_yt_dlp_for_json(self):
        result = self.run_cli(URL, "--print-probe-command")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.strip().split("\n")
        self.assertIn("--dump-single-json", lines)
        self.assertEqual(lines[-1], URL)

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


class TestBotCheck(unittest.TestCase):
    """YouTube's "prove you are not a bot" refusal is the most common failure."""

    # A Python stub rather than a shell script: the CI matrix includes Windows.
    def run_with_stub(self, printed, exit_code, **options):
        stub = Path(tempfile.mkdtemp()) / "stub.py"
        stub.write_text(
            "import sys\n"
            "print({!r})\n"
            "sys.exit({})\n".format(printed, exit_code),
            encoding="utf-8",
        )
        original = yd.find_runner
        yd.find_runner = lambda: [sys.executable, str(stub)]
        lines = []
        try:
            with tempfile.TemporaryDirectory() as out:
                code = yd.run_download(URL, on_line=lines.append, output_dir=out, **options)
        finally:
            yd.find_runner = original
        return code, "\n".join(lines)

    BLOCKED = "ERROR: [youtube] ID: Sign in to confirm you’re not a bot. Use --cookies"

    def test_failure_appends_the_hint(self):
        code, log = self.run_with_stub(self.BLOCKED, 1)
        self.assertEqual(code, 1)
        self.assertIn("--cookies-from-browser", log)

    def test_hint_names_the_browser_already_in_use(self):
        _, log = self.run_with_stub(self.BLOCKED, 1, cookies_browser="firefox")
        self.assertIn("firefox", log)

    def test_no_hint_when_the_download_succeeds(self):
        # yt-dlp prints the same wording in warnings it goes on to recover from.
        code, log = self.run_with_stub(self.BLOCKED, 0)
        self.assertEqual(code, 0)
        self.assertNotIn("--cookies-from-browser", log)

    def test_no_hint_for_unrelated_failures(self):
        _, log = self.run_with_stub("ERROR: unable to write data: No space left", 1)
        self.assertNotIn("--cookies-from-browser", log)

    def test_on_job_exposes_the_running_process(self):
        seen = []
        original = yd.find_runner
        yd.find_runner = lambda: [sys.executable, "-c", "pass"]
        try:
            with tempfile.TemporaryDirectory() as out:
                yd.run_download(URL, on_line=lambda _: None, on_job=seen.append, output_dir=out)
        finally:
            yd.find_runner = original
        self.assertEqual(len(seen), 1, "the cancel button never received the job")
        self.assertIsInstance(seen[0], yd.Download)


class TestBrowserQuitPrompt(unittest.TestCase):
    """The offer to close the login-source browser, which locks its cookies.

    Covers both Chrome and Edge, the two Chromium sources that hold the
    database open. Every test stubs both the detection and the killing: a test
    run must never actually close the browser of whoever is running it.
    """

    def setUp(self):
        self.calls = []
        self.originals = {
            name: getattr(yd, name) for name in ("browser_running", "quit_browser", "_run_quiet")
        }
        # Any command reaching _run_quiet is a bug in the test, not a pass.
        yd._run_quiet = lambda cmd, timeout=15: self.fail(
            "a real process command escaped the stubs: {}".format(cmd))

    def tearDown(self):
        for name, value in self.originals.items():
            setattr(yd, name, value)

    def arrange(self, running, quit_result=True):
        yd.browser_running = lambda browser: running
        yd.quit_browser = lambda browser, *a, **kw: self.calls.append(browser) or quit_result

    def offer(self, browser="chrome", answer="y", **kwargs):
        out = []
        result = yd.offer_browser_quit_cli(
            browser, ask=lambda _prompt: answer, out=out.append, **kwargs)
        return result, "\n".join(out)

    def test_no_prompt_when_browser_is_not_running(self):
        for browser in ("chrome", "edge"):
            self.calls = []
            self.arrange(running=False)
            result, text = self.offer(browser=browser)
            self.assertFalse(result, browser)
            self.assertEqual(text, "", browser)
            self.assertEqual(self.calls, [])

    def test_no_prompt_for_a_source_that_does_not_lock(self):
        # "" / firefox / safari never hold the database open the way the two
        # Chromium browsers do, so they are never offered for closing.
        self.arrange(running=True)
        for browser in ("", "firefox", "safari"):
            result, text = self.offer(browser=browser)
            self.assertFalse(result, browser)
            self.assertEqual(text, "", browser)
        self.assertEqual(self.calls, [])

    def test_yes_closes_chrome(self):
        self.arrange(running=True)
        result, text = self.offer(browser="chrome", answer="y")
        self.assertTrue(result)
        self.assertEqual(self.calls, ["chrome"])
        self.assertIn("Chrome 已退出", text)

    def test_yes_closes_edge(self):
        # The whole point of the request: Edge gets the same treatment as
        # Chrome, named as Edge rather than mislabelled.
        self.arrange(running=True)
        result, text = self.offer(browser="edge", answer="y")
        self.assertTrue(result)
        self.assertEqual(self.calls, ["edge"])
        self.assertIn("Edge 已退出", text)
        self.assertNotIn("Chrome", text)

    def test_answer_is_case_and_space_tolerant(self):
        for answer in ("Y", " yes ", "YES", "是"):
            self.calls = []
            self.arrange(running=True)
            result, _ = self.offer(answer=answer)
            self.assertTrue(result, answer)

    def test_no_leaves_the_browser_alone_but_warns(self):
        for answer in ("n", "", "no", "随便"):
            self.calls = []
            self.arrange(running=True)
            result, text = self.offer(browser="edge", answer=answer)
            self.assertFalse(result, answer)
            self.assertEqual(self.calls, [], answer)
            self.assertIn("Edge 仍在运行", text)

    def test_failed_quit_is_reported_as_failure(self):
        self.arrange(running=True, quit_result=False)
        result, text = self.offer(answer="y")
        self.assertFalse(result)
        self.assertIn("没能退出", text)

    def test_interrupted_answer_does_not_kill_anything(self):
        self.arrange(running=True)

        def refuse(_prompt):
            raise EOFError

        out = []
        result = yd.offer_browser_quit_cli("chrome", ask=refuse, out=out.append)
        self.assertFalse(result)
        self.assertEqual(self.calls, [])

    def test_question_explains_why_and_what_is_lost(self):
        # The dialog is the only place this is explained, so it has to carry
        # the cause, the upstream issue, the cost of saying yes, and the right
        # browser name.
        for browser, name in (("chrome", "Chrome"), ("edge", "Edge")):
            question = yd.browser_quit_question(browser)
            for fragment in ("cookies", "7271", "未保存", name):
                self.assertIn(fragment, question, browser)

    def test_process_names_differ_between_chrome_and_edge(self):
        chrome = yd.browser_process_names("chrome")
        edge = yd.browser_process_names("edge")
        for names in (chrome, edge):
            self.assertTrue(names)
            self.assertTrue(all(isinstance(name, str) and name for name in names))
        self.assertNotEqual(chrome, edge, "Chrome and Edge resolved to the same process")

    def test_running_answers_a_bool_without_raising(self):
        yd._run_quiet = self.originals["_run_quiet"]
        yd.browser_running = self.originals["browser_running"]
        for browser in ("chrome", "edge"):
            self.assertIsInstance(yd.browser_running(browser), bool)

    def test_unknown_process_state_reads_as_not_running(self):
        # pgrep/tasklist missing must not produce an offer to kill anything.
        yd.browser_running = self.originals["browser_running"]
        yd._run_quiet = lambda cmd, timeout=15: None
        self.assertFalse(yd.browser_running("chrome"))
        self.assertFalse(yd.browser_running("edge"))

    def test_quit_returns_early_once_the_browser_is_gone(self):
        yd.quit_browser = self.originals["quit_browser"]
        issued = []
        yd._run_quiet = lambda cmd, timeout=15: issued.append(cmd)
        yd.browser_running = lambda browser: False
        started = time.monotonic()
        self.assertTrue(yd.quit_browser("edge", grace=5))
        # One polite request, then out -- no waiting on the grace period and
        # no escalation to a forced kill.
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(len(issued), 1)
        self.assertNotIn("/F", issued[0])
        self.assertNotIn("-9", issued[0])

    def test_quit_escalates_only_after_the_grace_period(self):
        yd.quit_browser = self.originals["quit_browser"]
        issued = []
        yd._run_quiet = lambda cmd, timeout=15: issued.append(cmd)
        yd.browser_running = lambda browser: True  # never goes away
        self.assertFalse(yd.quit_browser("chrome", grace=0.5))
        self.assertGreater(len(issued), 1, "a stubborn browser was never escalated")
        forced = " ".join(" ".join(cmd) for cmd in issued[1:])
        self.assertTrue("/F" in forced or "-9" in forced)


class TestVersion(unittest.TestCase):
    """The version in the title bar, and the two GUIs agreeing on it.

    The point of showing it at all is that a bug report names a build, which
    only works while both implementations report the same one.
    """

    PS1 = ROOT / "standalone" / "windows" / "YouTube-Downloader.ps1"

    def test_version_looks_like_a_version(self):
        self.assertRegex(yd.VERSION, r"^\d+\.\d+\.\d+$")

    def test_title_bar_carries_the_version_and_the_name(self):
        self.assertIn(yd.VERSION, yd.APP_TITLE)
        self.assertIn(yd.APP_NAME, yd.APP_TITLE)

    def test_powershell_gui_shows_the_same_version(self):
        source = self.PS1.read_text(encoding="utf-8")
        match = re.search(r'\$form\.Text\s*=\s*"([^"]+)"', source)
        self.assertIsNotNone(match, "could not find the PowerShell window title")
        title = match.group(1)
        self.assertEqual(
            title, yd.APP_TITLE,
            "the two GUIs disagree about the title bar; update both or the "
            "version in a bug report means nothing")


class TestWindowsParity(unittest.TestCase):
    """The PowerShell GUI must carry the startup checks the Python one does.

    Windows is where the locked cookie database and the missing dependencies
    actually bite, and it is the platform least likely to have a terminal open
    to work around either. A check that exists only in Python is a check the
    people who need it most never see.
    """

    PS1 = ROOT / "standalone" / "windows" / "YouTube-Downloader.ps1"
    WINDOWS = ROOT / "standalone" / "windows"

    def setUp(self):
        self.source = self.PS1.read_text(encoding="utf-8")

    def test_browser_is_detected_and_can_be_closed(self):
        for needed in ("Test-BrowserRunning", "Stop-Browser", "Invoke-BrowserQuitOffer", "7271"):
            self.assertIn(needed, self.source,
                          "the PowerShell GUI lost the browser check: " + needed)

    def test_both_chrome_and_edge_are_handled(self):
        # Edge is the fallback when Chrome refuses, so it must lock-quit too.
        for token in ("chrome", "edge", "msedge"):
            self.assertIn(token, self.source,
                          "the PowerShell GUI does not handle " + token)

    def test_browser_is_asked_about_politely_before_being_forced(self):
        # CloseMainWindow before taskkill /F: the reverse loses unsaved tabs
        # without ever asking the browser to close itself.
        self.assertLess(self.source.index("CloseMainWindow"),
                        self.source.index("taskkill.exe /IM"))

    def test_startup_offers_whatever_is_missing(self):
        shown = self.source.index("$form.Add_Shown")
        handler = self.source[shown:]
        for needed in ("Find-Executable", "Resolve-FfmpegDirectory", "缺少依赖"):
            self.assertIn(needed, handler,
                          "startup stopped checking for " + needed)

    def test_one_entry_point_and_the_old_names_forward_to_it(self):
        entry = self.WINDOWS / "YouTube-Downloader.bat"
        self.assertTrue(entry.is_file(), "the single entry point is missing")
        self.assertIn("YouTube-Downloader.ps1", entry.read_text(encoding="utf-8"))
        for old in ("Run-Downloader.bat", "Install-and-Run.bat"):
            text = (self.WINDOWS / old).read_text(encoding="utf-8")
            self.assertIn("YouTube-Downloader.bat", text,
                          "{} no longer forwards to the one entry".format(old))


class TestToolDiscovery(unittest.TestCase):
    def test_find_runner_returns_list_or_none(self):
        runner = yd.find_runner()
        self.assertTrue(runner is None or isinstance(runner, list))

    def test_ffmpeg_hint_mentions_a_package_manager(self):
        self.assertTrue(any(word in yd.ffmpeg_hint() for word in ("brew", "apt", "install")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
