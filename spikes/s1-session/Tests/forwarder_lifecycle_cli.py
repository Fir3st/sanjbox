#!/usr/bin/env python3
"""Bounded synthetic loopback checks; each CLI child is terminated and reaped.

Usage: python3 Tests/forwarder_lifecycle_cli.py /absolute/path/to/sanjbox-s1-forward
No VNC, Screen Sharing, process inventory, or non-loopback connections.
"""
import concurrent.futures
import contextlib
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import sys
import time

TIMEOUT = 4
PAYLOAD = bytes(range(256)) * 800  # Larger than the forwarder's 64 KiB copy buffer.


@contextlib.contextmanager
def bound_socket(listening=True):
    with socket.socket() as listener:
        listener.settimeout(TIMEOUT)
        listener.bind(("127.0.0.1", 0))
        if listening:
            listener.listen(4)
        yield listener


class Lines:
    def __init__(self, process):
        self.process = process
        self.pending = b""

    def read(self):
        deadline = time.monotonic() + TIMEOUT
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "forwarder output deadline"
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            assert ready, "forwarder output deadline"
            chunk = os.read(self.process.stdout.fileno(), 4096)
            assert chunk, "forwarder exited before expected output"
            self.pending += chunk
            assert len(self.pending) < 16384, "unexpected output volume"
        line, self.pending = self.pending.split(b"\n", 1)
        return line.decode("utf-8")


@contextlib.contextmanager
def forwarder(executable, target):
    process = subprocess.Popen(
        [executable, "--listen", "0", "--target", str(target)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    try:
        lines = Lines(process)
        banner = lines.read()
        match = re.fullmatch(
            r"forwarding 127\.0\.0\.1:(\d+) -> 127\.0\.0\.1:" + str(target)
            + r"; open vnc://127\.0\.0\.1:\1", banner,
        )
        assert match, banner
        yield process, lines, int(match.group(1))
        assert process.poll() is None, "forwarder unexpectedly exited"
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=TIMEOUT)
        process.stdout.close()


def receive(sock):
    data = bytearray()
    while chunk := sock.recv(65536):
        data += chunk
        assert len(data) <= 1_048_576, "unexpected payload volume"
    return bytes(data)


def send_and_half_close(sock, payload):
    sock.sendall(payload)
    sock.shutdown(socket.SHUT_WR)


def relay_case(executable, mode):
    with bound_socket() as listener:
        target_port = listener.getsockname()[1]
        with forwarder(executable, target_port) as (_, lines, port):
            with socket.create_connection(("127.0.0.1", port), TIMEOUT) as client:
                target, peer = listener.accept()
                with target:
                    assert peer[0] == "127.0.0.1"
                    target.settimeout(TIMEOUT)
                    response = PAYLOAD[::-1]
                    if mode == "duplex":
                        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                            tasks = [
                                pool.submit(send_and_half_close, client, PAYLOAD),
                                pool.submit(send_and_half_close, target, response),
                                pool.submit(receive, target),
                                pool.submit(receive, client),
                            ]
                            results = [task.result(timeout=TIMEOUT + 1) for task in tasks]
                        assert results[2:] == [PAYLOAD, response]
                    elif mode == "client-half-close":
                        # Reply starts only after the request's EOF crosses the forwarder.
                        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                            sent = pool.submit(send_and_half_close, client, PAYLOAD)
                            assert receive(target) == PAYLOAD
                            sent.result(timeout=TIMEOUT + 1)
                            replied = pool.submit(send_and_half_close, target, response)
                            assert receive(client) == response
                            replied.result(timeout=TIMEOUT + 1)
                    else:
                        # The reverse direction must remain writable after target EOF.
                        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                            sent = pool.submit(send_and_half_close, target, response)
                            assert receive(client) == response
                            sent.result(timeout=TIMEOUT + 1)
                            replied = pool.submit(send_and_half_close, client, PAYLOAD)
                            assert receive(target) == PAYLOAD
                            replied.result(timeout=TIMEOUT + 1)
                    report = lines.read()
                    assert report.endswith(
                        f"connection closed: {len(PAYLOAD)} bytes to target, {len(response)} bytes back"
                    ), report
        # After the child has exited, its listener must no longer own the port.
        with socket.socket() as rebound:
            rebound.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            rebound.bind(("127.0.0.1", port))
            rebound.listen(1)
    print(f"PASS {mode}")


def refused_target(executable):
    # Port 0 cannot host a TCP service, so this never contacts an unowned host service.
    # A bound-but-unlistening macOS TCP socket can instead leave connect pending.
    with forwarder(executable, 0) as (_, lines, port):
        for _ in range(4):
            with socket.create_connection(("127.0.0.1", port), TIMEOUT) as client:
                assert receive(client) == b""
            assert "cannot connect to 127.0.0.1:0:" in lines.read()
    print("PASS refused-target (4 connections)")


def explicit_self_target(executable):
    with bound_socket(listening=False) as reservation:
        port = reservation.getsockname()[1]
    result = subprocess.run(
        [executable, "--listen", str(port), "--target", str(port)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=TIMEOUT,
    )
    assert result.returncode == 2, result
    assert "self-target 127.0.0.1:" in result.stderr, result.stderr
    assert not result.stdout, result.stdout
    print("PASS explicit-self-target")


def main():
    executable = str(Path(sys.argv[1]).resolve(strict=True))
    explicit_self_target(executable)
    for mode in ("duplex", "client-half-close", "target-half-close"):
        relay_case(executable, mode)
    refused_target(executable)
    print("PASS 5/5 bounded forwarder CLI cases; all children reaped")


if __name__ == "__main__":
    main()
