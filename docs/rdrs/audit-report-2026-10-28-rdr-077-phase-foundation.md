# RDR-077 Phase Policy and Authorization Foundation Acceptance Audit

**Date:** 2026-10-28  
**Issue:** #4511  
**Authority:** [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md),
[automation-phases LLD](../intent/automation-phases/automation-phases-design.md), and
`AUTOMATION-PHASES-001`–`018`  
**Verdict:** Accepted after two bounded authorization and rollback corrections

## Acceptance evidence

| Criterion | Shipped evidence | Verification |
| --- | --- | --- |
| Project phase defaults retain subordinate settings; release and deployment remain independent; auto-pick entry differs from coding continuation | `Automation::Phases`, `Automation::PhaseSettings`, `Automation::PhaseSettings::Update`, and `projects.automation_phase_settings` provide the canonical six phases, retain the complete stored phase/control map, derive legacy-compatible defaults, and model release/deployment independently. Coding derivation treats auto-pick as one entry capability without making it the continuation authority. | `spec/services/automation/phases_spec.rb`, `phase_settings_spec.rb`, and `effective_policy_notice_spec.rb` (`AUTOMATION-PHASES-001`, `-002`, `-015`, `-016`). |
| Scoped grants persist actor, lineage, endpoint, completion/revocation, and audit data; endpoints stop at merge; manual actions remain available | `WorkItemContinuationGrant` stores project, issue, start phase, endpoint, source, author, timestamps, completion, and revocation actor/time. `Automation::Phases::CONTINUATION_ENDPOINTS` ends at issue preparation, coding, and merge. `Automation::ManualStart::Plan` and `Projects::AgentRunsController` preserve explicit manual starts in disabled phases. | Model, lookup, manual-plan, request, and PR-ready activity specs (`AUTOMATION-PHASES-004`, `-005`, `-008`). |
| Grants supplement defaults; no item stopping override; additional and child issues do not inherit authority | `Automation::EffectivePolicy` accepts either grants or project defaults. `Automation::ContinuationGrantLookup` follows only an issue/PR/run continuation chain and deliberately excludes children, mentions, dependencies, and other project work. The manual plan exposes no stopping override. | `continuation_grant_lookup_spec.rb`, `effective_policy_spec.rb`, and `manual_start/plan_spec.rb` (`AUTOMATION-PHASES-006`, `-007`, `-012`). |
| Actor/tenant scope and delegation permission, including merge; existing safety policy remains in force; missing configuration blocks | Controller lookup uses the project policy scope; grant lookup constrains project and work lineage; merge delegation uses `ProjectPolicy#delegate_merge?`; non-merge delegation now uses `ProjectPolicy#run_agent?`, closing an evidence-found cross-account service-call gap. `Automation::EffectivePolicy` supplies phase authority only, leaving reviews, CI, merge rules, trust, budgets, and safety holds to existing gates. | New outsider rejection in `manual_start/plan_spec.rb`, plus request, effective-policy, and dequeue-recheck specs (`AUTOMATION-PHASES-003`, `-007`, `-009`, `-013`). |
| Default-off rollout guard, authorized pilot management, coordinated activation, and rollback protection | `automation_phases` remains in `FeatureFlags::DEFINITIONS`; `Automation::RolloutGuard` reads `FeatureFlags.enabled?(:automation_phases, project:)`; its rollout metadata names the authorized project-scoped pilot and coordinated prerequisites. While off, effective policy returns `legacy_policy`. `FeatureFlags.disable!` now blocks project rollback while an active continuation grant exists and directs the operator to complete/revoke grants and reconcile queued work. | New active-grant rollback example in `rollout_guard_spec.rb`, plus migration-preview and effective-policy specs (`AUTOMATION-PHASES-014`, `-015`). |
| Shared decisions and explanations cover manual, defaults, grants, Inbox, and UI/API; missing authority fails closed without hiding platform health | `Automation::EffectivePolicy::Decision` exposes permitted/source/reason; `Automation::EffectivePolicyNotice` and `ManualStart::Plan` share the form/API explanation and stale-policy signature; Inbox phase relevance consumes the same policy and grant lookup. Unknown ownership and platform-health items remain visible, while absent execution authority returns `phase_disabled`. | Effective-policy, notice, manual request, Inbox ownership/relevance/queue/count/availability, and API Inbox specs (`AUTOMATION-PHASES-003`, `-010`, `-011`, `-017`; `INBOX-PHASE-RELEVANCE-001`–`010`). |

## Corrections made by this audit

1. Non-merge continuation grants previously treated delegation as unconditionally
   permitted inside `Automation::ManualStart::Plan`. They now require the same
   tenant-aware `ProjectPolicy#run_agent?` authority as the covered manual action.
2. The rollout definition documented active-grant rollback protection, but the
   project-scoped disable operation did not enforce it. `FeatureFlags.disable!`
   now rejects disabling `automation_phases` for a project with active grants.

No proposal from #4624 was used, no new phase policy or EARS identifier was
introduced, and the rollout remains default-off. Pilot activation and broad
rollout remain separately authorized release operations.
