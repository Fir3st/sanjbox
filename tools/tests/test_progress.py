"""Regression checks for honest counting, Git history and safe static rendering."""

from copy import deepcopy
from html.parser import HTMLParser
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("progress", ROOT / "tools/progress.py")
progress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(progress)


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.coverage = (ROOT / "docs/COVERAGE.md").read_text(encoding="utf-8")
        self.implementation = (ROOT / "docs/IMPLEMENTATION.md").read_text(encoding="utf-8")

    def test_package_completion_does_not_pass_acceptance(self):
        data = progress.collect(self.coverage, self.implementation)
        self.assertTrue(any(p["state"] == "done" for p in data["packages"]))
        # Counts come from detail rows, independently of the hand-written summary.
        changed = self.coverage.replace("| Testové případy | 155 |", "| Testové případy | 999 |")
        self.assertEqual(progress.collect(changed, self.implementation)["summary"], data["summary"])
        self.assertEqual(data["summary"]["packages"]["total"], len(data["packages"]))
        self.assertEqual(data["summary"]["tests"]["done"], sum(t["state"] == "passed" for t in data["tests"]))
        self.assertEqual(data["summary"]["gates"]["total"], 10)
        self.assertEqual(sum(p["total"] for p in data["summary"]["phases"].values()), len(data["packages"]))

    def test_unknown_verdict_fails_instead_of_inventing_success(self):
        row = next(line for line in self.coverage.splitlines() if line.startswith("| GUI-01 |"))
        with self.assertRaisesRegex(ValueError, "Neznámý verdikt"):
            progress.collect(self.coverage.replace(row, row.replace("Neověřeno", "Skoro hotovo")), self.implementation)

    def test_unknown_package_state_fails(self):
        row = next(line for line in self.coverage.splitlines() if line.startswith("| WP0.2 |"))
        with self.assertRaisesRegex(ValueError, "neznámý stav balíku"):
            progress.collect(self.coverage.replace(row, row.replace("✅", "100%")), self.implementation)

    def test_passing_test_needs_evidence(self):
        changed = self.coverage.replace("| Neověřeno | |", "| Prošlo | |", 1)
        with self.assertRaisesRegex(ValueError, "Prošlo vyžaduje odkaz"):
            progress.collect(changed, self.implementation)

    def test_evidenced_case_changes_only_acceptance_counter(self):
        row = next(line for line in self.coverage.splitlines() if line.startswith("| GUI-01 |"))
        changed = self.coverage.replace(row, row.replace("| Neověřeno | |", "| Prošlo | [Protokol](evidence/S1/run/verdict.md) |"))
        before = progress.collect(self.coverage, self.implementation)
        after = progress.collect(changed, self.implementation)
        self.assertEqual(after["summary"]["tests"]["done"], before["summary"]["tests"]["done"] + 1)
        self.assertEqual(after["summary"]["gates"], before["summary"]["gates"])
        html = progress.render(after, [], "Example/project", "abc123", False)["index.html"]
        self.assertIn('href="https://github.com/Example/project/blob/abc123/docs/evidence/S1/run/verdict.md"', html)

    def test_unsafe_evidence_and_case_id_are_rejected(self):
        for target in ("javascript:alert", "//example.invalid/proof", "../../outside.md"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                progress.evidence_links(f"[Proof]({target})", "Example/project", "abc123")
        with self.assertRaisesRegex(ValueError, "Neplatné ID případu"):
            progress.collect(self.coverage.replace("| GUI-01 |", '| GUI-01"onclick="alert(1) |'), self.implementation)

    def test_requirement_cannot_pass_with_unverified_gates(self):
        changed = self.coverage.replace("| GUI-01…13, HB, DK, POS | Neověřeno |",
                                        "| GUI-01…13, HB, DK, POS | Prošlo |")
        with self.assertRaisesRegex(ValueError, "prošlé rozhodující brány"):
            progress.collect(changed, self.implementation)

    def test_missing_and_duplicate_rows_fail(self):
        row = next(line for line in self.coverage.splitlines() if line.startswith("| WP0.2 |"))
        with self.assertRaisesRegex(ValueError, "Duplicitní ID"):
            progress.collect(self.coverage.replace(row, row + "\n" + row), self.implementation)
        with self.assertRaisesRegex(ValueError, "neshodují"):
            progress.collect(self.coverage.replace(row + "\n", ""), self.implementation)

    def test_malformed_or_missing_section_fails(self):
        with self.assertRaisesRegex(ValueError, "buněk"):
            progress.collect(self.coverage.replace("| WP0.2 |", "| extra | WP0.2 |"), self.implementation)
        with self.assertRaisesRegex(ValueError, "sekce tests"):
            progress.collect(self.coverage.replace("## 3. Testové případy", "## Příklady"), self.implementation)

    def test_fenced_examples_and_escaped_pipes(self):
        text = "## Example\n```markdown\n| ID | Text |\n|---|---|\n| fake | no |\n```\n| ID | Text |\n|---|---|\n| real | a \\| b |"
        rows = list(progress.markdown_rows(text))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][3], {"ID": "real", "Text": "a | b"})

    def test_html_svg_escaping_and_static_fallback(self):
        data = progress.collect(self.coverage, self.implementation)
        data["packages"][0]["title"] = '<script>alert("x")</script>'
        pages = progress.render(data, [], "Fir3st/sanjbox", "a" * 40, True)
        html = pages["index.html"]
        self.assertNotIn('<script>alert', html)
        self.assertIn('&lt;script&gt;', html)
        self.assertNotIn("{{", html)
        self.assertIn("Lokální náhled", html)
        for record in data["packages"]:
            self.assertIn(f'id="package-{record["id"]}"', html)
        for record in data["tests"]:
            self.assertIn(f'id="test-{record["id"]}"', html)
        ET.fromstring(progress.overview_svg(data))


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run_git("init", "-b", "main")
        self.run_git("config", "user.name", "Progress Test")
        self.run_git("config", "user.email", "progress@example.invalid")
        (self.root / "docs").mkdir()
        self.coverage = (ROOT / "docs/COVERAGE.md").read_text(encoding="utf-8")
        (self.root / "docs/IMPLEMENTATION.md").write_text((ROOT / "docs/IMPLEMENTATION.md").read_text(encoding="utf-8"), encoding="utf-8")

    def run_git(self, *args, env=None):
        return subprocess.run(["git", "-C", str(self.root), *args], env=env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, date, coverage):
        (self.root / "docs/COVERAGE.md").write_text(coverage, encoding="utf-8")
        self.run_git("add", "docs")
        env = dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        self.run_git("commit", "--allow-empty", "-m", "Progress fixture", env=env)
        return self.run_git("rev-parse", "HEAD")

    def test_utc_daily_last_commit_and_scope_changes(self):
        # Both local dates land on the same UTC day. Only the latter is retained.
        self.commit("2026-10-30T23:30:00-0200", self.coverage)
        last = self.commit("2026-10-31T05:00:00+0100", self.coverage)
        row = next(line for line in self.coverage.splitlines() if line.startswith("| WP0.5 |"))
        changed = self.coverage.replace(row, row.replace("⬜", "✅"))
        self.commit("2026-11-02T12:00:00+0100", changed)
        records = progress.history(self.root, "HEAD")
        self.assertEqual([r["date"] for r in records], ["2026-10-31", "2026-11-02"])
        self.assertEqual(records[0]["commit"], last)
        self.assertEqual(records[1]["summary"]["packages"]["done"], records[0]["summary"]["packages"]["done"] + 1)
        self.assertEqual(records[1]["summary"]["tests"], records[0]["summary"]["tests"])

    def test_side_branch_activity_is_not_merged_progress(self):
        main = self.commit("2026-10-30T12:00:00Z", self.coverage)
        self.run_git("checkout", "-b", "work")
        self.commit("2026-10-31T12:00:00Z", self.coverage)
        self.run_git("checkout", "main")
        self.assertEqual([r["commit"] for r in progress.history(self.root, "main")], [main])

    def test_shallow_history_is_rejected(self):
        sha = self.commit("2026-11-01T12:00:00Z", self.coverage)
        (self.root / ".git/shallow").write_text(sha + "\n")
        with self.assertRaisesRegex(ValueError, "úplný checkout"):
            progress.history(self.root, "HEAD")

    def test_complete_build_has_consistent_artifacts_and_local_links(self):
        self.commit("2026-11-01T12:00:00Z", self.coverage)
        out = self.root / "public"
        data = progress.build(self.root, out, "Example/project")
        stored = json.loads((out / "progress.json").read_text())
        self.assertEqual(stored["summary"], data["summary"])
        self.assertEqual(len(json.loads((out / "history.json").read_text())["days"]), 1)
        self.assertEqual((out / "index.html").read_bytes(), (out / "progress.html").read_bytes())
        self.assertTrue((out / ".nojekyll").is_file())
        ET.parse(out / "progress.svg")

        class Links(HTMLParser):
            def __init__(self):
                super().__init__()
                self.targets, self.ids = [], set()

            def handle_starttag(self, tag, attrs):
                attrs = dict(attrs)
                if "id" in attrs:
                    self.ids.add(attrs["id"])
                for name in ("href", "src"):
                    if name in attrs:
                        self.targets.append(attrs[name])

        for name in ("index.html", "history.html"):
            parser = Links()
            parser.feed((out / name).read_text())
            for url in parser.targets:
                if url.startswith("https:"):
                    self.assertIn("Example/project", url)
                elif url.startswith("#"):
                    self.assertIn(url[1:], parser.ids)
                else:
                    self.assertTrue((out / url).is_file(), url)

    def test_chart_uses_elapsed_days_and_handles_single_point(self):
        data = progress.collect(self.coverage, (ROOT / "docs/IMPLEMENTATION.md").read_text())
        records = [{"date": date, "summary": deepcopy(data["summary"])} for date in ("2026-10-01", "2026-10-02", "2026-10-11")]
        svg = progress.chart(records, "packages", "Progress")
        self.assertIn('cx="107.60"', svg)  # One day of a ten-day span, not half the width.
        ET.fromstring(svg)
        ET.fromstring(progress.chart(records[:1], "packages", "One point"))


if __name__ == "__main__":
    unittest.main()
