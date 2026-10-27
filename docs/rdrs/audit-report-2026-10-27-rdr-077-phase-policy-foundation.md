# RDR-077 Phase Policy and Continuation Grants — Acceptance Audit — 2026-10-27

- **Issue**: [#4511](https://github.com/viamin/paid/issues/4511) — RDR-077: Phase
  policy, continuation grants, and rollout foundation
- **Umbrella**: [#4509](https://github.com/viamin/paid/issues/4509) (closed by
  [#4586](https://github.com/viamin/paid/issues/4586)); this audit tracks the
  parent for tracking only and does not reopen it
- **Design**: [RDR-077](../rdrs/RDR-077-automation-phases-and-work-item-authorization.md),
  merged via [#4508](https://github.com/viamin/paid/issues/4508)
- **Intent**: `docs/intent/automation-phases/`,
  `docs/intent/inbox-phase-relevance/`
- **Conclusion**: **Implemented with bounded corrections.** The phase vocabulary,
  project phase defaults, continuation grants, authorization evaluation, and the
  default-off rollout guard are shipped and covered by focused tests. The audit
  corrected four residual gaps in the grant record itself — an unscoped work
  item, a cross-tenant author, a missing author, a missing audit trail — and strengthened the
  delegation permission check so it is enforced by the shared plan rather than
  only for the merge endpoint. No rollout was authorized and no flag was
  enabled.

Closed child issues were not used as evidence. Every row below cites shipped
code and an executable test.

## Acceptance evidence

| #4511 acceptance criterion | Shipped evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Persist project phase defaults while retaining subordinate settings; keep release and deployment controls independent and distinguish auto-pick entry from coding continuation | `app/services/automation/phase_settings.rb:11` (`projects.automation_phase_settings`), `:40` (`phase_enabled?`), `:53`/`:57` (separate `release`/`deployment` controls), `:80` (derived defaults for projects without stored settings); `app/services/automation/phase_settings/update.rb:66` (only known phase keys are persisted, subordinate capability values are untouched) | `spec/services/automation/phase_settings_spec.rb` — "retains every subordinate capability value when a phase is turned off", "never enables release or deployment implicitly from the phase switch", "keeps release and deployment independent of each other", and the new "coding entry and continuation" examples proving the phase switch does not conflate auto-pick entry with continued coding | Satisfied |
| Persist scoped grants with actor, work lineage, endpoint, completion/revocation and audit data. Supported endpoints end at preparation/coding/merge; manual actions remain available in disabled phases | `app/models/work_item_continuation_grant.rb` (project, issue, `created_by`, `revoked_by`, `start_phase`, `endpoint`, `completed_at`, `revoked_at`, plus the new scope/author validation and audit trail); `app/services/automation/phases.rb:38` (`CONTINUATION_ENDPOINTS` ends at merge); `app/services/automation/continuation_grant_lookup.rb:17` (work lineage across issue → run → PR → review → repair); `app/services/automation/effective_policy.rb:55` (a manual action is permitted in a disabled phase) | `spec/models/work_item_continuation_grant_spec.rb`, `spec/services/automation/effective_policy_spec.rb`, `spec/services/automation/continuation_grant_lookup_spec.rb`, `spec/requests/projects/agent_runs_continuation_spec.rb` | Satisfied after correction: the grant record now requires its author and rejects a work item from another project, and each creation and revocation writes an account-scoped audit event |
| Grants supplement project defaults without a per-item stopping override. Additional issues, including linked children, never inherit execution authority | `app/services/automation/phases.rb:95` (`chain` never reaches discovery, release, deployment, or operations); `app/services/automation/continuation_grant_lookup.rb:17` (the chain does not walk child issues, mentions, or dependency edges); `app/services/automation/manual_start/plan.rb` (no stop option is offered); `app/services/automation/effective_policy_notice.rb:52` (the endpoint does not suppress independently enabled project automation) | `spec/services/automation/manual_start/plan_spec.rb` — "offers no per-item stop beyond the chosen endpoint"; `spec/services/automation/continuation_grant_lookup_spec.rb` — child, mention, and dependency cases; `spec/services/automation/effective_policy_spec.rb` — "does not authorize release or deployment through a merge endpoint" | Satisfied |
| Enforce actor/tenant scope and permission to delegate covered actions, including merge. Preserve checks, reviews, trust, budgets and safety holds; missing configuration remains a blocker | `app/services/automation/manual_start/plan.rb:139`/`:143` (the plan itself requires delegation permission: merge needs `ProjectPolicy#delegate_merge?`, every other endpoint needs `ProjectPolicy#run_agent?`); `app/policies/project_policy.rb` (`delegate_merge?`, `run_agent?`); `app/models/work_item_continuation_grant.rb:98` (a grant may not name another project's work item); `app/services/automation/strategies/auto_merge.rb` (checks, owner approval, review methods, dependency resolution and branch-protection blockers still decide a merge, so a grant never waives them); `app/services/agent_runs/recheck_issue_eligibility.rb` (budgets, trust, pauses and safety holds still apply at dequeue) | `spec/services/automation/manual_start/plan_spec.rb` — "requires permission to delegate merge", "refuses a continuation for an actor who may not start work in the project", "refuses a grant for a work item outside the project"; `spec/models/work_item_continuation_grant_spec.rb` — scope examples; `spec/requests/projects/agent_runs_continuation_spec.rb` — "returns unauthorized merge delegation to the form without creating a run"; `spec/services/automation/strategies/auto_merge_spec.rb` — the merge stays blocked (noop) while owner approval, blocking reviews, review freshness, checks, or dependency resolution are missing, so absent configuration is a visible blocker rather than an exemption | Satisfied after correction: the delegation check no longer treats every non-merge endpoint as self-authorizing |
| Add `automation_phases` to `FeatureFlags::DEFINITIONS`, default off, and wire via `FeatureFlags.enabled?(:automation_phases, project:)`. Confirm and document authorized pilot management, coordinated activation, and rollback protection for active grants | `app/services/feature_flags.rb:102` (definition, default off, rollout plan and cleanup criteria); `app/services/automation/rollout_guard.rb:10`/`:14` (every decision reads `FeatureFlags.enabled?(:automation_phases, project:)`); `docs/intent/automation-phases/automation-phases-design.md` — "Rollout operations" (pilot management, coordinated activation, rollback protection) | `spec/services/automation/rollout_guard_spec.rb`; `spec/services/automation/effective_policy_spec.rb` — "keeps the legacy policy while the flag is off" | Satisfied; the automated rollback block is owned by [#4517](https://github.com/viamin/paid/issues/4517) and is recorded as a follow-up, not as shipped behavior |
| Provide shared decision/explanation interfaces for manual authorization, project defaults, grants, Inbox consumers and UI/API notices; fail closed on missing authority without hiding platform health | `app/services/automation/effective_policy.rb` (the one decision interface, with `source`/`reason` for audit records); `app/services/automation/effective_policy_notice.rb` (the one explanation interface, with a policy signature for submission-time re-evaluation); `app/services/automation/phase_settings.rb` and `app/services/automation/continuation_grant_lookup.rb` (the shared building blocks the Inbox consumes); `app/services/inbox/phase_ownership.rb` (platform health, credential, safety and unclassified requests carry no phase and stay visible) | `spec/services/automation/effective_policy_spec.rb`, `spec/services/automation/effective_policy_notice_spec.rb`, `spec/services/inbox/phase_ownership_spec.rb`, `spec/services/inbox/phase_relevance_spec.rb` | Satisfied |

## Corrections made by this audit

1. **Grant scope.** `WorkItemContinuationGrant` accepted a grant whose work
   item or author belonged to another account. The record now rejects both,
   and `Automation::ManualStart::Plan#build_grant` refuses a foreign work item
   with a plan error instead of a persistence error.
2. **Grant author.** A grant could be persisted with no author, so delegated
   automation authority was not always attributable. Creation now requires the
   author; a later user deletion still nullifies the reference.
3. **Grant audit trail.** Grant creation and revocation now write an
   account-scoped activity event naming the actor, the work item, the starting
   phase, and the endpoint. Completion stays on the grant row.
4. **Delegation permission.** `Automation::ManualStart::Plan` treated every
   non-merge endpoint as self-authorizing, so the check depended on the calling
   controller. The plan now requires permission to start the covered action for
   non-merge endpoints, and refuses unauthorized grant requests on its own.

Each correction is covered by a failing-first test under the approved EARS
claims `AUTOMATION-PHASES-009` and the new `AUTOMATION-PHASES-019`, and the
intent documents record the behavior before the code changed.

## Observations that are not gaps in this scope

- **No per-item stop exists, and the HLD paragraph that reads like one
  belongs to an unapproved proposal.** The high-level design describes an
  authorization whose endpoint "is an enforceable stop, even where project
  defaults would otherwise proceed", and points at
  [RDR-078](../rdrs/RDR-078-bounded-delivery-phase-authorization.md), which is
  `Proposed` and tracked by [#4624](https://github.com/viamin/paid/issues/4624).
  The shipped continuation grant follows RDR-077's rule instead: the endpoint
  bounds the grant and never suppresses independently enabled project
  automation (`AUTOMATION-PHASES-012`). No bounded-stop behavior was added
  here, and the high-level design was not changed, because that policy is not
  approved for implementation.
- **Execution enforcement is not this issue's scope.** Applying the effective
  policy to every entry, retry, and follow-up path is
  [#4512](https://github.com/viamin/paid/issues/4512); grouped phase settings
  and the work-detail/API notice surfaces are
  [#4513](https://github.com/viamin/paid/issues/4513); Inbox ownership and
  relevance are [#4514](https://github.com/viamin/paid/issues/4514); personal
  Inbox removal is [#4515](https://github.com/viamin/paid/issues/4515). The
  audit did not implement any of them.
- **The Inbox resolves phase relevance with its own batched query set.**
  `Inbox::PhaseRelevance::Context` reproduces the continuation chain
  (`app/services/inbox/phase_relevance/context.rb:58`) instead of calling
  `Automation::ContinuationGrantLookup#chain_issue_ids` per entry, to keep the
  Inbox to bounded queries. The two agree on the shipped chain semantics; the
  duplication is a deliberate performance choice and not a policy divergence.

## Rollout guard and verification

`automation_phases` remains defined and default off. No project had the flag
enabled by this audit, and the flag's own rollout plan still requires phase
mappings, capability configuration, grant storage, and Inbox classification to
be validated together before a pilot. The documented rollback procedure
requires draining or revoking a project's active grants and reconciling its
queued work before the flag is disabled; the automated block that refuses to
disable the flag while grants remain active is owned by
[#4517](https://github.com/viamin/paid/issues/4517).

The focused audit suite passed on 2026-10-27:

```text
bundle exec rspec \
  spec/services/automation \
  spec/services/inbox \
  spec/models/work_item_continuation_grant_spec.rb \
  spec/models/account_activity_event_spec.rb \
  spec/requests/projects/automation_phases_spec.rb \
  spec/requests/projects/agent_runs_continuation_spec.rb \
  spec/requests/inbox_phase_relevance_spec.rb \
  spec/services/agent_runs/recheck_issue_eligibility_spec.rb
```

Result: **1228 examples, 0 failures**. `bin/lint --changed` reported no
offenses, and `bin/coherence-check.mjs` reports no reverse orphan or
uncovered-spec drift for the `AUTOMATION-PHASES` segment. The repository-wide
soft-block signals the checker prints (untagged files, unrelated stale arrows,
and the `BOUNDED-PHASE-AUTHORIZATION` active gaps that belong to the
unapproved RDR-078 proposal) are outside this issue's scope and were left
untouched.
