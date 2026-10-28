---
parent: PAID
prefix: AUTOMATION-PHASES
---

# Low-Level Design: Automation Phases and Work-Item Authorization

Implements [RDR-077](../../rdrs/RDR-077-automation-phases-and-work-item-authorization.md).

## Phase vocabulary

`Automation::Phases` is the single source of phase identity:

| Constant | Responsibility | Delivery order |
| --- | --- | --- |
| `discovery` | Idea → actionable intent (feature creation, intention gathering) | 0 |
| `issue_preparation` | Prepare existing intent for implementation (analysis, enhancement, clarification, readiness) | 1 |
| `coding` | Implement work and bring its PR to merge readiness (auto-pick, review, CI repair, conflicts, auto-continue) | 2 |
| `merge` | Integrate a ready PR (eligibility, approvals, auto-merge) | 3 |
| `release_deployment` | Publish and deliver merged software (release creation, deployment) | 4 |
| `operations` | Observe deployed software and manage operational responses | — (outside the delivery chain) |

`DELIVERY_CHAIN` orders the five delivery phases. `CONTINUATION_ENDPOINTS` is the
offered manual-continuation menu (`issue_preparation`, `coding`, `merge`).
`Phases.chain(from_phase:, through:)` returns the phases a grant covers: the
starting phase plus every later delivery phase up to and including the
endpoint. Operations never appears in a chain, and discovery is never reachable
from a coding or later start.

## Rollout guard

`automation_phases` is defined in `FeatureFlags::DEFINITIONS`, default off, and
every policy decision reads it through `Automation::RolloutGuard.enabled?`
(`FeatureFlags.enabled?(:automation_phases, project:)`). While off,
`Automation::EffectivePolicy` returns a permitted `legacy_policy` decision, so
existing execution and Inbox behavior is untouched.

The authorized project feature-flag surface refuses to disable the rollout for
a project with active continuation grants. Operators must finish or explicitly
revoke those grants and reconcile affected queued work before rollback, because
legacy policy cannot interpret the grant records.

## Project phase defaults

`projects.automation_phase_settings` (jsonb) stores:

```json
{ "phases": { "issue_preparation": false, "coding": true, "merge": true },
  "release": false, "deployment": false }
```

`Automation::PhaseSettings` is the only reader. A project with no stored
configuration reads derived defaults (`Automation::Phases::DerivedSettings`) so
pre-existing projects keep their effective capabilities:

| Phase | Derived from |
| --- | --- |
| `discovery` | `true` (operator-triggered, no standing automatic entry) |
| `issue_preparation` | `auto_enhance_enabled` |
| `coding` | `auto_pick_enabled \|\| auto_scan_prs \|\| auto_scan_security \|\| auto_fix_merge_conflicts` |
| `merge` | `auto_merge_enabled? \|\| auto_merge_mode != "off"` |
| `release_deployment` | `auto_release_granularity != "off"` |
| `operations` | `false` (project operations automation does not exist yet) |

Release and deployment are separate subordinate controls: turning the phase off
retains both values, and enabling one never enables the other.

`Automation::PhaseSettings::Update` applies a settings change and returns the
phases that transitioned disabled → enabled; that transition list is what drives
Inbox reconciliation (`INBOX-PHASE-RELEVANCE-004`, `-007`).

## Effective execution policy

```ruby
decision = Automation::EffectivePolicy.new(project:, phase:, work_item:, trigger:).call
decision.permitted?  # => true / false
decision.source      # => :legacy_policy | :manual_action | :continuation_grant | :project_defaults
decision.reason      # => stable symbol for audit records
```

Evaluation order:

1. Rollout guard off → permitted, `:legacy_policy`.
2. `:manual` trigger on an explicitly authorized manual action → permitted,
   `:manual_action`.
3. An active grant covering the phase and the work chain → permitted,
   `:continuation_grant`.
4. Project phase enabled → permitted, `:project_defaults`.
5. Otherwise blocked, reason `:phase_disabled`.

A grant never bypasses review methods, CI requirements, merge rules, budgets,
trust rules, tenant permissions, or scheduler safety holds — those are applied
after the phase decision by the existing paths.

## Continuation grants

`work_item_continuation_grants` is the durable record: project, work item
(issue), starting phase, endpoint, author, source, creation time, completion,
and revocation. `WorkItemContinuationGrant#covers_phase?` walks the delivery
chain; `#active?` requires neither completion nor revocation.
The author and work item must belong to the grant's project tenant.

`Automation::ContinuationGrantLookup.resolve(work_item:)` resolves the chain
from any work item in the delivery chain — the issue, its pull requests'
parent issue, or a run attached to either — so a grant survives issue →
implementation run → PR → review → repair. It deliberately does **not** walk
child issues, mentions, or dependency edges, so an additional or decomposed
issue needs its own authorization.

Completion and revocation:

- `complete!` is called when the endpoint's work lands (PR merged for a merge
  endpoint, PR merge-ready for a coding endpoint); reopening never reactivates.
- `revoke!` withdraws only the exception. Project defaults may still permit the
  work independently, which the revocation UI states explicitly.

## Manual starts

`Automation::ManualStart::Plan` is the shared form/API contract:

- `endpoints` — the applicable continuation choices for the selected action's
  phase, defaulting to that phase.
- `notice` — an `Automation::EffectivePolicyNotice` describing the phases that
  project policy permits beyond the chosen endpoint, the settings responsible,
  and conditional-authorization wording.
- `signature` — a digest of project policy state, independent of the user's
  endpoint and continuation selections.

`Projects::AgentRunsController#new` renders the endpoint selector and notice.
`#create` re-plans against current policy and compares the signature with the
submitted one: a mismatch returns the updated notice for review and creates no
run (`AUTOMATION-PHASES-011`). Grant creation requires permission to delegate
the covered actions; a merge endpoint requires permission to delegate merge.

There is deliberately no per-item "stop after this phase" override
(`AUTOMATION-PHASES-012`).

## Execution enforcement

- `Automation::FeatureActivation` gates every capability entry point through
  `Automation::Phases.for_capability(feature)` and the effective policy, so a
  disabled phase cannot be re-enabled by a trusted activation label or by a
  catch-all label.
- `AgentRuns::RecheckIssueEligibility` rechecks phase authorization at dequeue
  and cancels queued work whose authorization disappeared, without touching a
  claimed or running run. Retries that create a new execution pass the same
  gate.

## Migration preview

`Automation::Phases::MigrationPreview` reports, per project, the derived phase
defaults, which currently visible Inbox entries would leave the default Inbox
under those defaults, and which label-enabled work would lose automatic
execution. It is read-only and never enables anything.

## Operations boundary

Project operations describe project-runtime work. Paid's own platform health,
credential, and safety requests are project-independent: `Inbox::PhaseOwnership`
classifies them as platform requests with no phase, so a disabled Operations
phase never hides them and they never gain execution authority. See
[operations-ownership.md](operations-ownership.md).
