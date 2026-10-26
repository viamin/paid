---
parent: PAID
prefix: MAINT-OPT
---

# Low-Level Design: Optimization Recipes (Maintenance Optimization Family)

> **Draft — pending owner acceptance.** This LLD and its EARS specs
> ([`optimization-recipes-specs.md`](optimization-recipes-specs.md)) are the
> reviewable design prerequisite for the optimization recipe family
> ([#4492](https://github.com/viamin/paid/issues/4492) umbrella;
> [#4493](https://github.com/viamin/paid/issues/4493)–
> [#4496](https://github.com/viamin/paid/issues/4496) delivery issues). They
> are current intent with no implementation: every claim below is an active
> gap, no schema, service, feature flag, or rollout change is included, and
> nothing here authorizes the family to ship. Acceptance is a human decision
> recorded on [#4636](https://github.com/viamin/paid/issues/4636); see
> [Open Questions & Future Decisions](#open-questions--future-decisions) for
> the revisions that decision has to settle.
>
> The base maintenance contracts this family extends live in
> [`docs/intent/maintenance-runs/`](../maintenance-runs/maintenance-runs-design.md)
> (`MAINT-001`–`MAINT-073`), which are themselves unaccepted draft intent
> pending [#4635](https://github.com/viamin/paid/issues/4635).

## Purpose

The maintenance capability can investigate a repository; the optimization
family adds the audits that answer "is this project as efficient as it could
be?" — duplication, maintainability, performance, security hardening, cost,
architecture, and test quality. These audits share the maintenance run
lifecycle: a pinned revision, a report-only outcome, durable findings, and
recurring finding identity.

Two things make the family more than another recipe list:

1. **A curated type menu.** Users pick an optimization type from a catalog
   rather than writing an objective, and the catalog is extensible without
   migrating the run contract.
2. **A bounded automatic-repair policy.** RDR-075 excludes automatic repair
   "unless a separately approved policy" exists. This segment is that
   policy's draft: an opt-in, per-run election that queues bounded repair runs
   for the findings that qualify, with explicit budgets, revalidation, and
   idempotency.

The family deliberately stays downstream of the base maintenance contracts:
it reuses the maintenance run, report, finding, and repair-handoff contracts
rather than introducing a parallel run type, a second tool catalog, or a
second repair pathway.

## Relationship to the Base Maintenance Contracts

| Base contract | What the family adds | What the family does not change |
| --- | --- | --- |
| `MAINT-011` (start inputs) | A type selection alongside objective/scope/guidance; free-form natural-language scope targets | The requirement that a run needs an objective or nonblank guidance; scope alone still admits nothing |
| `MAINT-014` (broad scope) | Broad scope stays the default for optimization audits | The requirement to record broad scope explicitly |
| `MAINT-022`, `MAINT-044` (honest coverage) | Prompt-first recipes that disclose their coverage | The rule that an incomplete check is never a clean scan |
| `MAINT-025` (finding content) | Recipe metric hints and per-finding assessment provenance | The rule that raw tool confidence is separate from the agent's assessment |
| `MAINT-026`–`MAINT-029` (finding identity) | Automatic repair keys off the canonical finding identity | Canonical identity semantics and dismissal/reassessment rules |
| `MAINT-043` (tool provenance) | Recipe-level analyzer provenance for tool-assisted recipes | The rule that a language match is never authorization for a fix |
| `MAINT-070`–`MAINT-073` (repair handoff) | A recorded run-start election as an alternative to per-finding manual selection | Report-only as the base default |

Two base claims are reconciled in place because the family would otherwise
contradict them: `MAINT-011` names the accepted scope forms, and
`MAINT-073` names what counts as an explicit selection. Both edits keep the
base default report-only.

## Optimization Catalog Contract

The catalog is a code-defined set of type entries. It is presentation over
the recipe mechanism, not a hard enumeration in the run contract.

Each catalog entry carries:

| Field | Meaning |
| --- | --- |
| `key` | Stable identifier persisted on the run snapshot |
| `display_name` | Name shown in the type menu |
| `description` | What the agent looks for in this type |
| `metric_hints` | Default expectation hints (latency reduction, complexity decrease, duplicated lines removed, …) |
| `recipe` | Pointer to the underlying recipe definition, or null when the type has no recipe yet |
| `automatic_repair_admission` | `eligible`, `manual_only`, or `denied` — whether findings of this type may participate in automatic repair at all |

The seven initial types are Code Duplication, Maintainability / Readability,
Performance, Security Hardening, Cost / Resource Efficiency, Design /
Architecture, and Test Coverage & Quality. The first three ship recipes; the
last four register as staged entries whose recipes land only when the
preceding stages' evaluation evidence supports them.

Adding a type is a catalog entry. It is not a run-contract enum migration, and
a start request carrying a value that resolves to no catalog entry degrades to
a custom-objective maintenance run rather than failing.

The type menu appears wherever a maintenance run can be started — the
trigger-agent-run form, chat, the authenticated API, and the MCP surface —
with equivalent behavior and the same project-scoped authorization. A run
remains startable with no type selected; selecting one is a convenience, not
a precondition.

The selected type is recorded on the run snapshot alongside objective, scope,
and guidance, and survives retries of that run.

## Scope Contract

Optimization audits accept a free-form natural-language scope: files, a
feature, a page in the application, or a description of the area to audit. No
default scope limits apply — the audit's value depends on the user naming
the area they care about, not on a path filter the platform guessed.

Scope bounds **recommendations**, not **evidence access**. The agent may
inspect callers, tests, framework entry points, and design documents outside
the requested scope to validate a claim; that inspection is expected, not a
scope violation. A recommendation that would require changes beyond the
requested scope says so explicitly, and any repair that would change code
beyond the selected finding needs explicit human authorization.

Where no scope is supplied, the run records an explicit broad-scope
investigation. Where a named target is ambiguous or missing, the run produces
an actionable clarification outcome rather than silently broadening.

## Recipe Contract

A recipe supplies the objective, the investigation instructions, the applicable
evidence collectors, the validation guidance, and the default metric hints.

The first three recipes are:

- **Code Duplication** — tool-assisted. Evidence collectors come from the
  RDR-075 research set (PMD CPD for cross-language duplication; Exhale /
  Debride-class analyzers for Ruby where applicable). Similarity alone does
  not establish that code should be shared: deliberate independence, framework
  callbacks, reflection, external APIs, and compatibility obligations are
  assessed before a consolidation or deletion is recommended.
- **Maintainability / Readability** — tool-assisted where complexity analysis
  is available, agent-assessed otherwise. Cognitive-complexity regressions,
  overly complex functions, and naming/documentation gaps are reportable
  findings with proposed actions.
- **Performance** — prompt-first initially. The agent investigates hot paths,
  algorithmic improvements, and N+1/IO patterns within scope. Tool-assisted
  profiling extends the recipe later without a contract change.

Metric hints recorded on findings are expectations, not measurements. A
finding may carry a hint only when the run actually measured the metric.

## Honest Evidence Contract

Tool evidence identifies candidates; the agent assesses meaning. The two are
never merged:

- A tool-assisted finding records the analyzer's name, version, and
  configuration as provenance.
- A prompt-only run records prompt-only provenance. It never claims analyzer
  provenance it did not have.
- A planned analyzer that did not complete produces visible incomplete
  coverage per the base contract; it is never presented as a clean scan.
- Raw analyzer confidence scores stay evidence. They are never the input to
  the automatic-repair gate.
- A clean optimization scan is a successful outcome, not an error.

## Semantic Assessment Contract

Whether a finding is a sound basis for an automatic repair is a semantic
judgment, so it is made by the agent, not by control-plane code.

### Assessment payload

The repair eligibility of a finding is produced through `agent_harness` as a
structured response carrying:

- `repair_standing` — one of `supported`, `marginal`, `unsupported`, or
  `unknown`;
- `explanation` — why that standing, in the agent's words;
- `evidence_references` — the findings, code locations, and tool outputs the
  assessment rests on;
- `evidence_revision` — the revision of the finding's supporting evidence the
  assessment was made against;
- `rubric_version` and `model_version` — the rubric and model that produced
  it.

### Standing semantics

Standings are ordered `supported` > `marginal` > `unsupported`, with
`unknown` outside that order: it is a distinct state, not the weakest
standing. `unknown` never qualifies for automatic repair under any
configuration.

A standing is a policy assessment of evidence strength, not a calibrated
probability, and it is never aggregated numerically across findings or
converted into a score. This mirrors the shipped
[`facet-confidence`](../facet-confidence/facet-confidence-design.md) segment,
which already treats confidence outputs as rubric-scored policy assessments
rather than calibrated probabilities.

The owner's recorded selection policy is a **configured threshold applied to
findings only**. This design keeps that shape — a configured minimum, a
per-run evaluation, findings only — and reconciles its input with Zero
Framework Cognition: the threshold's input is the assessment's discrete
standing rather than a numeric confidence value, because no calibration
measurement for optimizer findings exists to make a number meaningful. A raw
analyzer confidence score is never the threshold's input.

### Deterministic gates

Everything the control plane decides about automatic repair is a
deterministic gate in code, applied to the assessment:

1. **Authorization** — who may elect automatic repair, and who may dispatch
   it.
2. **Catalog admission** — the finding's optimization type must be
   `eligible`.
3. **Standing threshold** — the assessment's standing must meet the election's
   configured minimum standing.
4. **Idempotency** — the canonical finding identity must not already have
   produced repair work.
5. **Budget** — the repair run must carry its own explicit cost and time
   caps.
6. **Revalidation** — the repair target's revision must still support the
   finding's evidence.
7. **Report terminality** — the report must have completed.

An assessment that is missing, malformed, `unknown`, failed, or bound to a
superseded evidence revision fails closed: the finding does not qualify, and
the reason is recorded rather than silently dropped.

## Bounded Automatic Repair Contract

### The run-start election

Automatic repair is elected per run, at run start, on the UI, the
authenticated API, and the MCP surface, with equivalent authorization. It is
opt-in and off by default: a run without the election behaves exactly like a
report-only run.

The election is a per-run election and never becomes a tenant-wide setting or
a recipe default. A schedule therefore cannot elect automatic repair: a
standing election on a recurring run is exactly the recipe default the policy
excludes, so scheduled runs are default-deny until a separate design decides
otherwise.

The election records:

| Field | Default | Meaning |
| --- | --- | --- |
| `enabled` | absent/false | Whether the run may queue repairs at all |
| `minimum_standing` | `supported` | The threshold a finding's assessment must meet |
| `cost_limit_cents` | explicit per-run default | Cost cap for each dispatched repair run |
| `time_limit_seconds` | explicit per-run default | Time cap for each dispatched repair run |

The default minimum standing is `supported` — the strictest standing. The
family is opt-in and automatic, so a wrong automatic repair costs more than a
skipped one.

### Dispatch conditions

Automatic repairs are dispatched only when the report's outcome is
`completed`. A `partial`, `cancelled`, or `budget_exhausted` report queues
nothing and records why. The complete report is delivered regardless of the
election, and findings that were not selected remain available for manual
selection.

Qualifying findings are dispatched through the base repair-handoff pathways
unchanged — a bounded repair issue or a PR-creation run through existing
authorized creation pathways — and each dispatched repair links back to its
source report and canonical finding.

### Idempotency, budgets, and scope

The automatic-repair idempotency key derives from the canonical finding
identity (project, recipe, claim, and affected symbols), not from the
occurrence or the run. A repeated occurrence of the same identity therefore
creates no second repair run, which is the base recurring-identity contract
extended to an automatic path.

Each dispatched repair run carries its own explicit cost and time caps; when a
cap is exhausted the collected evidence is preserved, as the base contract
requires for any run.

The repair scope stays bounded to the selected finding. A repair that would
change code beyond that finding requires explicit human authorization and is
not an automatic outcome.

### Standing by category

| Optimization type | Automatic-repair admission | Rationale |
| --- | --- | --- |
| Code Duplication | `eligible` | Scoped, evidence-backed, and bounded to the approved finding |
| Maintainability / Readability | `eligible` | Same shape as duplication, with the same counterevidence discipline |
| Performance | `eligible` | Prompt-first evidence is admissible; the standing threshold still applies per finding |
| Security Hardening | `manual_only` | Security repairs stay manual-only until a separately authorized accuracy and safety review finds that automatic hardening meets the confidence and blast-radius standards |
| Cost / Resource Efficiency | `denied` | Default-deny until a separate owner authorization, supported by evaluation evidence, moves it |
| Design / Architecture | `denied` | Default-deny; its findings are proposed actions, not auto-applicable rewrites |
| Test Coverage & Quality | `denied` | Default-deny until separately authorized; it also overlaps the base maintenance test-quality recipe |

The election can only narrow these standings. It can never widen them: naming
a `manual_only` or `denied` type in an election changes nothing, and only a
separate owner authorization moves a catalog standing.

## Staged Follow-On Types

The remaining four types land in order of risk and value, each stage only
when its predecessors' evaluation evidence supports it:

1. **Security Hardening** — tool-assisted where available. Repairs default
   to manual selection only.
2. **Cost / Resource Efficiency** — right-sizing, idle waste, unnecessary
   retries and data transfer. Prompt-first initially.
3. **Design / Architecture** — coupling, layering, and boundary
   recommendations, framed as proposed actions rather than auto-applicable
   rewrites.
4. **Test Coverage & Quality** — untested branches, flaky candidates, and
   testability refactors, reconciled with the base maintenance test-quality
   recipe rather than duplicating it.

Where a staged type has no credible tool evidence path, it lands prompt-first
and says so honestly in its reports.

## Issue Mapping

| Spec range | Subject | Delivery issue |
| --- | --- | --- |
| `MAINT-OPT-001`–`MAINT-OPT-007` | Catalog, type menu, snapshot retention | [#4493](https://github.com/viamin/paid/issues/4493) |
| `MAINT-OPT-010`–`MAINT-OPT-015` | Scope semantics | [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494) |
| `MAINT-OPT-020`–`MAINT-OPT-030` | First recipes and honest evidence | [#4494](https://github.com/viamin/paid/issues/4494) |
| `MAINT-OPT-035`–`MAINT-OPT-041` | Semantic assessment and deterministic gates | [#4495](https://github.com/viamin/paid/issues/4495) |
| `MAINT-OPT-045`–`MAINT-OPT-060` | Bounded automatic repair | [#4495](https://github.com/viamin/paid/issues/4495) |
| `MAINT-OPT-065`–`MAINT-OPT-070` | Staged follow-on types | [#4496](https://github.com/viamin/paid/issues/4496) |
| `MAINT-OPT-075`–`MAINT-OPT-077` | Rollout guard, provenance, evaluation evidence | [#4493](https://github.com/viamin/paid/issues/4493), [#4494](https://github.com/viamin/paid/issues/4494), [#4495](https://github.com/viamin/paid/issues/4495), [#4496](https://github.com/viamin/paid/issues/4496) |

[#4492](https://github.com/viamin/paid/issues/4492) is a tracking umbrella. It
coordinates the family and audits the evidence its children produce; it is
not an executable deliverable, and no claim above is satisfied by it.

## Rollout Guard

The family rides the base `maintenance_runs` tenant rollout guard, which is
default off. It adds no second switch: a tenant that cannot start a
maintenance run cannot start an optimization run, and a tenant that cannot
dispatch maintenance cannot queue an automatic repair. RDR-073's own guard
remains authoritative for tool attachment.

This segment changes no rollout state. It does not register a flag, does not
change a default, and does not enable maintenance or the family. Removing
the `maintenance_runs` guard remains a separate decision owned by the base
maintenance closeout.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Where the family lives in the intent tree | A leaf segment under the root, owning the `MAINT-OPT` namespace and extending the base `MAINT` contracts by reference | A child segment nested under `maintenance-runs`; a second run goal for optimization | The base maintenance segment is a leaf that owns its own EARS claims; nesting would blur which segment owns the base contracts while the base acceptance (#4635) is still open. Extension by reference keeps the base claims editable in place and greppable under `MAINT`. |
| Type selection representation | A code-defined catalog of entries, persisted as a key on the run snapshot | A run-contract enum; project-admin authoring UI | An enum turns a presentation menu into a schema migration every time a type is added, and the family is explicitly extensible. Authoring UI is deferred to a later stage; the catalog stays code-defined while the entry shape is proven. |
| Unknown type values | Degrade to a custom-objective maintenance run | Reject the start request | A stale client or a hand-written API call should not lose the user's request; the base contract already treats a free-text objective as a valid run. |
| Scope form | Free-form natural-language targets, no default limits | Paths-and-symbols only; a path/size filter | Optimization audits are chosen by area of concern — a feature, a page, a workflow — not by path prefix. Imposing a limit would silently narrow the user's question. |
| Evidence beyond the requested scope | Allowed, and treated as expected practice | Restricted to the requested scope | Findings about duplication or complexity are frequently wrong until the agent checks the callers, tests, and entry points that give the code meaning. Scope bounds recommendations, not the evidence that validates them. |
| Selection threshold input | The assessment's discrete standing (`supported` > `marginal` > `unsupported`, plus `unknown`) | A numeric confidence threshold over a model-emitted score; raw analyzer confidence | Zero Framework Cognition puts semantic judgment in the AI call and policy in code, and no calibration measurement for optimizer findings exists — a numeric scale here would be false precision. The threshold's shape (configured minimum, per run, findings only, full report always delivered) is preserved; only its input changes. Raw analyzer confidence is evidence, not a gate input. |
| Minimum standing default | `supported` | `marginal` | The family is opt-in and automatic. A wrong automatic repair costs more than a skipped one, so the default is the strictest standing that still admits a finding. |
| Report outcome that may dispatch repairs | `completed` only | `partial` as well | A partial report means a planned check did not complete, so its findings rest on an unknown fraction of the evidence. Dispatching from it would convert an honest coverage gap into an unauthorized change. |
| Election scope | Per run, at start, on the finding's own type | Tenant-wide default; recipe default; schedule-level election | The owner's recorded decision is a per-run election, never a tenant-wide or recipe default. A schedule-level election is the recipe default by another name, so scheduled runs are default-deny until separately designed. |
| Idempotency key | The canonical finding identity | The finding occurrence; the run | Occurrences are per-report by design, so keying on them would queue one repair per scan for the same underlying problem. The canonical identity is the base contract's unit of recurring work. |
| Repairs dispatched through | The unchanged base repair-handoff pathways | A dedicated automatic-repair pathway | The base pathways already carry authorization, provenance links, revision revalidation, and budget handling. A separate pathway would fork those guarantees. |
| Security hardening | `manual_only` until a separately authorized accuracy and safety review | Eligible from the start | A false security finding that is auto-repaired can harden nothing and break access control. The blast radius justifies excluding the category until it is measured. |
| Staged types' admission | `denied` until a separate owner authorization with evaluation evidence | `eligible` from the start | Cost, architecture, and test-quality findings are the least bounded and the least measured; their admission follows evidence, not optimism. |
| Election's effect on catalog standings | Narrow only | Override in either direction | An election is a user's per-run choice; a catalog standing is a policy the platform applies to everyone. Letting a run-local choice widen a policy would make the policy meaningless. |

## Open Questions & Future Decisions

### Resolved

1. ✅ The base maintenance contracts are reused rather than forked: the
   family adds a type selection, a scope form, recipe content, and a repair
   policy to the existing run/report/finding contracts.
2. ✅ The family adds no second rollout switch; `maintenance_runs` remains the
   single admission gate.

### Deferred

1. The owner decision on the precise policy text in this segment and the two
   base-claim reconciliations (`MAINT-011`, `MAINT-073`) — the standing
   semantics, the `supported` default, `completed`-only dispatch, the
   election-can-only-narrow rule, the `manual_only` / `denied` catalog
   standings, the idempotency key, and the schedule default-deny. Recorded
   on [#4636](https://github.com/viamin/paid/issues/4636); the family stays
   unimplemented until it is settled.
2. Catalog entry and run-snapshot column shapes, and the API response shapes
   for the type menu and the election — resolve during [#4493](https://github.com/viamin/paid/issues/4493)
   implementation, not before acceptance.
3. The rubric that produces the `repair_standing` values, and its version
   cadence — belongs with [#4495](https://github.com/viamin/paid/issues/4495);
   the standing vocabulary is fixed here, the rubric text is not.
4. The per-run default cost and time caps for an automatically dispatched
   repair run — resolve during [#4495](https://github.com/viamin/paid/issues/4495)
   against the base run budget defaults.
5. Whether a schedule may ever elect automatic repair, and under what
   standing — default-deny here; a separate design would have to justify why
   a standing election is not a recipe default.
6. The conditions under which a separately authorized review may move
   `Security Hardening` from `manual_only`, or a staged type from `denied` —
   the categories are excluded here; the review is a separate decision.

## What This Is Not

- Not a second run type. Optimization runs are maintenance runs with a type
  selection and a recipe.
- Not a second tool catalog. Evidence collectors resolve through RDR-073's
  attachment and matching contract, exactly as the base does.
- Not a second repair pathway. Automatic repairs travel the base repair
  handoff unchanged.
- Not a rollout. No flag is registered, no default is changed, and the family
  remains unavailable while `maintenance_runs` is off.
- Not an authorization for automatic repair of security findings, or of the
  staged types.
- Not an acceptance of the family. This segment is a proposal for human
  review.

## References

- [RDR-075: General Maintenance Runs](../../rdrs/RDR-075-general-maintenance-runs.md)
  — the base design, including the requirement that automatic repair needs a
  separately approved policy
- [`maintenance-runs` LLD](../maintenance-runs/maintenance-runs-design.md) —
  the base contracts (`MAINT-001`–`MAINT-073`) this segment extends
- [`maintenance-runs` EARS](../maintenance-runs/maintenance-runs-specs.md)
- [`facet-confidence` LLD](../facet-confidence/facet-confidence-design.md) —
  the shipped precedent for rubric-scored policy assessments that are not
  calibrated probabilities
- [RDR-073: Marketplace Tool Sidecars](../../rdrs/RDR-073-marketplace-tool-sidecars.md)
  — the attachment and matching contract the family's evidence collectors
  consume
- [#4492](https://github.com/viamin/paid/issues/4492) (tracking umbrella),
  [#4493](https://github.com/viamin/paid/issues/4493),
  [#4494](https://github.com/viamin/paid/issues/4494),
  [#4495](https://github.com/viamin/paid/issues/4495),
  [#4496](https://github.com/viamin/paid/issues/4496),
  [#4636](https://github.com/viamin/paid/issues/4636) (this prerequisite)
- `docs/STYLE_GUIDE.md` — Zero Framework Cognition and the `agent_harness`
  interface
