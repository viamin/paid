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

This segment owns only evaluation. Inbox surfacing, persisted readiness
snapshots, remediation, and run-path enforcement are intentionally deferred to
the next phases described by RDR-074.
