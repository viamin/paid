# EARS: Optimization Recipes and Bounded Repair Policy

> **Preparation draft — pending owner acceptance and merge (#4636).** These
> claims extend, but do not override, the draft maintenance contracts. They are
> inactive until RDR-075, the base maintenance LLD/EARS, and this exact policy
> revision are accepted and merged. Runtime remains behind the default-off
> `maintenance_runs` guard.

## Catalog and Selection

- [ ] **OPT-001**: The system shall provide catalog entries for Performance,
      Design / Architecture, Code Duplication, Security Hardening, Cost /
      Resource Efficiency, Maintainability / Readability, and Test Coverage &
      Quality, with display text, investigation instructions, applicable
      evidence collectors, validation guidance, and metric hints.
- [ ] **OPT-002**: When an authorized user starts an optimization maintenance
      run, the system shall expose identical recipe-menu and free-text
      composition behavior through the UI, authenticated API, and MCP surface.
- [ ] **OPT-003**: The system shall snapshot the selected recipe key and
      version with the maintenance run and retain it across retries.
- [ ] **OPT-004**: When a requested recipe key is unmapped, the system shall
      admit a valid custom-objective maintenance run rather than fail solely
      because the catalog does not contain that key.

## Evidence and Assessment

- [ ] **OPT-010**: The system shall record tool provenance where a recipe uses
      an evidence collector and shall identify prompt-first or incomplete
      coverage honestly in the report.
- [ ] **OPT-011**: The system shall obtain semantic repair eligibility only
      through an `agent_harness` structured assessment bound to supplied
      evidence references.
- [ ] **OPT-012**: The system shall enforce authorization, scope, revision,
      budget, idempotency, and rollout gates deterministically, and shall not
      derive semantic eligibility from keyword matching, titles, raw analyzer
      confidence, or other Paid-side meaning heuristics.
- [ ] **OPT-013**: The system shall preserve raw tool confidence separately
      from the structured semantic assessment and shall retain both evidence
      references on the report occurrence.
- [ ] **OPT-014**: When a recipe has no applicable credible tool, the system
      shall complete it as a prompt-first investigation with its coverage
      limitation visible rather than represent it as a successful tool check.

## Opt-in Bounded Auto-Queue

- [ ] **OPT-020**: The system shall default optimization runs to report-only
      and shall accept an auto-queue election only from an authorized user at
      run start, snapshotting its confidence threshold and per-repair cost/time
      limits; omission shall retain manual-only repair selection.
- [ ] **OPT-021**: When a terminal report has a valid auto-queue election and
      a finding's structured assessment meets its stored threshold under the
      accepted assessment contract, the system shall submit that finding only
      through the existing authorized bounded-repair pathway.
- [ ] **OPT-022**: The system shall refuse an auto-queue attempt unless the
      `maintenance_runs` admission guard is enabled, the election is valid,
      the repair pathway authorizes the target, and the repair preserves the
      finding's bounded scope, provenance, and per-repair budget snapshot.
- [ ] **OPT-023**: The system shall exclude Security Hardening findings from
      auto-queue and shall leave them report-only and manual-selection-only
      until separately authorized security-repair policy exists.
- [ ] **OPT-024**: The system shall use an idempotency record keyed to the
      canonical finding and its election so repeated report occurrences do not
      create duplicate repair work.
- [ ] **OPT-025**: When a repair checkout differs from the source report's
      revision, the system shall revalidate the finding before applying its
      recommendation; failed or stale revalidation shall surface a visible
      blocked outcome and shall not silently apply or discard repair work.
- [ ] **OPT-026**: When a per-repair cost or time limit is exhausted, the
      system shall preserve collected evidence and report exhaustion without
      exceeding the stored budget.
- [ ] **OPT-027**: When `maintenance_runs` is disabled, the system shall stop
      future auto-queue admissions without cancelling active repair runs or
      deleting reports.
- [ ] **OPT-028**: The system shall link every auto-queued repair to its source
      report, canonical finding, occurrence, election, and gate outcomes.
- [ ] **OPT-029**: The system shall expose the same auto-queue election and
      report/gate state through the UI, authenticated API, and MCP surface,
      applying equivalent project-scoped authorization.

## Staged Recipes

- [ ] **OPT-030**: The system shall register Code Duplication,
      Maintainability / Readability, and Performance through the catalog and
      shall preserve their recipe-specific evidence limitations.
- [ ] **OPT-031**: The system shall register Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      only through catalog entries and shall not duplicate the RDR-075
      test-quality recipe contract.
- [ ] **OPT-032**: When a duplication recommendation depends on structurally
      similar but independently required behavior, the system shall retain the
      counterevidence and shall not represent similarity alone as repair
      authorization.
- [ ] **OPT-033**: The system shall keep all staged recipes behind the
      `maintenance_runs` guard and shall not treat recipe registration as
      rollout enablement.
