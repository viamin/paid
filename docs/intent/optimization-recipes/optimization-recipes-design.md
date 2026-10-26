# Low-Level Design: Maintenance Optimization Recipes

> **Draft — pending owner acceptance.** This leaf extends the planned
> RDR-075 maintenance capability; it does not accept RDR-075, authorize
> implementation, or enable a rollout. Its EARS claims are active gaps.

## Purpose and Scope

Optimization recipes make a bounded set of maintenance objectives selectable
without treating an analyzer result as permission to mutate a repository. The
catalog owns recipe identity, category admission, selection inputs, evidence
requirements, and the narrow automatic-repair policy requested for the
optimization family. It consumes the maintenance-run lifecycle, report,
finding identity, repair handoff, and `maintenance_runs` default-off guard.

This segment maps executable work to [#4493](https://github.com/viamin/paid/issues/4493)
(catalog and selection), [#4494](https://github.com/viamin/paid/issues/4494)
(first recipes and evidence), [#4495](https://github.com/viamin/paid/issues/4495)
(bounded auto-queue), and [#4496](https://github.com/viamin/paid/issues/4496)
(staged types). [#4492](https://github.com/viamin/paid/issues/4492) is a
tracking umbrella, not an executable deliverable. All four implementation
issues also depend independently on accepted RDR-075/base maintenance intent
and the required #4604 live tool-handoff evidence.

## Catalog, Selection, and Scope

A recipe is a versioned catalog entry with an objective, category, supported
evidence collectors, a semantic-assessment rubric, validation guidance, and
an automatic-repair standing. A run snapshots its selected recipe version,
scope, guidance, collector configuration, and limits at admission. An
authorized user may select a recipe or submit a free-text optimization
question; neither makes a recipe default for a tenant or project.

Requested scope bounds recommendations and any repair. It does not prevent
the investigation from reading callers, tests, entry points, and design
documents outside that scope when those are necessary supporting evidence.
The report must distinguish requested scope, inspected supporting context,
recommendation scope, exclusions, and incomplete coverage. Any recommended
or repair change outside requested scope requires a new explicit human
authorization.

The initial catalog is limited to the first recipes approved by #4494.
Cost, design/architecture, and test-coverage types are staged as
`default_deny`; security hardening is `manual_only`. Neither a run-start
election nor a recipe setting can promote either standing. A separate owner
authorization with evaluation evidence is required before any category gains
automatic-repair eligibility.

## Honest Evidence and Semantic Assessment

Collectors may produce candidates and raw scores, but raw tool confidence is
provenance, not a repair gate. `agent_harness` performs the semantic
assessment using a versioned rubric and structured response containing a
bounded ordered standing (`supported`, `marginal`, `unsupported`, or
`unknown`), explanation, cited evidence, counterevidence, and a validation
plan. This is a semantic judgment, so it is not reimplemented in framework
code or converted into a fabricated calibrated probability.

Code validates the response shape and evidence references, persists the
assessment and rubric version, and fails closed on malformed, missing, stale,
or `unknown` assessments. A configured threshold compares only the ordered
standing; it is a policy setting, not a numerical claim about probability.
The default minimum is `supported`. A report remains complete and visible
regardless of whether a finding passes that threshold.

## Bounded Automatic Repair

Automatic repair is a per-run, opt-in election at run start, default absent.
It is not a schedule, tenant, project, or recipe default. The election
snapshots a minimum standing and explicit cost/time cap for each potential
repair run. Omission produces exactly the existing report-only behavior.

After a `completed` report only, deterministic code may dispatch a repair
through the existing M04 pathway if every gate passes: the election exists;
the caller was authorized; the category standing permits auto-repair; the
semantic assessment meets the snapshot threshold; repair scope is within the
approved finding; the per-repair budget exists; and no repair with the
canonical finding identity has already been queued. `clean`, `partial`,
`cancelled`, and `budget_exhausted` reports dispatch none and record why.

Each queued repair links its source report, occurrence, canonical finding,
election, assessment, revision, and budget snapshot. It must revalidate the
finding against the repair checkout when the target revision moved; a failed
or incomplete revalidation visibly prevents application rather than silently
dropping or applying the repair. Budget exhaustion preserves repair evidence.
Disabling `maintenance_runs` stops new admissions and queues but never
cancels an already active repair or deletes reports.

## Decisions and Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Confidence semantics | `agent_harness` emits a bounded ordered standing; code compares the configured standing threshold | Raw analyzer score; calibrated numeric probability | Semantic confidence needs fresh contextual judgment; a numerical calibration would assert evidence the system has not measured. |
| Automatic-repair admission | Per-run opt-in election with explicit caps and deterministic gates | Tenant/recipe default; scan-time repair | Preserves #4495's opt-in decision and RDR-075's separation of investigation from authorization. |
| Category safety | Security manual-only; staged categories default-deny | Election may override a category | Category admission is a product safety decision, not a caller-selected parameter. |
| Idempotency key | Canonical finding identity | Report occurrence or run identity | Repeated occurrences must preserve history without creating duplicate repair work. |

## Acceptance and Dependencies

Owner acceptance is required for this precise draft, including standing-based
threshold semantics, `supported` as the default, completed-report-only
dispatch, election-only narrowing, manual-only security repairs,
default-deny staged types, canonical-identity idempotency, and the base
maintenance forward reference. Until it is accepted and merged, this is a
docs-only preparation and no runtime behavior is enabled.

## What This Is Not

- Not RDR-075 acceptance or a replacement for its report-only default.
- Not a second tool marketplace, evidence collector, repair pathway, or
  feature flag; it reuses existing maintenance services and the default-off
  `maintenance_runs` guard.
- Not permission to auto-repair security findings or to broaden repair scope.
