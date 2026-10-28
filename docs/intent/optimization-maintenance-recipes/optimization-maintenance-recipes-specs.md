---
parent: optimization-maintenance-recipes
prefix: OPT-MAINT
---

# EARS: Optimization Maintenance Recipes and Bounded Repair Policy

> **Draft — pending owner acceptance.** These docs-only claims trace to
> [`optimization-maintenance-recipes-design.md`](optimization-maintenance-recipes-design.md).
> They do not authorize implementation or rollout; base RDR-075 acceptance
> and the dependencies named by #4493–#4496 remain independent prerequisites.

## Catalog and Start Contract — #4493

- [ ] **OPT-MAINT-001**: When an authorized caller starts an optimization
      maintenance run through the UI, authenticated API, or MCP surface, the
      system shall expose the same code-defined curated catalog containing
      Performance, Design / Architecture, Code Duplication, Security
      Hardening, Cost / Resource Efficiency, Maintainability / Readability,
      and Test Coverage & Quality.
- [ ] **OPT-MAINT-002**: When a caller selects a catalog entry, the system
      shall resolve its recipe metadata; when a selection is unmapped, the
      system shall preserve it as a custom-objective maintenance request
      rather than reject the run.
- [ ] **OPT-MAINT-003**: When an optimization run starts, the system shall
      persist the resolved catalog selection or custom-objective result with
      the immutable RDR-075 objective, scope, guidance, and recipe snapshot,
      and shall retain that snapshot on retry.
- [ ] **OPT-MAINT-004**: When a caller supplies free-form optimization scope,
      the system shall accept files, features, and application pages without
      artificial scope-type limits, and shall apply MAINT-012 through
      MAINT-014 before representing coverage.

## Recipe Evidence and Assessment — #4494 and #4496

- [ ] **OPT-MAINT-010**: When the system runs the Code Duplication,
      Maintainability / Readability, or Performance recipe, it shall record
      the recipe instructions, applicable collectors, validation guidance,
      metric hints, and collector provenance used for each finding.
- [ ] **OPT-MAINT-011**: When duplication evidence is the only support for a
      proposed consolidation, the system shall require semantic assessment of
      deliberate independence and dynamic or framework invocation before it
      recommends the change.
- [ ] **OPT-MAINT-012**: When no applicable Performance collector is
      available, the system shall perform a prompt-first investigation and
      shall disclose that collector coverage was unavailable rather than
      representing the report as tool-verified.
- [ ] **OPT-MAINT-013**: When the system assesses the semantic sufficiency of
      optimization evidence, it shall call `agent_harness` with a structured
      result containing its finding disposition, cited evidence,
      counterevidence, proposed action, validation plan, and policy result;
      it shall not derive that assessment from keywords or raw tool scores.
- [ ] **OPT-MAINT-014**: When a report has incomplete checks or other coverage
      limits, the system shall preserve and present those limits independently
      of any finding's policy result, and shall not represent the report as
      complete solely because a finding is eligible for manual or automatic
      repair selection.
- [ ] **OPT-MAINT-015**: When a Security Hardening finding is produced, the
      system shall make it available for report inspection and manual repair
      selection only; it shall exclude it from the auto-queue policy until a
      separately accepted security-repair policy changes this claim.
- [ ] **OPT-MAINT-016**: When the system adds Test Coverage & Quality, Cost /
      Resource Efficiency, or Design / Architecture as staged recipes, it
      shall register them through the catalog and preserve the same honest
      evidence contract; the Test Coverage & Quality recipe shall reconcile
      with, rather than duplicate, RDR-075's test-quality objective.

## Bounded Auto-Queue Policy — #4495

- [ ] **OPT-MAINT-020**: When a caller explicitly elects auto-queue at
      optimization-run start, the system shall persist that per-run election,
      confidence-threshold policy, and per-repair cost and time limits; when
      the caller omits the election, the system shall remain report-only.
- [ ] **OPT-MAINT-021**: When `agent_harness` returns a policy result for a
      finding, the system shall treat the configured threshold representation
      as a deterministic policy input and shall not present the result as a
      calibrated numerical probability or infer it from a raw tool score.
- [ ] **OPT-MAINT-022**: When a reported optimization finding is considered
      for auto-queue, the system shall queue a repair only if the
      `maintenance_runs` guard is enabled, the persisted election is present,
      the finding is open and non-security, its persisted policy result meets
      the captured threshold, its source evidence and coverage state are
      inspectable, and the existing repair-creation authorization succeeds.
- [ ] **OPT-MAINT-023**: When an auto-queued repair is created, the system
      shall carry the source report and canonical finding identity, a scope no
      broader than the finding, and the persisted per-repair cost and time
      limits into the existing M04 repair handoff.
- [ ] **OPT-MAINT-024**: When the repair checkout differs from the source
      report revision, the system shall revalidate the selected finding before
      applying its recommendation; when revalidation fails, the system shall
      retain an inspectable non-queued or blocked disposition and shall not
      silently apply the repair.
- [ ] **OPT-MAINT-025**: When a repair already exists or is active for the
      same canonical finding identity and repair target under an auto-queue
      election, the system shall not queue a duplicate repair.
- [ ] **OPT-MAINT-026**: When a candidate fails authorization, revalidation,
      budget, or idempotency gating, the system shall retain its report and
      record an inspectable non-queued disposition; it shall not broaden the
      scope, substitute another finding, cancel an active repair, or delete
      evidence.
- [ ] **OPT-MAINT-027**: When `maintenance_runs` is disabled after a report
      exists, the system shall block new auto-queue admissions while preserving
      reports and active repair runs under their existing lifecycle.
