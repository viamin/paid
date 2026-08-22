# Design: Run-Scoped TDD Write Guards (RDR-056)

> Design notes for enforcing per-phase file-change boundaries on TDD-governed
> agent runs, and the refactor/mutation-phase sequencing that depends on
> those boundaries. Code is compiled output that may be regenerated from this
> spec plus the EARS claims in `tdd-write-guards-specs.md`.

This segment covers issue #3469 of
[RDR-056](../../rdrs/RDR-056-strict-test-driven-development-mode.md): rejecting
agent runs that alter files outside their TDD phase's allowed boundary, and
sequencing mutation checks to run only after tests are frozen. It builds on
the `Project#tdd_mode` configuration and labels from
[`tdd-mode`](../tdd-mode/tdd-mode-design.md) (#3466).

## What this segment owns

- An `AgentRun#tdd_phase` attribute with three values: `test_writing`,
  `test_fixing`, `refactor`. `nil` means the run is not TDD-governed (mirrors
  pre-existing behavior for `tdd_mode: "off"` projects and non-TDD goals).
- `Tdd::WriteGuard`, a pure structural check that classifies a run's changed
  files against its phase's allowed boundary:
  - `test_writing` may change test files and LID docs, never implementation
    code.
  - `test_fixing` may change implementation code; it may only change tests
    if the run has already returned the PR to test review.
  - `refactor` may change implementation code; it may never change tests.
- Wiring that check into `CreatePullRequestActivity`, the existing choke
  point where `lid_planning` and `create_feature` goals already validate
  their own changed-file boundaries via the GitHub compare API. The guard
  runs for every TDD-governed run regardless of goal, so a mutation-driven
  fix is held to the same boundary as a manual edit.
- `Tdd::ReturnToTestReview`, the single legitimate path for a `test_fixing`
  run to unlock test edits mid-run: it swaps `paid-tests-approved` for
  `paid-tests-ready-for-review` on the PR and records
  `agent_run.tdd_returned_to_test_review = true` in the same call, so the
  flag can never be set without the PR actually being sent back for human/
  agent re-review.
- Gating `Containers::QualityHooks#install_quality_hooks` so the mutation
  pre-commit check is skipped during `test_writing` — there is no
  implementation yet to mutate, and running mutant against freshly-written
  tests before they are reviewed would only produce noise.

## What this segment does NOT own

- The test-writing goal/focus on `AgentRun` and the run path that opens
  tests-only draft PRs (issue #3467).
- The queue/dispatch rule that blocks implementation runs while
  `paid-tests-ready-for-review` or `paid-test-changes-requested` is present
  without `paid-tests-approved`, i.e. "implementation begins only after
  approved tests exist" as a *pre-run* gate (issue #3468). This segment only
  enforces the boundary *within* a run that has already started.
- The `test_review` agent verdict for non-strict mode.
- Keeping the refactor phase's test suite green — that is an execution-time
  outcome enforced by the container's existing test pre-commit hook
  (`Containers::QualityHooks`/`Containers::GitOperations`), not a new check
  owned by this segment. This segment only ensures refactor runs cannot
  *edit* tests to make them pass; the pre-existing test hook still runs them.

## Schema

`agent_runs.tdd_phase` is a nullable string column with no database default
— most runs are not TDD-governed, so `nil` (not an "off" sentinel) is the
natural absence value, consistent with other optional `AgentRun` attributes.
`agent_runs.tdd_returned_to_test_review` is a non-null boolean defaulting to
`false`.

```ruby
add_column :agent_runs, :tdd_phase, :string,
  comment: "RDR-056 TDD phase governing this run's write boundary: test_writing | test_fixing | refactor"
add_column :agent_runs, :tdd_returned_to_test_review, :boolean,
  default: false, null: false,
  comment: "RDR-056: true once a test_fixing run has swapped the PR back to paid-tests-ready-for-review, unlocking test edits for the rest of the run"
```

## Write guard evaluation

`Tdd::WriteGuard.call(agent_run:, changed_files:)` is a pure function over
the run's `tdd_phase`, `tdd_returned_to_test_review` flag, and a flat list of
changed file paths — no I/O, no AI judgment (Zero Framework Cognition: this
is a structural policy check, not a semantic one). File classification
mirrors `CreatePullRequestActivity#changed_test_files`'s test-path
convention (`spec/`, `test/`, `.ephemeral-tests/`) and the LID doc allowlist
already used for `lid_planning` runs (`docs/`, `AGENTS.md`, `CLAUDE.md`,
`.github/copilot-instructions.md`), so the three checks in
`CreatePullRequestActivity` agree on what counts as a test file or a LID doc.

The result carries `forbidden_files` (not just a boolean) so the caller can
produce an actionable error message naming the specific paths that violated
the boundary, matching the existing `lid_planning`/`create_feature`
violation-reporting style.

## Return-to-test-review sequencing

The label swap and the `tdd_returned_to_test_review` flag are applied
together, inside `Tdd::ReturnToTestReview`, so no other code path can set the
flag without the PR's labels actually reflecting "back in test review." This
closes the loophole where a run could claim it returned the PR without the
label state agreeing — a reviewer (human or agent) re-checking the PR always
sees a label state consistent with the run's write-guard exemption.

`Tdd::ReturnToTestReview` is only invoked when the write guard actually
rejects a `test_fixing` run's test edits and the run's own reasoning
determines the approved tests are wrong (per RDR-056: "If implementation
discovers approved tests or LID docs are wrong, require the PR to return to
test review before tests change"). This segment provides the mechanism; the
decision of *when* to call it belongs to the run's own agent-harness-driven
reasoning, not to structural code (ZFC: quality/semantic judgments — "are
these tests actually wrong" — are delegated to AI, not hardcoded here).

## Mutation-phase sequencing

`Containers::QualityHooks#install_quality_hooks` already resolves a
per-project mutation command and installs it into the container's
pre-commit hook. This segment adds one additional gate:
`mutation_cmd = nil if agent_run.tdd_test_writing_phase?`. `test_fixing` and
`refactor` phases (and non-TDD-governed runs) are unaffected — mutation
checks continue to run after green as before, and the existing
approved-tests write-guard boundary already prevents a mutation-driven fix
from touching tests outside the `ReturnToTestReview` path.
