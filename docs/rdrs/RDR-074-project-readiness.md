# RDR-074: Settings-Aware Project Readiness

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-10-11
- **Status**: Accepted
- **Type**: Architecture
- **Related RDRs**: [RDR-046](RDR-046-polyglot-language-detection-and-test-execution.md), [RDR-056](RDR-056-strict-test-driven-development-mode.md)
- **Related Issues**: #4255 (umbrella), #4256 (evaluation), #4257 (Inbox), #4258 (bootstrap), #4325 (closeout)

## Decision

Paid SHALL evaluate whether a project is structurally ready for the
contract-driven work its enabled settings require. `Projects::Readiness` is a
pure service: it receives a project and an already-available repository
checkout, reads only that checkout and the project's settings, and returns a
persistence-ready result containing `gaps` and `evaluated_at`.

Each gap has a stable `kind`, an actionable `description`, and structural
`evidence`. Phase 1 neither persists, displays, nor remediates the result.
Those concerns belong to the later Inbox and run-admission phases.

The initial rule is TDD readiness. `tdd_mode: strict` and
`tdd_mode: non_strict` require all of the following:

- a CI-capable repository (`.github/workflows/`, `.circleci/config.yml`, or
  `.gitlab-ci.yml`);
- an ecosystem-appropriate test directory; and
- a runnable test command.

`tdd_mode: off` contributes no TDD gaps. Other settings may contribute their
own gaps later; their rules are additive rather than changing the meaning of
TDD-off.

Ecosystem behavior uses registered detectors. A detector owns applicability,
test-directory candidates, and test-command readiness. The default detector
reuses `Prompts::LanguageCommands`; ecosystem-specific detectors precede it.
Godot 4.x with gdUnit4 is the reference specialized detector: a GDScript or
Godot project requires `test`/`tests` and `addons/gdUnit4`.

## Alternatives considered

### A single language `case` in the readiness rule

Rejected. It turns every new ecosystem into a risky edit of a central branch
and mixes rule policy with ecosystem evidence. A registered detector keeps
addition local and testable.

### Ask an LLM whether the repository is ready

Rejected. Readiness is an admission contract based on observable structure,
not a quality judgment. Deterministic paths and command mappings are
explainable, inexpensive, and suitable for persistence.

### Clone or fetch inside the evaluator

Rejected. Network and worktree lifecycle are I/O concerns that make an
otherwise pure evaluator hard to reuse and test. Phase 2/3 callers provide a
checkout and own repository acquisition.

### Treat TDD-off as globally ready forever

Rejected. It would prevent review, security, or future contract settings from
adding their own prerequisites. TDD-off only suppresses TDD-specific gaps.

## Trade-offs

The evaluator reports conventional structure, so a nonstandard but runnable
repository may receive a gap until a detector supports its ecosystem. This is
preferable to claiming a contract is satisfiable without evidence. The initial
CI markers are intentionally broad enough for the supported workflows but do
not prove that a remote CI run will succeed; later execution phases retain
their existing runtime verification.

`Prompts::LanguageCommands` supplies a known runnable command for supported
languages, not proof that dependencies are installed in every checkout. That
matches Phase 1's structural scope and prevents duplicate command policy.

## Validation criteria

- A strict Godot/GDScript fixture containing only `AGENTS.md`, `README.md`,
  and `docs/` reports CI, test-directory, and test-command gaps.
- A supported-language repository with CI and its test directory reports no
  TDD gaps when its language command is available.
- Strict and non-strict modes apply the same initial TDD prerequisites.
- TDD-off reports no TDD gaps and remains open to independent future rules.
- The result serializes gaps and an ISO-8601 evaluation timestamp without
  persistence.
