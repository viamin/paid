---
parent: PAID
prefix: QUALITY-LOOPS
---

# Low-Level Design: Quality Feedback Loops

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the current shipped quality/backpressure mechanisms that
> replaced the original draft shapes in RDR-013: managed-project
> `PreCommitRequirement` resolution and evaluation, container git-hook
> installation, quality-gate admission checks, and the review-bot trigger
> parser. Paid's own repository secret/workflow scans are covered separately in
> `repo-secret-scan` and `repo-workflow-scan`; mutation-specific closeout lives
> in RDR-036 and its linked implementation/tests.

## Purpose

The original RDR-013 proposed several class shapes and feedback loops that did
not ship as written. The current system still delivers the same functional
backpressure goals through concrete mechanisms that already exist in the app:

- DB-backed pre-commit requirement records instead of generated config files
- container-installed git hooks instead of a generic per-language parser layer
- rolling quality-gate admission checks instead of a per-run retry activity
- review-bot workflow/trigger handling instead of the draft `PrReviewService`

This segment records those current mechanisms so the brownfield LID surface
tracks the software that actually runs today.

## Effective Pre-Commit Requirements

`PreCommitRequirement` is the account/user/project-scoped source of truth for
managed-project checks. `PreCommitRequirement.resolve(project:, user:)` merges
requirements by name with precedence `project > user > account`; disabled
overrides act as tombstones that suppress inherited requirements with the same
name. The resulting enabled checks are ordered by position/name.

`PreCommitRequirements::Evaluate` executes the resolved checks in the agent
container after the agent commits but before branch push/PR creation. Warn-mode
checks surface feedback without blocking; block/auto-fix checks can stop the
run from proceeding. Mutation-test requirements route through the current
mutation results reader so surviving mutations become structured quality
feedback instead of opaque stdout.

## Container Hook Installation

`Containers::QualityHooks` installs the git-hook commands that provide
immediate backpressure inside the agent container. It derives the lint/test
commands from the detected project language and resolves the mutation command
from the effective pre-commit requirements.

For DB-dependent languages such as Ruby, when no database service container is
running the test and mutation hooks are replaced with no-ops. This avoids an
inescapable commit loop where hooks reject every commit for infrastructure the
agent cannot provision mid-run.

## Quality-Gate Admission

`Activities::CheckQualityGateActivity` is the automatic-run admission gate. It
evaluates a rolling window of recent automated `QualityMetric` records against
the project's effective gate settings and any enabled threshold records.

Current bypass rules are deliberate:

- manual runs bypass the gate
- priority-labeled issue/PR work bypasses the gate
- explicit caller bypass also wins

When enough recent data exists and no bypass applies, the activity blocks
automatic work only when the rolling averages breach the configured thresholds.
The result is recorded into `WorkflowState` for workflow-level observability.

## Review-Bot Trigger Parsing

Review-bot follow-up work is driven by a shared trigger payload parser:
`Automation::ReviewBotTrigger#review_bot_reviewers_from`. It prefers the
ordered `request_logins` array and falls back to the legacy single
`request_login` field so in-flight histories and replayed workflows continue to
produce the same reviewer chain during the schema transition.

## What this is not

- **Not the superseded `QualityConfiguratorService` design.** Current quality
  configuration is record-based (`PreCommitRequirement`), not generated files.
- **Not a generic structured parser for every test framework.** Current
  structured feedback is targeted where it ships today, notably mutation-test
  results.
- **Not Paid's own repo scan coverage.** The host pre-commit secret scan and
  CI workflow scan are intentionally documented in their sibling intent
  segments to avoid duplication.
