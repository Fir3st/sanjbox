#!/usr/bin/env python3
"""Real CLI checks using only disabled/synthetic policy and IPv4 loopback.
Usage: python3 proto/gateway/Tests/listener_cli.py /absolute/path/to/sanjbox-gateway-service
"""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


def policy():
    return {
        "schemaVersion": 1, "zoneID": "zone-cli-fixture", "auditCapacity": 64,
        "gateways": [{"operation": "npm", "enabled": False, "mount": "/npm",
                      "publicOrigin": "http://127.0.0.1:18765",
                      "upstreamHostname": "registry.example", "artifactHostnames": [],
                      "cooldownSeconds": 3600,
                      "limits": {"metadataBytes": 4096, "artifactBytes": 4096, "files": 10,
                                 "operations": 1, "auditRecords": 16, "lifetimeSeconds": 1}}],
    }


class ListenerCLI(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="h4-cli-")
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "policy.json"
        self.path.write_text(json.dumps(policy()), encoding="utf-8")

    def run_cli(self, *arguments):
        return subprocess.run([BINARY, "--policy", str(self.path), *arguments],
                              text=True, capture_output=True, timeout=5, check=False)

    def test_default_composes_without_socket(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no socket opened", result.stdout)
        self.assertNotIn("listener ready:", result.stdout)

    def test_bind_collision_never_reports_ready(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen(1)
            result = self.run_cli("--listen", "127.0.0.1:%d" % occupied.getsockname()[1])
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertNotIn("listener ready:", result.stdout)
        self.assertEqual(result.stdout.count("listener stopped: bindFailed"), 1)

    def test_invalid_policy_and_listener_fail_before_ready(self):
        result = self.run_cli("--listen", "0.0.0.0:18765")
        self.assertEqual(result.returncode, 2)
        self.path.write_text(self.path.read_text().replace('"enabled": false',
                             '"enabled": false, "enabled": true'), encoding="utf-8")
        result = self.run_cli("--listen", "127.0.0.1:18765")
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("listener ready:", result.stdout)

    def test_public_origin_must_match_actual_listener(self):
        value = policy()
        value["gateways"][0]["enabled"] = True
        self.path.write_text(json.dumps(value), encoding="utf-8")
        result = self.run_cli("--listen", "127.0.0.1:1")
        self.assertEqual(result.returncode, 4)
        self.assertIn("originMismatch", result.stdout)
        self.assertNotIn("listener ready:", result.stdout)

    def test_live_cli_serves_rejects_malformed_and_releases_port_on_exit(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        process = subprocess.Popen([BINARY, "--policy", str(self.path), "--listen",
                                    "127.0.0.1:%d" % port], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)

        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            process.stdout.close()
        self.addCleanup(stop)
        output = b""
        deadline = time.monotonic() + 5
        while b"listener ready:" not in output and time.monotonic() < deadline:
            if select.select([process.stdout], [], [], 0.1)[0]:
                chunk = os.read(process.stdout.fileno(), 8192)
                if not chunk:
                    break
                output += chunk
        self.assertIn(b"listener ready:", output, output.decode(errors="replace"))

        def exchange(request):
            with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
                client.sendall(request)
                result = b""
                while True:
                    part = client.recv(8192)
                    if not part:
                        return result
                    result += part

        self.assertEqual(exchange(b"not-http\r\n\r\n"), b"")
        self.assertTrue(exchange(b"GET /npm/fixture HTTP/1.1\r\nHost: fixture.test\r\n\r\n")
                        .startswith(b"HTTP/1.1 403 "))
        with socket.create_connection(("127.0.0.1", port), timeout=2) as idle:
            process.terminate()
            process.wait(timeout=3)
            try:
                self.assertEqual(idle.recv(1), b"")
            except ConnectionResetError:
                pass
        with socket.socket() as replacement:
            replacement.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            replacement.bind(("127.0.0.1", port))
            replacement.listen(1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
