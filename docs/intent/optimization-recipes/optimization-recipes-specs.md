# EARS: Optimization Recipes (Maintenance Optimization Family)

> **Draft — pending owner acceptance.** These specs trace to
> [`optimization-recipes-design.md`](optimization-recipes-design.md), the
> reviewable design prerequisite for the optimization recipe family
> ([#4492](https://github.com/viamin/paid/issues/4492) umbrella;
> [#4493](https://github.com/viamin/paid/issues/4493)–
> [#4496](https://github.com/viamin/paid/issues/4496)). Every spec below is
> a `[ ]` active gap: correct, current intent with no implementation. None
> are implementable until the owner accepts this segment and the base
> maintenance segment ([#4635](https://github.com/viamin/paid/issues/4635));
> see the design's
> [Open Questions & Future Decisions](optimization-recipes-design.md#open-questions--future-decisions).
>
> Each section names the delivery issue that owns its claims.
> [#4492](https://github.com/viamin/paid/issues/4492) is a tracking umbrella
> and owns no claim here.

## Optimization Catalog and Type Menu — #4493

- [ ] **MAINT-OPT-001**: The system shall define the optimization catalog as
      a code-defined set of type entries, where each entry carries a stable
      key, a display name, a description of what the agent looks for, default
      metric hints, an optional pointer to an underlying recipe definition,
      and an automatic-repair admission of `eligible`, `manual_only`, or
      `denied`.
- [ ] **MAINT-OPT-002**: The system shall register Code Duplication,
      Maintainability / Readability, Performance, Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      as the seven initial optimization catalog entries.
- [ ] **MAINT-OPT-003**: Where a start request carries a type value that does
      not resolve to a catalog entry, then the system shall start a
      custom-objective maintenance run and shall not fail the request.
- [ ] **MAINT-OPT-004**: The system shall surface the optimization type menu
      wherever a maintenance run can be started — the trigger-agent-run form,
      chat, the authenticated API, and the MCP surface — with equivalent
      behavior and the same project-scoped authorization on every surface.
- [ ] **MAINT-OPT-005**: The system shall admit a maintenance run with no
      optimization type selected, and shall treat that run as a
      custom-objective investigation.
- [ ] **MAINT-OPT-006**: The system shall record the selected optimization
      type on the maintenance run snapshot alongside the objective, scope, and
      guidance, and shall retain it across retries of that run.
- [ ] **MAINT-OPT-007**: Where an optimization type is added or extended, the
      system shall require a catalog entry only, and shall not require a
      run-contract enum migration.

## Scope Semantics — #4493, #4494

- [ ] **MAINT-OPT-010**: The system shall accept a free-form natural-language
      scope for an optimization run, and shall treat files, a feature, and a
      page in the application as valid scope targets.
- [ ] **MAINT-OPT-011**: The system shall apply no default scope limits to an
      optimization run's free-form scope.
- [ ] **MAINT-OPT-012**: Where no scope is supplied, the system shall record
      the optimization run as an explicit broad-scope investigation.
- [ ] **MAINT-OPT-013**: The system shall bound optimization recommendations
      to the requested scope while allowing supporting evidence — callers,
      tests, framework entry points, and design documents — to be inspected
      outside it.
- [ ] **MAINT-OPT-014**: Where a recommendation would require changes beyond
      the requested scope, the system shall state that explicitly in the
      finding, and shall require explicit human authorization before any
      repair work extends beyond the selected finding.
- [ ] **MAINT-OPT-015**: Where a named scope target is ambiguous or missing,
      then the system shall produce an actionable clarification outcome rather
      than silently broadening the run.

## Recipes and Honest Evidence — #4494

- [ ] **MAINT-OPT-020**: The system shall register each optimization recipe
      with an objective, investigation instructions, applicable evidence
      collectors, validation guidance, and default metric hints.
- [ ] **MAINT-OPT-021**: The system shall implement the Code Duplication
      recipe with tool-assisted evidence collectors where an applicable
      analyzer attaches, and shall record the analyzer's name, version, and
      configuration as provenance on each finding it produces.
- [ ] **MAINT-OPT-022**: Where a Code Duplication finding rests on analyzer
      output alone, then the system shall not recommend consolidation or
      deletion without agent-assessed evidence about deliberate independence,
      framework callbacks, reflection, external APIs, and compatibility
      obligations.
- [ ] **MAINT-OPT-023**: The system shall implement the Maintainability /
      Readability recipe with tool-assisted complexity evidence where it is
      available and agent-assessed findings otherwise.
- [ ] **MAINT-OPT-024**: The system shall implement the Performance recipe as
      prompt-first, and shall complete it as a prompt-only investigation with
      honest coverage disclosure where no analyzer attaches.
- [ ] **MAINT-OPT-025**: The system shall record a recipe's default metric
      hints on the findings it produces as expectations rather than as
      measured deltas, unless the run actually measured the metric.
- [ ] **MAINT-OPT-026**: The system shall record each optimization finding's
      category, affected locations and symbols, claim, supporting evidence,
      known counterevidence, proposed action, validation plan, and
      verification disposition, distinct from any raw analyzer confidence
      score.
- [ ] **MAINT-OPT-027**: Where a run's evidence collection was prompt-only,
      then the system shall record prompt-only provenance on its findings and
      report, and shall not claim analyzer provenance it did not have.
- [ ] **MAINT-OPT-028**: Where a planned analyzer does not complete, then the
      system shall report incomplete coverage and shall not present the
      result as a clean scan.
- [ ] **MAINT-OPT-029**: The system shall treat a completed optimization scan
      with no findings as a successful outcome.
- [ ] **MAINT-OPT-030**: When a repeated scan reproduces the same canonical
      finding identity, then the system shall update that canonical finding's
      occurrences rather than create duplicate repair work.

## Semantic Assessment and Deterministic Gates — #4495

- [ ] **MAINT-OPT-035**: The system shall obtain a finding's repair
      eligibility from a structured assessment produced through
      `agent_harness`, and shall not derive eligibility from analyzer output,
      keyword matching, or the length or shape of the finding text.
- [ ] **MAINT-OPT-036**: The assessment response shall carry the repair
      standing, an explanation, evidence references, the evidence revision it
      assessed, and the rubric and model versions that produced it.
- [ ] **MAINT-OPT-037**: The system shall represent the repair standing as
      one of `supported`, `marginal`, `unsupported`, or `unknown`, ordered
      `supported` > `marginal` > `unsupported`, with `unknown` outside that
      order.
- [ ] **MAINT-OPT-038**: The system shall treat a repair standing as a policy
      assessment of evidence strength rather than a calibrated probability,
      and shall not aggregate standings numerically or combine them into a
      score.
- [ ] **MAINT-OPT-039**: The system shall not use a raw analyzer confidence
      score as the input to the automatic-repair selection threshold.
- [ ] **MAINT-OPT-040**: Where the assessment is missing, malformed,
      `unknown`, failed, or bound to a superseded evidence revision, then the
      system shall fail closed and shall not qualify the finding for
      automatic repair.
- [ ] **MAINT-OPT-041**: The system shall apply the automatic-repair gates
      deterministically in code — authorization, catalog admission, standing
      threshold, canonical-finding idempotency, per-repair budget caps, and
      repair-target revision freshness.

## Bounded Automatic Repair — #4495

- [ ] **MAINT-OPT-045**: The system shall offer an automatic-repair election
      at maintenance run start on the UI, the authenticated API, and the MCP
      surface, with equivalent behavior and the same project-scoped
      authorization on every surface.
- [ ] **MAINT-OPT-046**: The system shall default the automatic-repair
      election to absent, so that a run without the election behaves exactly
      like a report-only run.
- [ ] **MAINT-OPT-047**: The system shall record the election on the run
      snapshot — enabled, minimum standing, per-repair cost cap, per-repair
      time cap — and shall treat it as a per-run election that never becomes a
      tenant-wide setting or a recipe default.
- [ ] **MAINT-OPT-048**: The system shall apply the election only to findings
      of the run's own optimization type, and shall not extend it to findings
      of another type.
- [ ] **MAINT-OPT-049**: The system shall default the election's minimum
      standing to `supported`.
- [ ] **MAINT-OPT-050**: The system shall deliver the complete optimization
      report regardless of the election, and shall leave findings that were
      not selected available for manual selection.
- [ ] **MAINT-OPT-051**: The system shall dispatch automatic repairs only
      for a report whose outcome is `completed`; for a `partial`,
      `cancelled`, or `budget_exhausted` outcome the system shall queue
      nothing and shall record the reason.
- [ ] **MAINT-OPT-052**: The system shall dispatch qualifying repairs through
      the base repair-handoff pathways unchanged, as bounded repair issues or
      PR-creation runs, and shall link each dispatched repair to its source
      report and canonical finding.
- [ ] **MAINT-OPT-053**: Where the repair target's revision has moved since
      the source report was generated, then the system shall require
      revalidation of the finding's evidence before the repair applies, and
      shall surface a failed revalidation visibly rather than dropping the
      repair silently.
- [ ] **MAINT-OPT-054**: The system shall derive the automatic-repair
      idempotency key from the canonical finding identity, so that a repeated
      occurrence of the same identity creates no second repair run.
- [ ] **MAINT-OPT-055**: The system shall apply explicit cost and time caps
      to each automatically dispatched repair run, and shall preserve the
      collected evidence when a cap is exhausted.
- [ ] **MAINT-OPT-056**: The system shall keep an automatically dispatched
      repair's scope bounded to the selected finding; a repair that would
      change code beyond that finding requires explicit human authorization.
- [ ] **MAINT-OPT-057**: The system shall record on every automatically
      dispatched repair the run-start election, the assessment standing, and
      the report and canonical finding it came from.
- [ ] **MAINT-OPT-058**: The system shall not let a run-start election widen
      a catalog automatic-repair admission; the election can only narrow
      which findings qualify.
- [ ] **MAINT-OPT-059**: While the `maintenance_runs` guard is disabled for
      a project's tenant, the system shall queue no new automatic repairs,
      and shall neither cancel already-active repair runs nor delete any
      report.
- [ ] **MAINT-OPT-060**: The system shall refuse to queue automatic repairs
      for a schedule-generated run, because a standing election on a
      recurring run would be a recipe default.

## Staged Follow-On Types — #4496

- [ ] **MAINT-OPT-065**: The system shall register Security Hardening, Cost /
      Resource Efficiency, Design / Architecture, and Test Coverage & Quality
      as staged catalog entries whose recipes land only when the preceding
      stages' evaluation evidence supports them.
- [ ] **MAINT-OPT-066**: The system shall keep Security Hardening repairs
      manual-only until a separately authorized accuracy and safety review
      moves its automatic-repair admission.
- [ ] **MAINT-OPT-067**: The system shall keep the automatic-repair admission
      of Cost / Resource Efficiency, Design / Architecture, and Test Coverage &
      Quality at `denied` until a separate owner authorization, supported by
      evaluation evidence, moves it.
- [ ] **MAINT-OPT-068**: The system shall frame Design / Architecture
      findings as proposed actions rather than auto-applicable rewrites.
- [ ] **MAINT-OPT-069**: The system shall reconcile the Test Coverage &
      Quality recipe with the base maintenance test-quality recipe rather
      than duplicating it.
- [ ] **MAINT-OPT-070**: Where a staged type has no credible tool evidence
      path, the system shall land it prompt-first and shall record that
      honestly in its reports.

## Rollout Guard, Provenance, and Evaluation Evidence

- [ ] **MAINT-OPT-075**: The system shall admit the optimization family
      through the `maintenance_runs` tenant rollout guard, and shall not
      introduce a second rollout switch for it.
- [ ] **MAINT-OPT-076**: The system shall record the effective recipe version
      and the resolved analyzer provenance on every optimization run, its
      report, and the findings that used an analyzer.
- [ ] **MAINT-OPT-077**: The system shall record, per optimization recipe
      evaluation, the actionable findings, false positives, unresolved
      coverage, latency, token and tool cost, repeated-finding noise, and
      repair outcomes, and shall treat a recipe's admission change as
      unevaluated until those measurements exist.
