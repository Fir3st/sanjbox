#!/usr/bin/python3
"""Bounded CI command supervision; see WATCHDOG.md for the ownership contract."""

import math
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import time

POLL = 0.05
QUERY_SECONDS = 0.5
QUERY_BYTES = 65536
QUERY_REAP_SECONDS = 0.1
TERM_SECONDS = 1.0
CLEANUP_SECONDS = 4.0
REAP_SECONDS = 0.5
CANCEL_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


class ScopeError(Exception):
    pass


def shell_status(returncode):
    return returncode if returncode >= 0 else 128 - returncode


def signal_group(anchor, sig):
    # The caller MUST retain the unreaped anchor until its last group operation.
    try:
        os.killpg(anchor, sig)
    except ProcessLookupError:
        pass


def anchor_main(control, command):
    """Stay in the new group, even after reaping the command root."""
    try:
        os.setsid()
        for sig in CANCEL_SIGNALS:
            # Caught handlers (unlike SIG_IGN) reset to default on command exec.
            signal.signal(sig, lambda *_: None)
        control.sendall(b"READY\n")
        if control.recv(1) != b"G":
            return
        try:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, close_fds=True)
        except OSError as exc:
            status = 127 if isinstance(exc, FileNotFoundError) else 126
            control.sendall(("EXIT %d\n" % status).encode("ascii"))
            child = None
        reported = child is None
        while True:
            if not reported:
                status = child.poll()
                if status is not None:
                    control.sendall(("EXIT %d\n" % shell_status(status)).encode("ascii"))
                    reported = True
            readable, _, _ = select.select([control], [], [], POLL)
            if readable:
                request = control.recv(1)
                if not request:
                    break
    except BaseException:
        # Includes exec failure and a supervisor disappearing before READY/EXIT.
        pass
    # The supervisor may have been killed. No external PID is accepted here:
    # this process is itself the live session/group leader until the final KILL.
    if os.getpgrp() == os.getpid():
        signal_group(os.getpid(), signal.SIGTERM)
        signal_group(os.getpid(), signal.SIGCONT)
        time.sleep(TERM_SECONDS)
        signal_group(os.getpid(), signal.SIGKILL)


def bounded_output(command, deadline):
    """Collect at most QUERY_BYTES, with a shared deadline including helper reap."""
    end = min(deadline - QUERY_REAP_SECONDS, time.monotonic() + QUERY_SECONDS)
    if end <= time.monotonic():
        raise ScopeError("process snapshot deadline exhausted")
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    output = bytearray()
    try:
        while True:
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise ScopeError("process snapshot timed out")
            readable, _, _ = select.select([child.stdout], [], [], remaining)
            if not readable:
                raise ScopeError("process snapshot timed out")
            part = os.read(child.stdout.fileno(), min(4096, QUERY_BYTES + 1 - len(output)))
            if not part:
                try:
                    status = child.wait(timeout=max(0, end - time.monotonic()))
                except subprocess.TimeoutExpired:
                    raise ScopeError("process snapshot did not exit")
                if status not in (0, 1):
                    raise ScopeError("process snapshot failed")
                return output.decode("ascii", errors="strict")
            output.extend(part)
            if len(output) > QUERY_BYTES:
                raise ScopeError("process snapshot exceeds 64 KiB")
    finally:
        # This is our own direct child, and Popen.kill checks whether it exited.
        if child.poll() is None:
            child.kill()
            try:
                child.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
        child.stdout.close()


def snapshot(anchor, deadline):
    # Darwin -g selects a process group; GNU ps -s selects a session. The session
    # leader is pinned on both platforms. Never use a global process inventory or
    # individually query/signal cached descendant PIDs. Only numeric metadata is
    # requested; command arguments and other sessions are never collected.
    selector = "-g" if sys.platform == "darwin" else "-s"
    output = bounded_output(["/bin/ps", selector, str(anchor),
                             "-o", "pid=,pgid=,stat="], deadline)
    live = []
    seen_anchor = False
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            raise ScopeError("invalid process snapshot")
        pid, group = int(fields[0]), int(fields[1])
        if group != anchor:
            # Linux can identify a new group in our session, but cannot safely
            # target its numeric PGID after its leader exits. Fail explicitly.
            raise ScopeError("command changed process group; cleanup is unverified")
        seen_anchor = seen_anchor or pid == anchor
        if pid != anchor and not fields[2].startswith("Z"):
            live.append(pid)
    if not seen_anchor:
        raise ScopeError("process snapshot omitted the unreaped scope anchor")
    return live, output


def reap_anchor(anchor):
    # No group lookup or signal may follow this function: wait releases the PID.
    end = time.monotonic() + REAP_SECONDS
    while True:
        found, _ = os.waitpid(anchor, os.WNOHANG)
        if found:
            return True
        if time.monotonic() >= end:
            return False
        time.sleep(POLL)


