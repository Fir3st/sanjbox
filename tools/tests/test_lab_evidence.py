"""Synthetic LAB evidence: content integrity, bounded reads, and honest limits."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from tools.lab_evidence import validator as lab

ROOT = Path(__file__).resolve().parents[2]
RUN_A = "20261104T120000Z-alice-LAB-alice-01-r1-1234abcd"
RUN_B = "20261104T120001Z-bob-LAB-bob-02-r2-5678abcd"


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sanjbox-wp05-test-")
        self.addCleanup(self.temp.cleanup)
        # macOS /var is a symlink; only our own freshly created scratch is resolved.
        self.scratch = Path(self.temp.name).resolve()
        self.root = self.scratch / "evidence"
        self.selection = "s1/" + RUN_A
        self.run = self.make_run(self.selection)

    def make_run(self, selection):
        run = self.root / selection
        (run / "raw").mkdir(parents=True)
        (run / "reviews").mkdir()
        (run / "inputs").mkdir()
        (run / "environment.md").write_text("Synthetic lab fixture.\n")
        (run / "inputs.md").write_text("Synthetic preregistration, no measurement.\n")
        (run / "credentials.log").write_text("SYNTHETIC-PROBE-METADATA-DO-NOT-ECHO\n")
        (run / "verdict.md").write_text("Neověřeno. [raw](raw/sample.json)\n")
        (run / "raw/sample.json").write_text('{"mock":true,"result":"unknown"}\n')
        (run / "reviews/review.md").write_text("Synthetic review. [verdict](../verdict.md)\n")
        self.manifest(run)
        return run

    def manifest(self, run=None):
        run = run or self.run
        entries = []
        for path in sorted(run.rglob("*")):
            if path.is_file() and path.name != "manifest.sha256":
                entries.append(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.relative_to(run).as_posix())
        (run / "manifest.sha256").write_text("\n".join(entries) + "\n")

    def check(self, selections=None, index=None):
        return lab.validate(str(self.root), selections or [self.selection], str(index) if index else None)

    def codes(self, result):
        return {f["code"] for r in [result] + result["runs"] for f in r["findings"]}

    def assert_code(self, result, code):
        self.assertIn(code, self.codes(result))
        self.assertNotEqual(result["structural_status"], "consistent")
        self.assertEqual(result["acceptance"], "unverified")

    def index(self, rows):
        path = self.scratch / "spikes.md"
        path.write_text("## S1 — Synthetic\n\n" + "\n".join(rows) + "\n")
        return path

    def row(self, run_id=RUN_A, verdict="Neověřeno", suffix=""):
        return ("| 2026-11-04T12:00:00Z / " + run_id + " | běh: mock | fixture | synthetic configuration | "
                + verdict + " | [proof](evidence/s1/" + run_id + "/verdict.md)" + suffix + " |")

    def test_consistent_fixture_is_unverified_and_bytes_unchanged(self):
        before = {p: p.read_bytes() for p in self.run.rglob("*") if p.is_file()}
        report = self.check(index=self.index([self.row()]))
        self.assertEqual(report["structural_status"], "consistent")
        self.assertEqual(report["acceptance"], "unverified")
        self.assertEqual(report["runs"][0]["index_records"][0]["declared_verdict"], "Neověřeno")
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertNotIn("SYNTHETIC-PROBE-METADATA-DO-NOT-ECHO", json.dumps(report))
        self.assertNotIn(str(self.root), json.dumps(report))
        self.assertTrue(any("calibration" in item for item in report["unverified_checks"]))

    def test_manifest_hash_tampering(self):
        (self.run / "raw/sample.json").write_text('{"mock":false}\n')
        self.assert_code(self.check(), "hash_mismatch")

    def test_unmanifested_review_and_extra_data_are_not_silently_ignored(self):
        for path in ("reviews/later.md", "raw/extra.json"):
            (self.run / path).write_text("{}\n")
        result = self.check()
        self.assert_code(result, "unmanifested_file")
        self.assertEqual(sum(f["code"] == "unmanifested_file" for f in result["runs"][0]["findings"]), 2)

    def test_missing_file_is_missing_not_failed_measurement(self):
        (self.run / "inputs.md").unlink()
        report = self.check()
        self.assertEqual(report["structural_status"], "missing")
        self.assert_code(report, "required_file_missing")
        self.assert_code(report, "manifest_file_missing")

    def test_missing_run_and_manifest_do_not_succeed(self):
        self.assert_code(self.check(["s1/" + RUN_B]), "selected_path_missing")
        (self.run / "manifest.sha256").unlink()
        self.assert_code(self.check(), "required_file_missing")

    def test_empty_required_file_raw_or_review_is_a_gap(self):
        (self.run / "credentials.log").write_bytes(b"")
        (self.run / "raw/sample.json").unlink()
        (self.run / "reviews/review.md").unlink()
        self.manifest()
        report = self.check()
        for code in ("required_file_empty", "raw_evidence_missing", "review_evidence_missing"):
            self.assert_code(report, code)

    def test_duplicate_self_and_noncanonical_manifest_entries(self):
        original = (self.run / "manifest.sha256").read_text()
        bad = [original + original.splitlines()[0] + "\n",
               original + "0" * 64 + "  manifest.sha256\n"]
        for source in bad:
            with self.subTest(source=source[-90:]):
                (self.run / "manifest.sha256").write_text(source)
                self.assert_code(self.check(), "duplicate_or_self_manifest_entry")
        for path in ("../outside", "/outside", "raw//sample.json", "raw/./sample.json", "raw/../sample.json",
                     "raw\\sample.json", "raw/%2e%2e", "raw/é.json"):
            with self.subTest(path=path):
                (self.run / "manifest.sha256").write_text(original + "0" * 64 + "  " + path + "\n")
                self.assert_code(self.check(), "unsafe_path")

    def test_malformed_or_truncated_manifest(self):
        for text in ("0" * 64 + " raw/sample.json\n", "A" * 64 + "  raw/sample.json\n", "# comment\n"):
            (self.run / "manifest.sha256").write_text(text)
            self.assert_code(self.check(), "malformed_manifest")
        (self.run / "manifest.sha256").write_text("0" * 64 + "  raw/sample.json")
        self.assert_code(self.check(), "incomplete_manifest")

    def test_canonical_selection_and_duplicate_ids(self):
        for selection in ("s1/../" + RUN_A, "s1//" + RUN_A, "/s1/" + RUN_A, "s9/" + RUN_A,
                          "s1/" + RUN_A.replace("1104", "0230")):
            with self.subTest(selection=selection):
                self.assertNotEqual(self.check([selection])["structural_status"], "consistent")
        for selected in ([self.selection, self.selection], [self.selection, "s0/" + RUN_A]):
            self.assert_code(self.check(selected), "duplicate_selected_run_id")

    def test_revision_aliases_and_hex_case_preserve_original_run_id(self):
        revised = RUN_B.replace("-r2-", "-baseline-A-").replace("abcd", "ABCD")
        self.make_run("s1/" + revised)
        report = self.check(["s1/" + revised])
        self.assertEqual(report["structural_status"], "consistent")
        self.assertEqual(report["runs"][0]["selection"], "s1/" + revised)
        self.assert_code(self.check(["s1/" + revised, "s1/" + revised.lower().replace("t", "T", 1).replace("z", "Z", 1)]),
                         "duplicate_selected_run_id")

    def test_links_stay_within_run_and_missing_links_are_gaps(self):
        (self.run / "reviews/review.md").write_text("[ok](../raw/sample.json)\n")
        self.manifest()
        self.assertEqual(self.check()["structural_status"], "consistent")
        for target in ("../../outside.md", "/etc/passwd", "file:///etc/passwd", "raw/%2e%2e/x",
                       "raw/../inputs.md", "raw//sample.json", "raw\\sample.json", "//example.invalid/x"):
            with self.subTest(target=target):
                (self.run / "verdict.md").write_text("[bad](" + target + ")\n")
                self.manifest()
                self.assertNotEqual(self.check()["structural_status"], "consistent")
        (self.run / "verdict.md").write_text("[missing](raw/missing.json)\n")
        self.manifest()
        self.assert_code(self.check(), "linked_file_missing")

    def test_unsupported_and_malformed_markdown_never_succeed(self):
        for source, code in (("[bad](raw/sample.json\n", "malformed_markdown_link"),
                             ("[x][ref]\n[ref]: raw/sample.json\n", "unsupported_markdown_links"),
                             ('<a href="raw/sample.json">x</a>\n', "unsupported_markdown_links"),
                             ("[x](inputs.md#unknown)\n", "fragment_not_verified"),
                             ("```\n", "unclosed_markdown_fence")):
            with self.subTest(code=code):
                (self.run / "verdict.md").write_text(source)
                self.manifest()
                self.assert_code(self.check(), code)

    def test_duplicate_nested_json_keys_nonfinite_and_malformed_json(self):
        for source, code in (('{"a":{"x":1,"x":2}}', "duplicate_json_key"),
                             ('{"value":NaN}', "nonfinite_json"),
                             ('{"value":1e999}', "nonfinite_json"),
                             ('{"x":', "malformed_json")):
            with self.subTest(code=code):
                (self.run / "raw/sample.json").write_text(source)
                self.manifest()
                self.assert_code(self.check(), code)

    def test_json_nesting_nodes_and_size_are_bounded(self):
        (self.run / "raw/sample.json").write_text("[" * 40 + "0" + "]" * 40)
        self.manifest()
        self.assert_code(self.check(), "json_depth_limit")
        (self.run / "raw/sample.json").write_text("[1,2,3,4,5]")
        self.manifest()
        with mock.patch.object(lab, "MAX_JSON_NODES", 4):
            self.assert_code(self.check(), "json_node_limit")
        with mock.patch.object(lab, "MAX_JSON_BYTES", 4):
            self.assert_code(self.check(), "text_size_limit")

    def test_invalid_utf8_is_reported_without_content(self):
        (self.run / "raw/sample.json").write_bytes(b"\xffSYNTHETIC-UNPRINTABLE")
        self.manifest()
        report = self.check()
        self.assert_code(report, "invalid_utf8")
        self.assertNotIn("SYNTHETIC-UNPRINTABLE", json.dumps(report))

    def test_run_id_inside_json_is_bound_to_selected_directory(self):
        (self.run / "raw/sample.json").write_text(json.dumps({"run_id": RUN_B}))
        self.manifest()
        self.assert_code(self.check(), "run_id_mismatch")

    def test_planned_attempt_references_keep_missing_and_extra_attempts(self):
        (self.run / "inputs/preregistration.json").write_text(json.dumps({"run_id": RUN_A, "planned_attempts": 2}))
        (self.run / "raw/attempt-03.json").write_text("{}")
        self.manifest()
        report = self.check()
        self.assert_code(report, "planned_attempt_file_missing")
        self.assert_code(report, "unplanned_attempt_file")

    def test_planned_attempt_number_cannot_be_bool_or_unbounded(self):
        for count in (True, 0, 101, "3"):
            (self.run / "inputs/preregistration.json").write_text(json.dumps({"run_id": RUN_A, "planned_attempts": count}))
            self.manifest()
            self.assert_code(self.check(), "invalid_planned_attempts")

    def test_legacy_publication_hashes_and_review_reference(self):
        (self.run / "inputs/expect-host.json").write_text("{}\n")
        (self.run / "raw/attempt-01.json").write_text("{}\n")
        digest = hashlib.sha256(b"{}\n").hexdigest()
        pub = {"expectation_published_sha256": digest,
               "attempts": [{"attempt": 1, "published_sanitized_sha256": digest}]}
        (self.run / "raw/publication.json").write_text(json.dumps(pub))
        (self.run / "raw/seal.json").write_text('{"review":"reviews/review.md"}')
        self.manifest()
        self.assertEqual(self.check()["structural_status"], "consistent")
        pub["attempts"][0]["published_sanitized_sha256"] = "0" * 64
        (self.run / "raw/publication.json").write_text(json.dumps(pub))
        self.manifest()
        self.assert_code(self.check(), "publication_hash_mismatch")
        pub["attempts"].append(pub["attempts"][0])
        (self.run / "raw/publication.json").write_text(json.dumps(pub))
        self.manifest()
        self.assert_code(self.check(), "duplicate_or_invalid_publication_attempt")
        (self.run / "raw/seal.json").write_text('{"review":"../outside.md"}')
        self.manifest()
        self.assert_code(self.check(), "unsafe_path")

    def test_source_references_never_open_repository_or_private_files(self):
        document = {"run_id": RUN_A, "source_sha256": {"spikes/unavailable.swift": "0" * 64}}
        (self.run / "inputs/preregistration.json").write_text(json.dumps(document))
        self.manifest()
        self.assertEqual(self.check()["structural_status"], "consistent")
        document["source_sha256"] = {"../outside": "0" * 64}
        (self.run / "inputs/preregistration.json").write_text(json.dumps(document))
        self.manifest()
        self.assert_code(self.check(), "unsafe_path")

    def test_symlink_root_ancestor_run_directory_and_file_are_rejected(self):
        alias = self.scratch / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assert_code(lab.validate(str(alias), [self.selection]), "unsafe_directory")
        parent_alias = self.scratch / "parent-alias"
        parent_alias.symlink_to(self.scratch, target_is_directory=True)
        self.assert_code(lab.validate(str(parent_alias / "evidence"), [self.selection]), "unsafe_directory")
        (self.root / "s1" / RUN_B).symlink_to(self.run, target_is_directory=True)
        self.assert_code(self.check(["s1/" + RUN_B]), "unsafe_directory")
        path = self.run / "raw/link.json"
        path.symlink_to(self.run / "raw/sample.json")
        self.assert_code(self.check(), "unsafe_file_type_or_hardlink")
        path.unlink()
        (self.run / "raw/linked-directory").symlink_to(self.run / "inputs", target_is_directory=True)
        self.assert_code(self.check(), "unsafe_file_type_or_hardlink")

    def test_hardlinks_fifo_and_case_aliases_are_rejected(self):
        path = self.run / "raw/hard.json"
        os.link(self.run / "raw/sample.json", path)
        self.assert_code(self.check(), "unsafe_file_type_or_hardlink")
        path.unlink()
        fifo = self.run / "raw/pipe"
        os.mkfifo(fifo)
        self.assert_code(self.check(), "unsafe_file_type_or_hardlink")
        fifo.unlink()
        # Distinct files with case-only aliases cannot be created on every volume.
        alias = self.run / "raw/SAMPLE.json"
        alias.write_text("{}")
        if len([p for p in (self.run / "raw").iterdir() if p.name.lower() == "sample.json"]) == 2:
            self.assert_code(self.check(), "ambiguous_case_names")
        else:
            self.assert_code(self.check(), "hash_mismatch")

    def test_prohibited_names_are_rejected_before_open_and_not_echoed(self):
        original = os.open
        for name in (".env", "access-token.json", "private.key", "certificate.pem", "credentials-extra.log", "live.sqlite"):
            path = self.run / "raw" / name
            path.touch()  # Empty synthetic stand-in; never populate/read a secret.
            opened = []
            def checked_open(target, *args, **kwargs):
                opened.append(target)
                return original(target, *args, **kwargs)
            with mock.patch.object(lab.os, "open", side_effect=checked_open):
                report = self.check()
            self.assertNotEqual(report["structural_status"], "consistent")
            self.assertNotIn(name, opened)
            self.assertNotIn(name, json.dumps(report))
            path.unlink()

    def test_limits_fail_closed_without_large_fixtures(self):
        for name, value, code in (("MAX_FILE_BYTES", 4, "file_size_limit"),
                                  ("MAX_TOTAL_BYTES", 4, "total_size_limit"),
                                  ("MAX_ENTRIES", 2, "entry_count_limit"),
                                  ("MAX_DEPTH", 0, "depth_limit")):
            with self.subTest(name=name), mock.patch.object(lab, name, value):
                self.assert_code(self.check(), code)
        with mock.patch.object(lab, "MAX_RUNS", 1):
            self.assert_code(self.check([self.selection, "s1/" + RUN_B]), "selection_count_limit")

    def test_missing_safety_capability_is_unknown_not_success(self):
        with mock.patch.object(lab, "supported", return_value=False):
            report = self.check()
        self.assertEqual(report["structural_status"], "unknown")
        self.assert_code(report, "unsupported_read_safety_platform")

    def test_metadata_permission_error_is_unknown_not_success(self):
        original = lab.os.stat
        def denied(name, *args, **kwargs):
            if name == "sample.json":
                raise PermissionError("DO-NOT-ECHO")
            return original(name, *args, **kwargs)
        # supported() compares callable identities; check support before injecting IO.
        with mock.patch.object(lab, "supported", return_value=True), mock.patch.object(lab.os, "stat", side_effect=denied):
            report = self.check()
        self.assert_code(report, "read_or_metadata_error")
        self.assertEqual(report["structural_status"], "unknown")
        self.assertNotIn("DO-NOT-ECHO", json.dumps(report))

    def test_file_replacement_after_read_is_detected_even_with_same_bytes(self):
        original = lab.Reader.read_file
        def replace(reader, parent, name, before, path):
            data = original(reader, parent, name, before, path)
            if path == "raw/sample.json":
                replacement = self.run / "raw/replacement"
                replacement.write_bytes(data)
                replacement.replace(self.run / path)
            return data
        with mock.patch.object(lab.Reader, "read_file", replace):
            self.assert_code(self.check(), "concurrent_change")

    def test_in_place_change_and_short_read_are_detected(self):
        original = lab.os.read
        changed = False
        def read_and_change(fd, length):
            nonlocal changed
            data = original(fd, length)
            if not changed and data.startswith(b"SYNTHETIC-PROBE"):
                changed = True
                with (self.run / "credentials.log").open("ab") as output:
                    output.write(b"change")
            return data
        with mock.patch.object(lab.os, "read", side_effect=read_and_change):
            self.assert_code(self.check(), "concurrent_change")
        with mock.patch.object(lab.os, "read", return_value=b""):
            self.assert_code(self.check(), "incomplete_read")

    def test_replaced_run_ancestor_is_detected(self):
        original = lab.check_run
        def replace(files, report, run_id):
            original(files, report, run_id)
            self.run.rename(self.run.with_name(RUN_A + "-moved"))
            self.run.mkdir()
        with mock.patch.object(lab, "check_run", side_effect=replace):
            self.assert_code(self.check(), "concurrent_change")

    def test_multiple_machines_and_conflicting_outcomes_remain_independent(self):
        other = self.make_run("s1/" + RUN_B)
        (other / "verdict.md").write_text("Neprošlo: synthetic example.\n")
        self.manifest(other)
        index = self.index([self.row(verdict="Prošlo"), self.row(RUN_B, "Neprošlo")])
        report = self.check([self.selection, "s1/" + RUN_B], index)
        self.assertEqual(report["structural_status"], "consistent")
        self.assertEqual([r["index_records"][0]["declared_verdict"] for r in report["runs"]], ["Prošlo", "Neprošlo"])
        self.assertTrue(all(r["acceptance"] == "unverified" for r in report["runs"]))
        self.assertEqual(len(report["runs"]), 2)

    def test_index_missing_duplicate_wrong_gate_and_target(self):
        self.assert_code(self.check(index=self.index([])), "index_run_missing")
        self.assert_code(self.check(index=self.index([self.row(), self.row()])), "duplicate_index_run")
        index = self.index([self.row()])
        index.write_text(index.read_text().replace("## S1", "## S0"))
        self.assert_code(self.check(index=index), "index_gate_mismatch")
        self.assert_code(self.check(index=self.index([self.row().replace("/verdict.md", "/absent.md")])), "index_target_missing")

    def test_index_malformed_links_and_unknown_outcomes(self):
        self.assert_code(self.check(index=self.index([self.row(verdict="Almost")])), "unknown_or_ambiguous_index_verdict")
        self.assert_code(self.check(index=self.index([self.row().replace("/verdict.md", "/../outside")])), "unsafe_path")
        self.assert_code(self.check(index=self.index([self.row().replace(" | fixture |", " | fixture | extra |")])), "malformed_index_row")

    def test_index_reviews_do_not_overwrite_original_claim(self):
        review = self.row(verdict="Nejasné").replace("běh: mock", "review")
        report = self.check(index=self.index([self.row(), review]))
        self.assert_code(report, "conflicting_index_claims_require_review")
        self.assertEqual([r["declared_verdict"] for r in report["runs"][0]["index_records"]], ["Neověřeno", "Nejasné"])

    def test_new_run_reference_to_old_run_does_not_duplicate_or_overwrite_it(self):
        self.make_run("s1/" + RUN_B)
        link = "; [earlier](evidence/s1/" + RUN_A + "/verdict.md)"
        index = self.index([self.row(), self.row(RUN_B, "Neprošlo", link)])
        report = self.check([self.selection, "s1/" + RUN_B], index)
        self.assertEqual(report["structural_status"], "consistent")
        self.assertEqual([r["declared_verdict"] for r in report["runs"][0]["index_records"]], ["Neověřeno"])

    def test_null_known_structured_documents_are_malformed(self):
        for path, code in (("inputs/preregistration.json", "malformed_preregistration"),
                           ("raw/seal.json", "malformed_review_reference"),
                           ("raw/publication.json", "malformed_publication")):
            with self.subTest(path=path):
                (self.run / path).write_text("null")
                self.manifest()
                self.assert_code(self.check(), code)
                (self.run / path).unlink()

    def test_report_and_reference_counts_are_bounded(self):
        (self.run / "verdict.md").write_text("[x](absent.md)\n" * 20)
        self.manifest()
        with mock.patch.object(lab, "MAX_FINDINGS", 3):
            report = self.check()
        self.assert_code(report, "finding_limit")
        self.assertEqual(len(report["runs"][0]["findings"]), 4)
        with mock.patch.object(lab, "MAX_REFERENCES", 2):
            self.assert_code(self.check(), "reference_count_limit")

    def test_fifo_replacement_before_open_never_reads_or_blocks(self):
        original = lab.os.open
        def replace(name, *args, **kwargs):
            if name == "credentials.log":
                (self.run / name).unlink()
                os.mkfifo(self.run / name)
            return original(name, *args, **kwargs)
        with mock.patch.object(lab, "supported", return_value=True), \
                mock.patch.object(lab.os, "open", side_effect=replace), \
                mock.patch.object(lab.os, "read", side_effect=AssertionError("must not read FIFO")):
            self.assert_code(self.check(), "concurrent_change")

    def test_index_symlink_and_concurrent_replacement_are_rejected(self):
        index = self.index([self.row()])
        actual = self.scratch / "original.md"
        index.rename(actual)
        index.symlink_to(actual)
        self.assert_code(self.check(index=index), "unsafe_file_type_or_hardlink")
        index.unlink()
        actual.rename(index)
        original = lab.check_index
        def replace(*args):
            original(*args)
            replacement = self.scratch / "replacement.md"
            replacement.write_bytes(index.read_bytes())
            replacement.replace(index)
        with mock.patch.object(lab, "check_index", side_effect=replace):
            self.assert_code(self.check(index=index), "concurrent_index_change")

    def test_index_records_references_and_record_types_are_bounded(self):
        rows = [self.row(), self.row().replace("běh: mock", "review")]
        with mock.patch.object(lab, "MAX_REFERENCES", 1):
            self.assert_code(self.check(index=self.index(rows)), "index_record_limit")
        links = "; [second](evidence/" + self.selection + "/inputs.md)"
        with mock.patch.object(lab, "MAX_REFERENCES", 3):
            self.assert_code(self.check(index=self.index([self.row(suffix=links), rows[1] + "\n" + rows[1]])),
                             "index_reference_limit")
        bad = self.row().replace("běh: mock", "běh-invalid")
        self.assert_code(self.check(index=self.index([bad])), "unknown_index_record_type")

    def test_cli_json_text_exit_codes_and_no_writes(self):
        command = [sys.executable, "-B", "-m", "tools.lab_evidence", "--root", str(self.root), "--run", self.selection]
        result = subprocess.run(command + ["--format", "json"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["acceptance"], "unverified")
        (self.run / "raw/sample.json").write_text("{}")
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("hash_mismatch", result.stdout)
        self.assertNotIn("SYNTHETIC-PROBE-METADATA-DO-NOT-ECHO", result.stdout)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
