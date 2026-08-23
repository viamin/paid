# Design: TDD Test-Review PRs (RDR-056)

> Design notes for the red-phase PR behavior in RDR-056: test-writing runs
> publish or refresh a draft PR whose review surface shows the proposed tests
> and, for LID projects, the updated intent docs before implementation begins.

This segment covers issue #3467 of
[RDR-056](../../rdrs/RDR-056-strict-test-driven-development-mode.md). It builds
on the project-level mode/labels in [`tdd-mode`](../tdd-mode/tdd-mode-design.md)
and the run-scoped file boundary checks in
[`tdd-write-guards`](../tdd-write-guards/tdd-write-guards-design.md).

## What this segment owns

- Draft-PR publication for `test_writing` runs: when a TDD-governed run writes
  tests, Paid either creates the PR or refreshes the existing PR body after the
  push so the red-phase output is reviewable on GitHub instead of being trapped
  in run logs.
- Automatic application of `paid-tests-ready-for-review` on `test_writing`
  runs. The label marks the PR as waiting at the red-phase gate regardless of
  whether the project uses strict or non-strict TDD; non-strict mode will later
  replace it with an automated verdict.
- PR-body review sections derived mechanically from the run diff:
  - `## Test Outline` for any PR whose diff touches tests.
  - `## LID Phase Report` for LID-enabled projects, summarizing changed LID
    docs/spec IDs, tests-first evidence, and the captured coherence-check line.
- Refreshing those sections on existing-PR follow-up runs so later test-writing
  passes keep the draft PR current rather than leaving stale outlines in place.

## Test outline rendering

`PullRequests::ReviewSurface` reads the changed test files from the run's git
diff and renders a documentation-style summary without test bodies:

- RSpec-style suites (`describe`, `context`, `feature`) become nested headings.
- RSpec examples (`it`, `example`, `specify`, `scenario`) become leaf lines.
- Non-RSpec files fall back to the nearest structural equivalent:
  `class Test...`, `test "..."`, and `def test_...` forms are rendered as suite
  and example titles so pytest/minitest-style files still produce a useful map.

The formatter is intentionally structural, not semantic: it reads known test
declaration forms from the changed files and emits plain-text outline lines in a
fenced code block. No AI call is involved.

## Existing-PR refresh

`CompleteExistingPrRunActivity` already represents "the run pushed new commits
to an open PR." This segment extends that activity to refresh the PR body's
review sections after a successful push, so a second red-phase pass that changes
tests or LID docs updates the same draft PR in place instead of relying on a
comment.
