"""Own-process fixtures for the CI watchdog; no global process inventory."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / ".github/scripts/watchdog.py"
WRAPPER = ROOT / ".github/scripts/run-with-watchdog.sh"
spec = importlib.util.spec_from_file_location("watchdog", HELPER)
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)

FIXTURE = r'''
import json, os, signal, sys, time
from pathlib import Path
mode, ready, status = sys.argv[1], Path(sys.argv[2]), int(sys.argv[3])
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.alarm(12)
if mode == "exit":
    sys.exit(status)
readfd, writefd = os.pipe()
child = os.fork()
if child == 0:
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(12)
    def term(*_):
        ready.with_suffix(".term").write_text("TERM received")
    signal.signal(signal.SIGTERM, term)
    ready.with_suffix(".child").write_text("ready")
    # The fixture owns both ends. It blocks indefinitely unless killed/alarmed,
    # and keeps the watchdog's stdout open as an independent cleanup oracle.
    os.read(readfd, 1)
    os._exit(0)
while not ready.with_suffix(".child").exists():
    time.sleep(0.005)
ready.write_text(json.dumps({"root": os.getpid(), "group": os.getpgrp()}))
if mode == "flood":
    while True:
        os.write(1, b"x" * 4096)
if mode == "orphan":
    os._exit(status)
if mode == "anchor-dies":
    os.kill(os.getpgrp(), signal.SIGKILL)
if mode == "stopped":
    os.kill(os.getpid(), signal.SIGSTOP)
if mode == "race":
    # Parent harness triggers cancellation and root exit from the same marker.
    while not ready.with_suffix(".exit").exists():
        time.sleep(0.005)
    os._exit(status)
os.read(readfd, 1)
'''


@unittest.skipUnless(os.name == "posix", "watchdog uses POSIX sessions")
class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sanjbox-watchdog-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.fixture = self.directory / "command.py"
        self.fixture.write_text(FIXTURE)
        self.ready = self.directory / "ready.json"
        self.logs = self.directory / "logs"
        self.processes = []
        self.addCleanup(self.cleanup_processes)

    def cleanup_processes(self):
        # Direct children only; never signal fixture PID records. Killing a
        # wrapper closes its control socket and exercises the anchor fallback.
        for child in self.processes:
            if child.poll() is None:
                child.kill()
            try:
                child.communicate(timeout=14)
            except subprocess.TimeoutExpired:
                self.fail("fixture exceeded its independent 12-second alarm")

    def launch(self, mode="exit", status=0, limit=3, wrapper=False, command=None, helper=HELPER):
        prefix = ["/bin/bash", str(WRAPPER)] if wrapper else [sys.executable, "-I", "-B", str(helper)]
        command = command or [sys.executable, "-I", "-B", str(self.fixture), mode, str(self.ready), str(status)]
        process = subprocess.Popen(prefix + [str(limit), str(self.logs)] + command,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.processes.append(process)
        return process

    def patched_helper(self, patch):
        launcher = self.directory / "patched_watchdog.py"
        launcher.write_text(
            "import importlib.util,os,sys\n"
            "spec=importlib.util.spec_from_file_location('watchdog', %r)\n"
            "watchdog=importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(watchdog)\n" % str(HELPER)
            + patch + "\nos._exit(watchdog.main(sys.argv))\n")
        return launcher

    def wait_ready(self, process):
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if self.ready.exists():
                try:
                    return json.loads(self.ready.read_text())
                except json.JSONDecodeError:
                    # write_text creates/truncates the file before writing its JSON.
                    # The fixture can still be alive and completing that write.
                    pass
            if process.poll() is not None:
                self.fail("own fixture exited before writing complete ready JSON")
            time.sleep(0.01)
        self.fail("own fixture did not write complete ready JSON")

    def test_wait_ready_waits_for_complete_json(self):
        self.ready.write_text("")
        process = subprocess.Popen(
            [sys.executable, "-I", "-B", "-c",
             "import pathlib,sys,time; time.sleep(0.05); "
             "pathlib.Path(sys.argv[1]).write_text('{\"root\": 1}')",
             str(self.ready)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(process)
        self.assertEqual(self.wait_ready(process), {"root": 1})
        self.assertEqual(process.wait(timeout=2), 0)

    def finish(self, process, expected, timeout=7):
        # communicate also requires EOF from the pipe inherited by descendants.
        # A wrapper exiting while leaving the fixture child alive cannot pass.
        output = process.communicate(timeout=timeout)[0].decode()
        self.assertEqual(process.returncode, expected, output)
        return output

    def test_clean_exit_status_and_bash_wrapper(self):
        for status in (0, 7, 124):
            with self.subTest(status=status):
                self.finish(self.launch(status=status, wrapper=True), status)
                self.assertFalse((self.logs / "hung-processes.txt").exists())

    def test_exec_failure_status(self):
        self.finish(self.launch(command=[str(self.directory / "missing")]), 127)
        nonexecutable = self.directory / "nonexecutable"
        nonexecutable.write_text("fixture")
        self.finish(self.launch(command=[str(nonexecutable)]), 126)

    def test_signal_exit_status(self):
        self.finish(self.launch(command=[sys.executable, "-c",
                                        "import os,signal; os.kill(os.getpid(),signal.SIGTERM)"]), 143)

    def test_root_exit_cannot_leave_pipe_blocked_child_and_pass(self):
        for status, expected in ((0, 125), (9, 9)):
            with self.subTest(status=status):
                start = time.monotonic()
                output = self.finish(self.launch("orphan", status), expected)
                self.assertLess(time.monotonic() - start, 4)
                self.assertIn("left live processes", output)
                self.assertTrue(self.ready.with_suffix(".term").exists())
                self.assertIn("pid pgid state", (self.logs / "hung-processes.txt").read_text())
                self.ready.with_suffix(".term").unlink()
                self.ready.with_suffix(".child").unlink()
                self.ready.unlink()

    def test_timeout_cleans_root_and_term_ignoring_child(self):
        start = time.monotonic()
        process = self.launch("hang", limit=0.3)
        self.wait_ready(process)
        output = self.finish(process, 124)
        self.assertIn("timed out", output)
        self.assertTrue(self.ready.with_suffix(".term").exists())
        self.assertLess(time.monotonic() - start, 5)

    def test_timeout_continues_stopped_root_and_cleans_child(self):
        process = self.launch("stopped", limit=0.3)
        self.wait_ready(process)
        self.finish(process, 124)
        self.assertTrue(self.ready.with_suffix(".term").exists())

    def test_reap_failure_preserves_only_timeout_status(self):
        helper = self.patched_helper(
            "reap = watchdog.reap_anchor\n"
            "def failed_reap(anchor):\n"
            "    reap(anchor)\n"
            "    return False\n"
            "watchdog.reap_anchor = failed_reap\n")
        # Reap the real fixture so the test cannot leak a child, then inject the
        # same failure report an uninterruptible anchor would produce.
        for mode, status, expected in (("hang", 0, 124), ("exit", 0, 125), ("exit", 124, 125)):
            with self.subTest(mode=mode, status=status):
                output = self.finish(self.launch(mode, status, limit=0.3, helper=helper), expected)
                self.assertIn("anchor did not exit within the reap budget", output)
                if mode == "hang":
                    self.assertTrue(self.ready.with_suffix(".term").exists())

    def test_startup_failure_cannot_block_on_full_stderr(self):
        for operation in ("socketpair", "fork"):
            with self.subTest(operation=operation):
                helper = self.patched_helper(
                    "module = watchdog.%s\n"
                    "original = module.%s\n"
                    "def fail_once(*args, **kwargs):\n"
                    "    module.%s = original\n"
                    "    raise OSError('synthetic startup allocation failure')\n"
                    "module.%s = fail_once\n" % (
                        "socket" if operation == "socketpair" else "os",
                        operation, operation, operation))
                readfd, writefd = os.pipe()
                process = None
                marker = self.directory / "command-started"
                try:
                    os.set_blocking(writefd, False)
                    while True:
                        try:
                            os.write(writefd, b"x" * 4096)
                        except BlockingIOError:
                            break
                    os.set_blocking(writefd, True)
                    process = subprocess.Popen(
                        [sys.executable, "-I", "-B", str(helper), "3", str(self.logs),
                         sys.executable, "-c", "from pathlib import Path; Path(%r).touch()" % str(marker)],
                        stdout=subprocess.PIPE, stderr=writefd)
                    self.processes.append(process)
                    os.close(writefd)
                    writefd = None
                    self.assertEqual(process.wait(timeout=3), 125)
                    self.assertFalse(marker.exists(), "startup failure launched the command")
                    # EOF also proves the bounded reporter relinquished stderr.
                    os.set_blocking(readfd, False)
                    while os.read(readfd, 4096):
                        pass
                    self.finish(process, 125, timeout=1)
                finally:
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait(timeout=2)
                    os.close(readfd)
                    if writefd is not None:
                        os.close(writefd)

    def test_full_undrained_stdout_cannot_block_cleanup_or_exit(self):
        process = self.launch("flood", limit=0.3)
        self.wait_ready(process)
        # Deliberately do NOT drain either stream until supervisor exit. The
        # previous synchronous print blocked before TERM at this exact point.
        start = time.monotonic()
        self.assertEqual(process.wait(timeout=6), 124)
        self.assertLess(time.monotonic() - start, 5)
        self.assertTrue(self.ready.with_suffix(".term").exists())
        self.assertIn("timed out", (self.logs / "hung-processes.txt").read_text())
        self.finish(process, 124, timeout=1)

    def test_full_undrained_stderr_cannot_block_argument_error_exit(self):
        readfd, writefd = os.pipe()
        try:
            os.set_blocking(writefd, False)
            while True:
                try:
                    os.write(writefd, b"x" * 4096)
                except BlockingIOError:
                    break
            os.set_blocking(writefd, True)
            process = subprocess.Popen([sys.executable, "-I", "-B", str(HELPER),
                                        "invalid", str(self.logs), "unused"],
                                       stdout=subprocess.PIPE, stderr=writefd)
            self.processes.append(process)
            os.close(writefd)
            writefd = None
            self.assertEqual(process.wait(timeout=3), 2)
            # Also require the reporter's inherited descriptor to close.
            os.set_blocking(readfd, False)
            while os.read(readfd, 4096):
                pass
            self.finish(process, 2, timeout=1)
        finally:
            os.close(readfd)
            if writefd is not None:
                os.close(writefd)

    def test_fifo_log_target_cannot_block_exit(self):
        self.logs.mkdir()
        target = self.logs / "hung-processes.txt"
        os.mkfifo(target)
        process = self.launch("hang", limit=0.3)
        self.wait_ready(process)
        self.assertEqual(process.wait(timeout=5), 124)
        output = self.finish(process, 124, timeout=1)
        self.assertIn("cannot write diagnostic log", output)
        self.assertTrue(stat.S_ISFIFO(target.stat().st_mode))
        self.assertTrue(self.ready.with_suffix(".term").exists())

    def test_symlink_log_target_is_not_overwritten(self):
        self.logs.mkdir()
        canary = self.directory / "own-canary.txt"
        canary.write_text("untouched")
        (self.logs / "hung-processes.txt").symlink_to(canary)
        self.finish(self.launch("hang", limit=0.3), 124)
        self.assertEqual(canary.read_text(), "untouched")

    def test_diagnostic_directory_symlink_and_hardlink_target_are_rejected(self):
        actual_logs = self.directory / "actual-logs"
        actual_logs.mkdir()
        canary = actual_logs / "hung-processes.txt"
        canary.write_text("untouched")
        self.logs.symlink_to(actual_logs, target_is_directory=True)
        output = self.finish(self.launch("hang", limit=0.3), 124)
        self.assertIn("cannot write diagnostic log", output)
        self.assertEqual(canary.read_text(), "untouched")
        self.logs.unlink()
        self.logs.mkdir()
        os.link(canary, self.logs / "hung-processes.txt")
        output = self.finish(self.launch("hang", limit=0.3), 124)
        self.assertIn("cannot write diagnostic log", output)
        self.assertEqual(canary.read_text(), "untouched")

    def test_supervisor_death_during_reporting_cannot_orphan_reporter(self):
        launcher = self.directory / "blocked_reporter.py"
        marker = self.directory / "reporter-started"
        launcher.write_text(
            "import importlib.util,os,signal,sys\n"
            "from pathlib import Path\n"
            "spec=importlib.util.spec_from_file_location('watchdog', %r)\n"
            "watchdog=importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(watchdog)\n"
            "def block(*args):\n"
            "    Path(%r).write_text('ready')\n"
            "    while True: signal.pause()\n"
            "watchdog.write_diagnostic=block\n"
            "emit=watchdog.emit_diagnostics\n"
            "def inherit_blocked_alarm(*args, **kwargs):\n"
            "    signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGALRM})\n"
            "    return emit(*args, **kwargs)\n"
            "watchdog.emit_diagnostics=inherit_blocked_alarm\n"
            "os._exit(watchdog.main(sys.argv))\n" % (str(HELPER), str(marker)))
        process = subprocess.Popen([sys.executable, "-I", "-B", str(launcher),
                                    "3", str(self.logs), sys.executable, "-I", "-B",
                                    str(self.fixture), "orphan", str(self.ready), "0"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.processes.append(process)
        end = time.monotonic() + 4
        while not marker.exists():
            if process.poll() is not None or time.monotonic() >= end:
                self.fail("owned reporter did not start")
            time.sleep(0.01)
        process.kill()
        # The blocked reporter holds stdout. EOF needs its own alarm to fire;
        # killing the supervisor alone cannot satisfy this assertion.
        self.finish(process, -signal.SIGKILL, timeout=2)

    def test_inherited_sigchld_ignore_does_not_release_owned_pids(self):
        launcher = ("import os,signal,sys; "
                    "signal.signal(signal.SIGCHLD,signal.SIG_IGN); "
                    "os.execv(sys.executable,[sys.executable,'-I','-B']+sys.argv[1:])")
        process = subprocess.Popen([sys.executable, "-I", "-B", "-c", launcher,
                                    str(HELPER), "0.3", str(self.logs), sys.executable,
                                    "-I", "-B", str(self.fixture), "hang", str(self.ready), "0"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.processes.append(process)
        self.finish(process, 124)
        self.assertTrue(self.ready.with_suffix(".term").exists())

    def test_cancellation_signals_clean_owned_group(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                process = self.launch("hang", wrapper=True)
                info = self.wait_ready(process)
                self.assertNotEqual(info["group"], os.getpgrp())
                process.send_signal(sig)
                self.finish(process, 128 + sig)
                self.ready.with_suffix(".child").unlink()
                self.ready.unlink()

    def test_cancellation_racing_root_exit_never_passes(self):
        for _ in range(3):
            process = self.launch("race")
            self.wait_ready(process)
            self.ready.with_suffix(".exit").write_text("exit")
            process.send_signal(signal.SIGTERM)
            self.finish(process, 143)
            self.ready.with_suffix(".exit").unlink()
            self.ready.with_suffix(".child").unlink()
            self.ready.unlink()

    def test_anchor_death_fails_and_cleans_children(self):
        output = self.finish(self.launch("anchor-dies"), 125)
        self.assertIn("anchor exited unexpectedly", output)

    def test_supervisor_death_anchor_cleans_children(self):
        process = self.launch("hang")
        self.wait_ready(process)
        process.kill()
        self.finish(process, -signal.SIGKILL)
        self.assertTrue(self.ready.with_suffix(".term").exists())

    def test_cancellation_does_not_signal_unrelated_direct_child(self):
        unrelated = subprocess.Popen([sys.executable, "-c",
                                      "import signal,time; signal.alarm(12); time.sleep(10)"])
        self.processes.append(unrelated)
        process = self.launch("hang")
        self.wait_ready(process)
        process.send_signal(signal.SIGTERM)
        self.finish(process, 143)
        self.assertIsNone(unrelated.poll())
        unrelated.terminate()
        unrelated.wait(timeout=2)

    def test_failed_scope_verification_cannot_pass(self):
        launcher = self.directory / "snapshot_failure.py"
        launcher.write_text(
            "import importlib.util,sys\n"
            "spec=importlib.util.spec_from_file_location('watchdog', %r)\n"
            "watchdog=importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(watchdog)\n"
            "def fail(*args):\n"
            "    raise watchdog.ScopeError('synthetic snapshot failure')\n"
            "watchdog.snapshot=fail\n"
            "sys.exit(watchdog.main(sys.argv))\n" % str(HELPER))
        start = time.monotonic()
        process = subprocess.Popen([sys.executable, "-I", "-B", str(launcher),
                                    "3", str(self.logs), sys.executable, "-c", "pass"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.processes.append(process)
        output = self.finish(process, 125)
        self.assertIn("cleanup could not be verified", output)
        self.assertLess(time.monotonic() - start, 6)

    def test_invalid_deadlines_do_not_launch(self):
        for limit in ("0", "-1", "nan", "inf", "wrong"):
            with self.subTest(limit=limit):
                self.finish(self.launch("hang", limit=limit), 2)
                self.assertFalse(self.ready.exists())

    def test_snapshot_is_scoped_and_rejects_unknown_output(self):
        with mock.patch.object(watchdog, "bounded_output", return_value="200 200 S\n201 200 Z\n202 200 S\n") as query:
            self.assertEqual(watchdog.snapshot(200, 10)[0], [202])
            args = query.call_args[0][0]
            self.assertEqual(args[2], "200")
            self.assertNotIn("-A", args)
            self.assertNotIn("-e", args)
        for output in ("", "201 200 S\n", "bad\n", "201 999 S\n"):
            with self.subTest(output=output), mock.patch.object(watchdog, "bounded_output", return_value=output):
                with self.assertRaises(watchdog.ScopeError):
                    watchdog.snapshot(200, 10)

    def test_diagnostic_helper_deadline_and_output_cap(self):
        start = time.monotonic()
        with self.assertRaisesRegex(watchdog.ScopeError, "timed out"):
            watchdog.bounded_output([sys.executable, "-c", "import time; time.sleep(12)"],
                                    time.monotonic() + 0.15)
        self.assertLess(time.monotonic() - start, 1)
        with self.assertRaisesRegex(watchdog.ScopeError, "64 KiB"):
            watchdog.bounded_output([sys.executable, "-c", "import os; os.write(1,b'x'*100000)"],
                                    time.monotonic() + 1)


if __name__ == "__main__":
    unittest.main()
