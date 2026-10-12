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
queues a bootstrap run; remediation remains a human decision for Phase 3.
