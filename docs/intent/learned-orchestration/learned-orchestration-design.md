---
parent: PAID
prefix: LEARNED-ORCH
---

# Low-Level Design: Learned Orchestration

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-014](../../rdrs/RDR-014-learned-orchestration.md). This LLD documents
> the shipped database-backed orchestration strategy selection path.

## Purpose

Paid's orchestration defaults are no longer only in-memory code paths. The
system stores strategy content and strategy versions as data, selects the best
scoped match for a decision context, and leaves baseline behavior intact when
no learned strategy applies.

## Strategy Data Model

`Strategy` is the scope owner and `StrategyVersion` is the immutable content
snapshot. Active strategy content is resolved through `current_version` at one
of three scopes:

- global,
- account,
- project.

`StrategyVersion` enforces that activating a later version requires explicit
promotion metadata, preserving the human review gate on strategy promotion.

## Runtime Selection

`Strategies::Select` is the public runtime selector. It enriches the decision
context, delegates the matching logic to `OrchestrationStrategySelector`, and
returns a structured result with:

- the matched strategy and version when found,
- matched-rule specificity,
- and a fallback result with empty content when nothing matches.

This keeps runtime call sites simple: callers can apply learned content when it
exists and continue baseline behavior otherwise.

## Provisioning

Baseline strategy content (`Strategies::BaselineOrchestration.definitions`) is
seeded by `Strategies::SeedBaselineOrchestration.call`, invoked from
`db/seeds.rb` (fresh installs) and `bin/rails ci:bootstrap_test_defaults`
(schema-only test databases). It is deliberately **not** seeded by a
migration: `strategies`/`strategy_versions` carried mutually self-referencing
RLS policies between the migration that enabled RLS on them and the migration
that fixed the resulting recursion, so any migration in that window that
queries either table fails on a from-scratch replay regardless of how the
query is issued (see #3585).

## Accepted Divergence

RDR-014's original automatic-promotion direction is not the production
contract. Production requires human-reviewed activation metadata for promoted
strategy versions; anomaly-based oversight may still evolve later, but the
runtime selection path assumes human-approved active versions today.

## References

- `app/services/strategies/select.rb`
- `app/models/strategy.rb`
- `app/models/strategy_version.rb`
