# C3 independent-review correction validation

Measured fixed source: `608b41cc308ffa6d6fb530f24bc3a899537e0411`.
Previous measured source: `926e106f24f1366af103544b546ad10db58efdf0`; its measurements are not relabeled or claimed rerun here.
This is offline instrument validation, not S3b/L4/isolation or performance evidence.

The independent review found three P2 defects: forged completion at the contact limit;
forged complete TCP EOF at exactly 4096 bytes; and unchecked sequence addition trapping at
Int.max. `review-counterexamples/` preserves reviewer reproductions and outcomes, including
SIGTRAP/no report. These are explicitly synthetic inputs, not producer measurements.

The fix follows unchanged common Receiver.swift: reaching maximumContacts is incomplete at
equality; TCP stops at 4096 before checking EOF. Sequence range is checked before addition.
Every decoded contact survives these errors with an invalid/incomplete-source marker.

- 63/63 native Release Swift Testing functions passed, with 12 focused cases across three new functions.
- Four exact reviewer inputs now return reports, retain all 4/2/2/2 contact findings, and flag source incompleteness. Exact input/stdout/stderr and hashes are in `review-fixed/`.
- Valid controls cover contacts below the limit, complete TCP 4095, and untruncated UDP 4096; truthful incomplete TCP 4096 remains incomplete.
- Int.min, Int.min+1, Int.max-1 and Int.max mutations return reports without trapping.
- 30/30 network CLI and 25/25 unchanged legacy CLI checks passed.
- 61/61 selected original producer hashes across nine historical cases still match.
- Source-only base-to-HEAD whitespace check returned 0. Full-branch check returned the expected 2 for five preserved compiler-diagnostic whitespace lines; exact output is retained. The previous clean-working-tree check was not a full-branch proof.

`inputs.json` is a labeled publication derivative of the preregistered private input record.
`commands.json` records actual commands and exit codes; `logs/` retains outputs. `publication.json`
maps private originals to published diagnostics with hashes and a worktree-prefix replacement
map. No newly failed test or build occurred. Environment and binary hash are in `environment.json`;
cleanup removed only this worker's new build/cache directories.

The old sealed 114-file record and original manifest remain byte-identical, including in the
private archive. In-place diagnostic sanitation was rejected by automatic approval review;
`logs/approval-review-rejection.txt` records the reason and safe alternative. Separate labeled
sanitized copies are under `../../publication/20261106-review-diagnostic-derivatives-926e106/`.
The historical original record still contains the two original home-path diagnostics; final
public-bundle packaging remains for the parent. No history or original evidence was rewritten.
All original producer journals, 61 imported files and the 352-file publication remain unchanged.
Independent peer authentication, capture completeness, external clock bounds, bind policy and
real testArea/L4 remain required. S3b/NET-10…12 remain Neověřeno.
