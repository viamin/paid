# RDR-077 Pilot Authorization and Live-Evidence Report — 2026-11-18

**RDR:** [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md)  
**Tracking issue:** #4638  
**Foundation/readiness dependency:** #4517 (accepted at `ee300f8deaa4cb0f11490178a42d9423e9729dd6`)  
**Reviewed repository revision:** `540107a61f803e0b346968a699833a505f312094`  
**Status:** blocked pending explicit authorized-owner pilot approval and the
shared #5133 schema-bootstrap disposition. The rollout remains off.

## Decision boundary

This report does not authorize a rollout and is not human evidence. The prior
readiness receipt and repository checks establish shipped foundations only.
They do not select a project, approve settings, or establish live execution or
rollback outcomes. No `automation_phases` switch, tenant feature map, project
phase setting, grant, Inbox request, release, or deployment was changed while
preparing this report.

`automation_phases` remains a default-off guard. The migration preview is
read-only: it derives settings and reports Inbox, label-enabled-work, grant,
and provenance information without enabling work or creating grants
(`AUTOMATION-PHASES-014` and `AUTOMATION-PHASES-015`).

## Authorization packet required from an accountable owner

The owner must record, on #4638 or a linked immutable approval record, all of
the following before an operator changes a rollout switch:

1. selected project full name and ID, tenant, and the accountable owner;
2. exact rollout target (`automation_phases` project actor only), start/end
   window, and an explicit statement that no tenant/global/percentage rollout
   is approved;
3. exact phase and subordinate settings; the proposed conservative baseline is
   `discovery=false`, `issue_preparation=false`, `coding=true`, `merge=false`,
   `release_deployment=false`, `operations=false`, `release=false`, and
   `deployment=false`;
4. exact enabled coding capabilities and any trusted label configuration,
   including their projected work-item IDs; the default proposal is PR-only
   review/security/repair work, with no auto-pick or issue preparation;
5. the reviewed migration-preview payload, including derived and configured
   settings, Inbox entries leaving the default list, active-grant count,
   label-enabled work, provenance status, and bounded replay/cost caveat;
6. the acceptance of ordinary trust, checks, budget, tenant, child
   non-inheritance, and release/deployment boundaries; and
7. stop conditions and the named operator authorized to revoke grants and
   perform the guarded rollback.

Automatic profile selection, permission to edit issue bookkeeping, a planning
label change, or an agent-generated comment is not this authorization.

## Criterion-to-evidence plan

| Criterion | Smallest credible verification | Current result |
| --- | --- | --- |
| Present preview, scope, effects, costs, protections, and rollback to an owner | Owner reviews the live project's `MigrationPreview` payload and this packet; retain its URL and revision | Not run: no selected project or owner review |
| Obtain exact authorization before changing a switch | Owner-authored, inspectable approval naming project, settings, window, and stop conditions | Blocked: no approval recorded |
| Execute and preserve live migration/rollback evidence | Authorized operator captures before/after policy, Inbox/grant behavior, execution IDs, rollback request/result, and timestamps through existing settings/run surfaces | Not run: activation is unauthorized |
| Preserve guardrails and scope | Inspect the live payload and execution records; verify only selected project actor is enabled and no child/release/deployment scope is admitted | Not run: depends on authorization |
| Publish revision-bound recommendation and actionable gaps | This report plus a post-pilot report linked from #4638; failures remain in Inbox and #4638 | Partial: this pre-authorization report identifies blockers, not live outcomes |
| Close only with reviewable evidence | Owner reviews the complete authorization and live receipt; #4518 separately consumes it | Not run: #4638 remains open |

The recurring guard and preview contracts are covered by the permanent focused
specifications named in `docs/intent/automation-phases/automation-phases-specs.md`:
`spec/services/automation/phases/migration_preview_spec.rb`,
`spec/services/automation/rollout_guard_spec.rb`, and
`spec/services/automation/phases/rollback_protection_spec.rb`. They are not
substitutes for the human and external evidence above.

## Live execution and rollback receipt template

After authorization, append a new revision-bound section to this report with:

- authorization URL, author, timestamp, selected project ID/full name, exact
  approved settings, capability labels, window, and approval revision;
- pre-activation feature-flag state, phase settings, effective-policy results,
  migration-preview JSON (including provenance status and costs), Inbox
  identities/counts, active grants, and queued-run IDs;
- each live scenario's initiating actor, run/grant/Inbox identifiers, policy
  source, trust/check/budget result, elapsed time, and cost;
- proof that a child work item did not inherit authority and that release,
  deployment, and unrelated projects received none;
- rollback attempt, active-grant and queued-work reconciliation outcomes,
  final flag/settings/policy/Inbox/grant state, failures, and remediation
  owner; and
- a recommendation limited to this pilot, with #4518 as the separate final
  closeout decision.

## Required disposition and recommendation

Do not activate the pilot or close #4638 yet. The accountable owner must first
approve a fully instantiated packet, and the shared #5133 schema-bootstrap
isolation defect must be resolved or explicitly accepted for this pilot. Once
those conditions hold, run only the approved project-scoped scenario, preserve
the receipt above, and keep unresolved evidence in Inbox and #4638. Broader
rollout remains a separate authorization.
