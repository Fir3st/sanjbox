import argparse
import json

from .validator import validate


def main():
    parser = argparse.ArgumentParser(description=(
        "Check selected sanitized LAB evidence without changing it. "
        "Consistency is not an acceptance verdict."))
    parser.add_argument("--root", required=True, help="absolute evidence root; no symlink components")
    parser.add_argument("--run", action="append", required=True, help="gate/canonical-run-id (repeatable)")
    parser.add_argument("--index", help="absolute path to the optional spikes.md index")
    parser.add_argument("--format", choices=("json", "text"), default="text")
    args = parser.parse_args()
    report = validate(args.root, args.run, args.index)
    if args.format == "json":
        print(json.dumps(report, ensure_ascii=True, indent=2, allow_nan=False))
    else:
        print("LAB evidence: " + report["structural_status"] + "; acceptance: unverified")
        for finding in report["findings"]:
            print("  {status}: {code}".format(**finding))
        for run in report["runs"]:
            print("{selection}: {structural_status}; acceptance: unverified".format(**run))
            print("  files: {files}; bytes: {bytes}; declared index verdicts: {verdicts}".format(
                files=run["files"], bytes=run["bytes"],
                verdicts=", ".join(record["declared_verdict"] for record in run["index_records"]) or "unknown"))
            for finding in run["findings"]:
                print("  {status}: {code}{path}".format(
                    **{**finding, "path": " (" + finding["path"] + ")" if finding.get("path") else ""}))
        print("Unverified: " + "; ".join(report["unverified_checks"]))
    # Exit zero certifies only completed structural checks, never a gate pass.
    return 0 if report["structural_status"] == "consistent" else 1


if __name__ == "__main__":
    raise SystemExit(main())
