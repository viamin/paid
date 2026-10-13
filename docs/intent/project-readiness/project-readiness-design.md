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

The initial rule is TDD readiness. Both `strict` and `non_strict` TDD require
a CI marker, a test directory, and a test command. `off` adds no TDD gap. A
future rule is independently additive, so a project with TDD off can still be
blocked by a feature that has its own declared contract.

Rules ask a detector for ecosystem-specific test evidence. Detectors are
registered in precedence order: specialized detectors first and the
`Prompts::LanguageCommands` fallback last. Adding an ecosystem therefore
means adding and registering a detector, rather than extending a central
language switch. The initial specialized detector covers Godot 4.x + gdUnit4;
it detects GDScript/Godot or `project.godot`, looks for `test` or `tests`, and
requires `addons/gdUnit4` as the executable test-harness evidence.

## Inbox readiness snapshot

The evaluator remains read-only. `Projects::Readiness::Record` persists its
serialized gaps and evaluation timestamp on the project after a worker has
obtained a temporary checkout. The Inbox only reads that snapshot; it never
clones, fetches, or evaluates during a poll/render.

Enabled TDD projects with one or more stored gaps appear in the
`project_setup_pending` Inbox lane. The entry is project-backed (rather than
issue- or PR-backed), lists the structural gap descriptions and evidence, and
links the operator to project settings. A satisfied snapshot, or a project
whose TDD mode is off, has no entry. This lane is visible using the same
authorized-project scope as other owner-scoped Inbox lanes and deliberately
does not depend on `auto_pick_enabled`.

Evaluation is queued when TDD readiness settings change and after a completed
run that produced a result commit. A snapshot update bumps the Inbox cache
version only when the gap set changes, so queue, filters, and nav badge refresh
together without re-evaluating a checkout on every poll. Surfacing a gap never
queues a bootstrap run. Phase 3 lets an authorized operator explicitly start
one `bootstrap_readiness` run from this Inbox entry. Only one unfinished
bootstrap attempt may exist for a project; after it reaches a terminal state,
another attempt requires another explicit click. A failed attempt leaves the
readiness entry and its run failure visible. Successful bootstrap PRs use the
ordinary draft/ready review flow and are separate from the later TDD
test-review PR.

## Bootstrap write boundary

`bootstrap_readiness` is a distinct harness class, enforced at
`CreatePullRequestActivity` before a PR is created or reused. It permits only
CI configuration (`.github/workflows/`, `.circleci/`, `.gitlab-ci.yml`),
project/scaffold manifests (including `project.godot`, `package.json`, and
`go.mod`), conventional test-directory layout (`test/`, `tests/`, `spec/`),
and tool configuration files. Any other changed file aborts the run with the
offending paths recorded in its system log. This structural boundary is not a
judgment about whether a configuration is runnable; the bootstrap prompt must
inspect the actual checkout and configure a runnable harness.

The bootstrap class is deliberately separate from `Tdd::WriteGuard`. The
`test_writing`, `test_fixing`, and `refactor` allowed-write semantics are
unchanged. A completed bootstrap run never schedules an eager readiness
evaluation: the issue-sync path schedules it only after GitHub confirms the
bootstrap PR merged, so the checkout reads target-branch evidence. No durable
ready latch exists.
