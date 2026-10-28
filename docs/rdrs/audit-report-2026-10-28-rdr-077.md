# RDR-077 Acceptance Audit — 2026-10-28

Scope: issue #4511, using RDR-077 and
`docs/intent/automation-phases/` as authority. The rollout flag remains
default-off. This audit does not adopt the unapproved proposal in #4624.

## Criterion evidence

| Acceptance criterion | Evidence and result |
| --- | --- |
| Project defaults and independent subordinate controls | `Automation::PhaseSettings`, its update service, and `phase_settings_spec.rb` persist the six phase defaults while retaining independent release and deployment values. `Automation::Phases` and the manual-start plan keep auto-pick entry distinct from later coding continuation. Satisfied. |
| Scoped, auditable grants through merge | `WorkItemContinuationGrant`, the authorization migration, and model/request specs retain project, actor, work item, start phase, endpoint, source, completion, revocation, and timestamps. Endpoints are limited to preparation, coding, and merge; manual starts remain available when defaults are disabled. This audit added model enforcement for a present actor and same-project work item. Satisfied. |
| Defaults supplemented without inherited authority | `Automation::EffectivePolicy`, `Automation::ContinuationGrantLookup`, and their specs apply grants as an additional authority source, expose no per-item stopping override, and do not traverse dependencies, mentions, or child issues. Satisfied. |
| Actor, tenant, and delegation enforcement | Project-scoped controller lookup, `ProjectPolicy`, grant lookup, dequeue rechecks, and existing execution guards retain tenant isolation, review/CI/merge rules, budgets, trust, and holds. This audit corrected non-merge delegation to require `run_agent?`; merge continues to require `delegate_merge?`. Missing authority fails closed. Satisfied. |
| Default-off rollout and protected rollback | `FeatureFlags::DEFINITIONS`, `Automation::RolloutGuard`, and rollout specs use `FeatureFlags.enabled?(:automation_phases, project:)`. `docs/FEATURE_FLAGS.md` now documents the authorized project task, coordinated pilot validation, and rollback sequence. This audit added refusal of project or global disable while affected active grants exist. Satisfied; no pilot is authorized by this audit. |
| Shared decisions and explanations | `Automation::EffectivePolicy`, `Automation::EffectivePolicyNotice`, `Automation::ManualStart::Plan`, Inbox phase relevance/ownership services, project UI, and JSON responses share authorization decisions and notices. Platform requests remain visible independently of project Operations settings. Satisfied. |

## Verification

- Focused phase, grant, request, and dequeue suite: 148 examples, 0 failures.
- Structural coherence and repository lint are recorded in the implementing
  commit/PR checks.

No acceptance item remains without a concrete code, test, or documentation
owner. Pilot activation and operational evidence remain separate rollout work;
this audit does not enable the flag for any project.
