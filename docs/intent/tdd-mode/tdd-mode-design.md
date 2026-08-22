# Design: Project TDD Mode (RDR-056)

> Design notes for the project-level TDD mode configuration and test-review
> labels. Code is compiled output that may be regenerated from this spec plus
> the EARS claims in `tdd-mode-specs.md`.

This segment covers the configuration and GitHub label provisioning portion of
[RDR-056](../../rdrs/RDR-056-strict-test-driven-development-mode.md). Test-writing
runs, queue gating, the `test_review` agent, run-scoped write guards, and
PR-description test-outline rendering are tracked separately under RDR-056's
remaining implementation issues (#3467–#3469) and are out of scope here.

## What this segment owns

- A `Project#tdd_mode` attribute with three values: `off`, `non_strict`,
  `strict`. Defaults to `off` for every project (including pre-existing
  rows) so existing Paid behavior is preserved.
- Inclusion validation on `Project#tdd_mode` so callers cannot persist a
  value outside the three supported modes.
- Surfacing the mode in the project's automation settings UI (edit page) and
  showing the active value in the project show page.
- Three GitHub labels with stable color and description:
  - `paid-tests-ready-for-review` (yellow) — draft PR is awaiting test review.
  - `paid-tests-approved` (green) — tests approved; Paid may implement.
  - `paid-test-changes-requested` (orange) — tests need changes before
    implementation.

## What this segment does NOT own

- The test-writing goal/focus on `AgentRun` and the run path that opens
  tests-only draft PRs (issue #3467).
- The queue/dispatch rule that blocks implementation runs while
  `paid-tests-ready-for-review` or `paid-test-changes-requested` is present
  without `paid-tests-approved` (issue #3468).
- The `test_review` agent verdict for non-strict mode (issue #3469).
- PR description test-outline rendering, run-scoped write guards, and the
  LID-aware strict-review prompt clauses called out in RDR-056's
  Implementation Plan.

## Schema

`projects.tdd_mode` is a non-null string column with a database-level default
of `"off"`. New rows are created with the default; pre-existing rows are
backfilled to `"off"` by the migration's default so no follow-up data fixup
is required.

```ruby
add_column :projects, :tdd_mode, :string,
  default: "off", null: false,
  comment: "Project-level TDD mode: off | non_strict | strict"
```

## Label provisioning

`Projects::EnsureStandardLabels` already owns the idempotent create-or-flag
flow for `paid-generated`, `paid-automation`, the enhance-issue pair,
`paid-recommend-close`, `paid-paused`, and the priority tiers. The three
test-review labels join that set with stable colors and descriptions so the
sync path remains a single entry point.

## UI surface

The project edit form already exposes other string-valued automation knobs
(`auto_merge_mode`, `auto_release_granularity`) via `form.select`. TDD mode
follows the same shape: a labeled `<select>` of the three values, with a
helper line that points operators at the RDR for the broader workflow. The
project show page surfaces the active value alongside the other automation
status rows.
