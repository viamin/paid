---
parent: PAID
prefix: PROJECT-READINESS
---

# Project readiness design

`Projects::Readiness` determines whether a project's enabled contract-driven
settings have structural prerequisites missing from an already-available
repository checkout. It is deterministic and read-only: it accepts a project
and checkout path, returns a `Result`, and never clones, fetches, persists,
renders UI, or asks an AI model to decide readiness.

The result is intentionally ready for persistence by later phases:

```ruby
{
  gaps: [{ kind: "missing_ci", description: "...", evidence: { checked_paths: [...] } }],
  evaluated_at: "2026-10-11T00:00:00Z"
}
```

The initial rules are TDD and interactive-verification readiness. Both `strict` and `non_strict` TDD require
a CI marker, a test directory, and a test command. `off` adds no TDD gap. A
future rule is independently additive, so a project with TDD off can still be
blocked by a feature that has its own declared contract.

Rules ask a detector for ecosystem-specific test evidence. Detectors are
registered in precedence order: specialized detectors first and the
`Prompts::LanguageCommands` fallback last. Adding an ecosystem therefore
means adding and registering a detector, rather than extending a central
language switch. The initial specialized detector covers Godot 4.x + gdUnit4;
it detects GDScript/Godot or `project.godot` and looks for `test` or `tests`.
Its command evidence is either the installed
`addons/gdUnit4/bin/GdUnitCmdTool.gd` entry point or the supported,
repository-owned install-on-demand contract: executable `bin/test` plus
executable `bin/install-test-tools`. The latter records that dependency setup
is required; it does not claim that setup or tests have succeeded.

Readiness never executes either script, downloads an addon, or infers a
command from a CI YAML string, an arbitrary filename, or a historical check.
The isolated agent/CI execution environment owns setup and test execution, and
retains its exact tool versions, discovered tests, output, and exit status.
An unavailable or failed setup is execution evidence, not a reason for the
web/control-plane evaluator to mutate it into a successful readiness result.

When interactive verification is enabled, readiness also validates the
target-checkout configuration through `Screenshots::RuntimePlan`: it requires
a parseable configuration, an applicable start command, and definitions for
each configured service. These are repository/setup facts, so they become
actionable gaps. Browser connectivity and whether a configured service happens
to be healthy in a particular run are bounded runtime probes. Their failures
remain structured run observations (including run, revision, time, and reason)
and never become durable repository gaps. Disabled verification adds no gap.

## Inbox readiness snapshot

The evaluator remains read-only. `Projects::Readiness::Record` persists its
serialized gaps and evaluation timestamp on the project after a worker has
obtained a temporary checkout. The Inbox only reads that snapshot; it never
clones, fetches, or evaluates during a poll/render.

Projects whose enabled TDD or verification capability has one or more stored
gaps appear in the
`project_setup_pending` Inbox lane. The entry is project-backed (rather than
issue- or PR-backed), lists the structural gap descriptions and evidence, and
links the operator to project settings. A satisfied snapshot, or a project
whose enabled capabilities have no gaps, has no entry. This lane is visible
using the same authorized-project scope as other owner-scoped Inbox lanes and
deliberately does not depend on `auto_pick_enabled`.

The detail also exposes the newest relevant verification setup observation,
selected by the observation's own recorded time rather than the run's creation
time: an older, long-running run can record its setup failure after a newer run
already recorded one. Runs without a recorded observation time are the last
resort, and no run-count cutoff may hide a later observation. That observation
is diagnostic evidence, not a readiness latch: a later target-branch evaluation
replaces repository gaps from checkout evidence, and a recovered browser or
service needs no cleanup action.

Evaluation is queued when a project is created with a readiness-relevant
setting enabled, when readiness-relevant settings change (TDD mode,
verification settings), when a project's service-container associations change
or an associated service is renamed, and after a completed run that produced a
result commit. A snapshot update bumps the Inbox cache
version only when the gap set changes, so queue, filters, and nav badge refresh
together without re-evaluating a checkout on every poll. Surfacing a gap never
queues a bootstrap run. Phase 3 lets an authorized operator explicitly start
one `bootstrap_readiness` run from this Inbox entry. The same authorized,
confirmation-gated `trigger_readiness_bootstrap` tool uses that admission path
for non-UI operator flows. Only one unfinished bootstrap attempt may exist for
a project; after it reaches a terminal state, another attempt requires another
explicit trigger. A failed attempt leaves the
readiness entry and its run failure visible. Successful bootstrap PRs use the
ordinary draft/ready review flow and are separate from the later TDD
test-review PR.

Actions in the Inbox detail frame that leave the Inbox — starting a bootstrap
run, opening project settings, and opening a failed run — explicitly target
the top-level page. Their destinations do not render the `inbox-detail` Turbo
frame, so frame-scoped navigation would otherwise replace the detail pane with
Turbo's missing-content state.

## Bootstrap write boundary

`bootstrap_readiness` is a distinct harness class, enforced at
`CreatePullRequestActivity` before a PR is created or reused. It permits only
CI configuration (`.github/workflows/`, `.circleci/`, `.gitlab-ci.yml`),
project/scaffold manifests (including `project.godot`, `package.json`, and
`go.mod`), conventional test-directory layout (`test/`, `tests/`, `spec/`,
`__tests__/`, `Tests/`), and tool configuration files. Any other changed file
aborts the run with the offending paths recorded in its system log. This
structural boundary is not a judgment about whether a configuration is
runnable; the bootstrap prompt must inspect the actual checkout and configure
a runnable harness.

Verification bootstrap work may additionally change `.paid/screenshots.yml`.
It is still explicitly admitted, bounded to configuration/harness files, and
never auto-retried. A repository gap clears only after the bootstrap PR merges
and the target branch is re-evaluated.

The bootstrap class is deliberately separate from `Tdd::WriteGuard`. The
`test_writing`, `test_fixing`, and `refactor` allowed-write semantics are
unchanged. A completed bootstrap run never schedules an eager readiness
evaluation: the issue-sync path schedules it only after GitHub confirms the
bootstrap PR merged, so the checkout reads target-branch evidence. No durable
ready latch exists.

## Product-acceptance boundary

RDR-074 formalizes the evaluator and the implementation above. The closeout
audit supplies the broader #4255 consumer evidence: runnable Godot/gdUnit4
coverage follows an authorized operator from a missing-project Inbox entry,
through a harness-bounded bootstrap and GitHub-confirmed merge, to
target-branch re-evaluation, Inbox clearance, and an intentionally red
test-writing draft. The confirmation-gated `trigger_readiness_bootstrap` tool
provides the equivalent authorized non-UI action. No ready flag or automatic
bootstrap retry may stand in for checkout re-evaluation.