def supervise(limit, log_dir, command):
    cancelled = [0]

    def cancel(sig, _frame):
        if not cancelled[0]:
            cancelled[0] = sig

    for sig in CANCEL_SIGNALS:
        signal.signal(sig, cancel)
    parent, child = socket.socketpair()
    deadline = time.monotonic() + limit
    anchor = os.fork()
    if anchor == 0:
        parent.close()
        anchor_main(child, command)
        child.close()
        os._exit(0)
    child.close()
    parent.setblocking(False)
    ready = False
    released = False
    result = 125
    root_status = None
    buffer = b""
    reason = "supervisor failed"
    diagnostic = ""
    try:
        while True:
            if cancelled[0]:
                result, reason = 128 + cancelled[0], "watchdog cancelled"
                break
            if time.monotonic() >= deadline:
                result, reason = 124, "timed out after %gs" % limit
                break
            readable, _, _ = select.select([parent], [], [],
                                          min(POLL, max(0, deadline - time.monotonic())))
            if not readable:
                continue
            data = parent.recv(1024)
            if not data:
                raise ScopeError("scope anchor exited unexpectedly (or command could not exec)")
            buffer += data
            while b"\n" in buffer:
                message, buffer = buffer.split(b"\n", 1)
                if message == b"READY" and not ready:
                    ready = True
                    parent.sendall(b"G")
                elif message.startswith(b"EXIT ") and ready and root_status is None:
                    root_status = int(message[5:])
                else:
                    raise ScopeError("invalid scope anchor response")
            if root_status is not None:
                live, diagnostic = snapshot(anchor, time.monotonic() + QUERY_SECONDS + POLL)
                if cancelled[0]:
                    result, reason = 128 + cancelled[0], "watchdog cancelled"
                elif live:
                    result = root_status or 125
                    reason = "command exited %d but left live processes in its scope" % root_status
                else:
                    result = root_status
                    # No live command process remains, so nothing can fork.
                    # Kill our anchor before releasing its PID with waitpid.
                    signal_group(anchor, signal.SIGKILL)
                    released = True
                break
    except (OSError, ValueError, ScopeError) as exc:
        reason = str(exc)
    finally:
        if not released:
            end = time.monotonic() + CLEANUP_SECONDS
            print("::error::Watchdog: " + reason, flush=True)
            if ready:
                try:
                    if not diagnostic:
                        _, diagnostic = snapshot(anchor, end)
                except (OSError, ValueError, ScopeError) as exc:
                    diagnostic = "Snapshot unavailable: %s\n" % exc
                # Diagnostics share this absolute deadline; never one sample per
                # descendant. The group leader remains unreaped through KILL and
                # verification, even if it died unexpectedly before cleanup.
                signal_group(anchor, signal.SIGTERM)
                signal_group(anchor, signal.SIGCONT)
                time.sleep(min(TERM_SECONDS, max(0, end - time.monotonic())))
                signal_group(anchor, signal.SIGKILL)
                verified = False
                while time.monotonic() < end:
                    try:
                        live, _ = snapshot(anchor, end)
                        if not live:
                            verified = True
                            break
                    except (OSError, ValueError, ScopeError):
                        pass
                    time.sleep(min(POLL, max(0, end - time.monotonic())))
                if not verified:
                    print("::error::Watchdog: scope cleanup could not be verified", flush=True)
                    if result != 124 and not cancelled[0]:
                        result = 125
            else:
                # The anchor cannot launch a command before READY + our G reply.
                os.kill(anchor, signal.SIGKILL)
            try:
                (log_dir / "hung-processes.txt").write_text(
                    "Owned scope %d; %s\npid pgid state\n%s" % (anchor, reason, diagnostic),
                    encoding="utf-8")
            except OSError as exc:
                print("::error::Watchdog: cannot write diagnostic log: %s" % exc, flush=True)
        parent.close()
        if not reap_anchor(anchor):
            print("::error::Watchdog: anchor did not exit within the reap budget", flush=True)
            result = 125
    return 128 + cancelled[0] if cancelled[0] else result


def main(argv):
    if len(argv) < 4:
        print("Usage: run-with-watchdog.sh SECONDS LOG_DIR COMMAND [ARGS...]", file=sys.stderr)
        return 2
    try:
        limit = float(argv[1])
        if not math.isfinite(limit) or limit <= 0:
            raise ValueError("SECONDS must be positive and finite")
        log_dir = Path(argv[2])
        log_dir.mkdir(parents=True, exist_ok=True)
    except (OSError, ValueError) as exc:
        print("Watchdog: %s" % exc, file=sys.stderr)
        return 2
    return supervise(limit, log_dir, argv[3:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
