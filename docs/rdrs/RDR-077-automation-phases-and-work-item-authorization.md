# RDR-077: Automation Phases and Work-Item Authorization

## Metadata

- **Date**: 2026-10-17
- **Status**: Draft
- **Type**: Architecture + Automation + Inbox UX
- **Related Issues**: #4509, #4510, #4511, #4512, #4513, #4514, #4515, #4516, #4517, #4518 (planning work; implementation remains subject to design and release gates)
- **Related RDRs**: [RDR-023](RDR-023-automation-modularization-architecture.md), [RDR-053](RDR-053-new-feature-creation.md), [RDR-063](RDR-063-operational-supervisor-delivery-health.md), [RDR-066](RDR-066-feature-intent-approval-lifecycle.md), [RDR-069](RDR-069-question-centered-chat-exploration.md), [RDR-071](RDR-071-confidence-driven-issue-delivery.md), [RDR-074](RDR-074-project-readiness.md), [RDR-076](RDR-076.md).
- **Implementation status**: Proposal only. No runtime changes or implementation issues are created by this document.

## Problem Statement

Paid exposes individual automation switches without a common lifecycle model.
Operators cannot clearly express which stages Paid should manage, and disabling
automatic issue work does not remove its outstanding questions from the Inbox.
A project intended only to maintain and merge existing PRs can therefore retain
an Inbox dominated by issue-preparation requests.

Project defaults also cannot fully describe explicitly requested work. An
operator must be able to start a manual run in a disabled phase and optionally
authorize automatic continuation of that particular work through a chosen
endpoint, without enabling automation across the project.

## Context and Research Findings

The current implementation separates scheduling eligibility from Inbox visibility:

- `Project#cancel_queued_auto_pick_runs` cancels queued auto-pick work when
  auto-pick is disabled; this does not clear saved issue questions or stop states.
- `Automation::FeatureActivation.issue_auto_enhance_enabled?` permits trusted
  per-issue activation labels to enable enhancement when its project default is
  off, except in Paid-local activation mode.
- `Inbox::Queue` derives clarification and manual-review entries from open
  issues' `paid_state`. Its project scope explicitly does not gate visibility
  on auto-pick eligibility. Counts and availability have corresponding paths.
- `manual_review` has multiple causes, including exhausted enhancement rounds
  and dependency-blocked partial completion. The state alone cannot identify
  which automation phase owns a request.
- The HLD's **No silent stops** tenet requires stops to remain discoverable,
  with their reason and recovery action. Removing an item from the actionable
  Inbox must preserve that information.

Relevant intent lives in `docs/intent/automation-activation-labels/`,
`docs/intent/issue-enhancement/`, `docs/intent/confidence-driven-delivery/`,
`docs/intent/inbox-foundation/`, and `docs/intent/operator-inbox/`.
This proposal changes their shared policy; implementation must reconcile them.

## Proposed Solution

### 1. A shared phase vocabulary

| Phase | Responsibility | Representative capabilities | Completion boundary |
| --- | --- | --- | --- |
| Discovery (pre-automation) | Turn an idea into actionable intent | `create_feature`, intention gathering, feature exploration | An issue or feature document exists, with applicable approval obligations satisfied |
| Issue preparation | Prepare existing intent for implementation | Issue analysis, enhancement, clarification, readiness assessment | The issue is ready for coding under project policy |
| Coding | Implement work and bring its PR to merge readiness | Auto-pick, implementation, code review and feedback cycles, auto-continue, CI repair, conflict resolution | A PR is open, out of draft, and satisfies required checks and project review requirements |
| Merge | Integrate a ready PR | Merge eligibility, merge approvals, auto-merge | The PR is merged |
| Release & Deployment | Publish and deliver merged software | Version publication, release creation, deployment | The configured release or deployment completes with its required validation |
| Operations | Observe deployed software and manage operational responses | Elevated-error monitoring, incoming error reports, incident triage | Defined by each operational capability; no universal terminal state |

These phases classify responsibility. They are not a mandatory linear workflow:
work may start with an existing issue or PR, and new feedback can return a
merge-ready PR to coding. Opening a PR does not end coding automation.
Discovery remains before issue automation, but has a phase identity for settings,
manual work, and Inbox classification.

Auto-pick is the automatic entry mechanism for coding. Disabling auto-pick does
not disable continued coding work on manually started issues or existing PRs.

Verification is an activity within the phase it supports, subject to the same
execution authorization and Inbox ownership rules as other work. Code review
and CI belong to Coding, deployment validation to Release & Deployment, and
runtime health checks to Operations. Standalone manual verification is classified
by the responsibility it assesses. Mapping individual verification capabilities
belongs to the implementation inventory; verification needs no separate phase
or authorization exception.

Maintenance is also an activity within the phase whose responsibility it serves.
Verification assesses whether expectations are met; maintenance changes or
preserves the condition of the software. Neither introduces a separate phase,
grant type, or Inbox policy. Map individual maintenance capabilities alongside
verification and other capabilities in the implementation inventory.

Operations describes project-runtime work. Paid's own infrastructure health and
platform safety controls are not optional project operations automation.
An incident can originate in operations and create a remediation issue; the
incident's origin does not authorize issue preparation or coding of that issue.
Release & Deployment is a separate phase after merge. Merging does not itself
authorize publishing or deployment. The phase has separate subordinate controls
for release and deployment; enabling one does not enable the other. This RDR
classifies existing capabilities without introducing new deployment execution.

### 2. Project defaults and capability settings

Project settings group controls into the six phase sections. Each section has
a phase enable switch, an explanation of its boundary, and subordinate capability
controls. Turning a phase off retains those controls' configured values.

A disabled phase grants no standing authorization for automatic work in that
phase. Activation labels cannot override a disabled phase. Within an enabled
phase, existing capability and trusted-label rules determine eligible actions.
Automatic entry and automatic continuation remain distinguishable controls.

For example, a project can disable discovery and issue preparation, enable
coding with auto-pick off and auto-continue on, and enable merge. Paid can then
maintain eligible existing PRs without selecting new issues to implement.

### 3. Manual starts and explicit continuation authorization

Authorized users can start manual runs in any phase regardless of the project's
phase defaults. A manual run receives the same phase classification as an
automatic run performing the same action.

The trigger form offers **Automatically continue this work**, unchecked by
default. When selected, an endpoint selector offers the applicable choices:

- Automate through issue preparation.
- Automate through coding.
- Automate through merge.

The initial endpoint defaults to the selected action's phase where that endpoint
exists. Inapplicable endpoints are omitted. Without continuation authorization,
the manual start authorizes the selected action and interactions needed to
finish it; later automatic actions require their own project authorization.

A continuation authorization covers the current phase and the subsequent
delivery phases necessary to reach its endpoint. Starting in coding and choosing
merge does not authorize discovery or unrelated issue enhancement. The offered
continuation endpoints end at merge; they do not grant Release & Deployment or
Operations authorization. Project settings can independently authorize release
or deployment after merge, which manual-start forms must explain under the
same effective-policy notice rules. Operations is not a delivery endpoint and
requires separate authorization for operational responses.

The grant belongs to the work item and its explicitly linked continuation
chain, rather than the first agent run. It survives transitions from issue to
implementation run, PR, review, and repair runs. It does not spread through a
mere issue mention, shared project, dependency, or a newly discovered task.
Creating additional issues, including explicitly linked child issues, does not
propagate the grant or authorize their execution. Each additional issue needs
its own manual authorization or applicable project automation. Authorization
across decomposed features is outside this RDR; existing decomposition paths
do not imply grant inheritance.

Within scope, the grant authorizes the automatic capabilities necessary for its
endpoint even when project phase or automatic-start/continuation switches are
off. Required review methods, CI requirements, merge rules, budgets, trust rules,
tenant permissions, and scheduler safety holds still apply. A missing required
capability configuration creates a visible blocker, not an implicit exemption.

The endpoint bounds the grant; it does not prohibit independently enabled
project automation. There is no per-item stopping override. When the grant ends,
project automation may continue the work under its normal eligibility rules.

Every form allowing a manual start must explain before submission when the
selected endpoint will not be the effective automation stopping point under the
current settings. The notice identifies the later phases that project policy
permits and the settings responsible. It updates when the selected action,
endpoint, or project changes, and also applies when automatic continuation is
unchecked but project defaults permit follow-up work. For example:

> You selected automation through coding. This project's merge automation is
> enabled, so Paid may also merge the PR once its checks and merge requirements
> are satisfied.

Describe continuation as conditional authorization, not a guarantee of merging
or completion. Show the same effective-policy explanation on work details and
return it to API clients creating manual work. Re-evaluate against current
policy at submission so a stale form cannot silently omit a newly permitted
continuation; return an updated notice for review if that continuation changed.

Grants record their author, scope, endpoint, creation time, and revocation.
Only users permitted to delegate the covered actions may create or extend them;
automating through merge requires permission to delegate merge. Grants are
visible and revocable on work details. Reaching the endpoint completes the grant;
reopening work does not silently reactivate it.

### 4. Effective execution policy

All entry points use one effective policy, including schedulers, labels, manual
forms, API actions, queue execution, retries, and workflow follow-ups:

1. Identify the action's phase, work scope, and required capabilities.
2. Establish authorization from project defaults, the explicit manual action,
   or an applicable continuation grant.
3. Apply the remaining execution, permission, and safety policies.
4. Record why the action is permitted or blocked.

Recheck authorization before queued work starts and before subsequent actions.
Disabling a project phase withdraws project authorization but preserves explicit
item grants. Revoking a grant withdraws that exception; project defaults can
still independently permit work. Explain this distinction in the revocation UI.

Neither change abruptly terminates an already-running action. It prevents new
actions that no longer have authorization; existing explicit cancellation
remains available. Retries that start a new execution recheck authorization.
Disabling a phase is therefore distinct from an emergency pause or cancellation.

### 5. Phase ownership and Inbox relevance

Every phase-owned request records its responsible phase and originating work.
Assign ownership when the request is produced; do not infer it from the generic
`needs_input` or `manual_review` state. A CI repair blocker belongs to coding;
an enhancement question belongs to issue preparation; a merge approval belongs
to merge. Origin and current responsibility are separate attributes.

A phase-owned item appears in the default actionable Inbox when:

- Its phase is enabled for the project; or
- An active continuation grant covers that phase and work; or
- It is needed to complete an explicitly started manual action that remains
  outstanding, even without automatic continuation.

Existing authorization, actionability, and personal removal rules still apply. Unresolved items
outside these conditions remain accessible in a **Disabled phases** view and
on work details, with the stop reason and recovery action. Hiding an item does
not resolve it, clear questions, remove GitHub comments, or alter issue readiness.
Manually answering a hidden request does not itself grant automatic continuation.

Re-enabling a phase reconciles outstanding requests before restoring relevant
items. Satisfied, closed, or superseded requests do not return as actionable.
Lists, counts, navigation badges, availability indicators, search filters, chat
admission, and direct-link access share the same policy. Authorized users may
inspect a hidden request directly; actions that start work still require
execution authorization.

Project-independent platform health, credential, and safety requests remain
visible under their own policy. They must not disappear because a project
operations phase is off. Unknown legacy ownership remains visible with an
explicit classification gap until reconciled, unless personally removed under
the rules below; ambiguity must not silently hide work or grant execution
authority. Classify legacy items from existing run, issue, and request-producer
evidence where possible. Insufficient evidence leaves the ownership unknown;
implementation planning selects the reliable evidence fields.

#### Personal removal from Inbox

Every Inbox item offers **Remove from Inbox**. Removal hides that request for
the acting user only; other users' visibility is unchanged. It does not resolve
the underlying request, change automation authorization, cancel work, or delete
questions and history. Removed requests remain inspectable through a
**Removed** filter and on the related item's history, subject to normal access
controls. The same action is available through the API.

Removal suppresses the current request until one of these events occurs after
removal:

- The project's automation for the request's responsible phase transitions from
  disabled to enabled. Reconcile the request and restore it only if it remains
  actionable. Saving an already-enabled setting is not a transition.
- The related item is manually worked on and that work produces a fresh
  Inbox-worthy condition. For example, a manual enhancement rerun produces a
  clarification request, even if it asks the same questions. Viewing the item,
  routine synchronization, timestamp changes, or rediscovering the unchanged
  condition do not qualify.

Returning an item clears that user's suppression for the new request occurrence;
phase relevance and access rules still apply. Manual work in a disabled phase
can make its resulting request relevant through the manual-action exception.
Automatic retries and follow-ups do not clear personal removal of the same
request. Separate requests remain independently eligible for the Inbox.

Persist removal against a stable request identity and occurrence, with the
user and removal event, so rebuilding the derived queue cannot resurrect it.
Phase enablement and manual-work events must distinguish fresh occurrences
from polling the same state, including when the underlying state value never
changes. A removal made after an occurrence remains effective when delayed
events from that occurrence are processed. Classifying an unknown legacy item
does not itself clear removal; a later qualifying event can restore it once its
responsible phase is known.

Default lists, counts, badges, and availability exclude personally removed
items consistently. Removal affects presentation only: authorized direct-link
inspection and manual work remain available. Platform requests do not gain
execution permission or lose enforcement because a user removes their Inbox
entry; phase-less requests can return on fresh manual-work conditions, while
phase enablement applies only to phase-owned requests.

### 6. Operations boundary

The initial implementation inventories existing operational capabilities and
assigns ownership without adding new autonomous remediation. Each operational
capability must declare its signal source, activation policy, response scope,
limits, escalation behavior, and handoff to other phases before activation.
Detailed operational automation design can follow separately.

## Alternatives Considered

| Alternative | Reason not selected |
| --- | --- |
| Hide all issue requests when auto-pick is off | Auto-pick does not describe preparation, manual work, or existing PR continuation |
| Use phase sections only as visual settings groups | Leaves scheduling, labels, and Inbox behavior inconsistent |
| Make disabled phases prohibit manual runs | Removes operator control and conflicts with existing manual execution |
| Temporarily enable project automation for a manual run | Authorizes unrelated work and creates configuration races |
| Store the exception only on the initial run | Loses authorization across PR creation and follow-up execution |
| Resolve or delete requests when disabling a phase | Destroys unresolved intent and violates discoverable-stop requirements |

## Trade-offs

The model makes project intent and item exceptions explicit, but adds policy
state and requires durable lineage across workflows. Phase ownership must be
maintained when capabilities evolve. Default Inbox volume decreases without
destroying history, at the cost of a secondary view and reconciliation logic.
Permission to request one manual action must remain distinguishable from
permission to delegate an entire delivery chain.

## Rollout Guard

This draft is docs-only and changes no runtime behavior. The foundation issue
must add `automation_phases` to `FeatureFlags::DEFINITIONS`, default off, and
wire decisions through `FeatureFlags.enabled?(:automation_phases, project:)`.
Use the existing authorized project feature-flag management surface for pilot
enablement after its availability is confirmed during LID planning.

While off, existing execution and Inbox policies remain active. Pilot projects
can enable the model only after phase mappings, capability configuration, grant
storage, and Inbox classification are validated together. Do not expose grants
before execution paths enforce them. Block rollback for a project with active
grants until they finish or are explicitly revoked and affected queued work is
reconciled; old policy cannot safely interpret those grants. Remove the rollout
flag after closeout verifies migration and complete execution-path coverage.

## Implementation Plan

The following are proposed issue boundaries, not filed issues:

1. **LID planning and capability inventory.** Reconcile HLD tenets and affected
   LLD/EARS segments. Map every existing action, request producer, and settings
   control to a phase or explicit platform concern. Map release and deployment
   separately within their phase and resolve legacy classification before
   implementation.
2. **Phase policy and authorization foundation.** Add phase identity, durable
   continuation grants, lineage, authorization evaluation, audit data, and the
   rollout guard. Preserve tenant and actor permissions.
3. **Execution enforcement.** Apply the policy to all entry, queue, retry, label,
   follow-up, review, repair, and merge paths, including cancellation races.
4. **Project and manual-trigger UX.** Group phase settings, preserve capability
   values, provide endpoint selection, effective-policy explanations, and grant
   inspection/revocation. Cover every manual-start form, including starts without
   a continuation grant, and submission-time policy changes. Maintain equivalent
   API access.
5. **Inbox ownership and visibility.** Classify producers and legacy requests;
   align queues, counts, badges, chat, details, and the Disabled phases view.
   Add personal removal, the Removed filter, stable request occurrences, and
   event-driven return on phase enablement or fresh manual-work conditions.
6. **Migration and pilot.** Derive phase defaults from current effective
   capabilities without enabling new automatic work. Existing manual runs do
   not acquire continuation grants retroactively. Preview per-project execution
   and Inbox changes before activation, including currently label-enabled work.
7. **Operations contract and final closeout.** Document current operational
   ownership and handoffs, validate acceptance scenarios, and record any gaps
   before removing the rollout guard.

## Validation and Acceptance Scenarios

- A project with issue preparation and auto-pick off, coding continuation on,
  and merge on maintains existing PRs without initiating issue preparation.
  Old preparation requests leave the default Inbox and remain discoverable.
- A manual enhancement run in disabled issue preparation can ask questions;
  those questions remain actionable until the requested action ends.
- A manual coding run authorized through merge continues across implementation,
  PR creation, reviews, CI repair, and merge despite disabled project phases.
  Required checks and approvals still block merging when unsatisfied.
- A through-coding grant ends at readiness. With project merge off, no merge
  runs; with project merge on, every applicable manual-start form explains before
  submission that merge automation can continue and identifies why. The notice
  updates with form selections and is also available through the API and work
  details. An unchecked continuation option does not suppress the notice when
  project policy permits follow-ups. Newly permitted continuation at submission
  returns an updated notice for review. No per-item stopping override is added.
- Phase disablement, grant revocation, queued execution, retries, and a new
  review comment race without starting unauthorized subsequent actions.
- Trusted activation labels cannot enable disabled phases. A grant does not
  authorize another issue, dependency, unrelated PR, or operational response.
  Creating linked child issues does not authorize their execution or grant
  inheritance; their execution requires independent authorization.
- Inbox lists, counts, badges, chat, and direct links agree about phase relevance
  while preserving account isolation and existing authorization checks.
- Legacy items with ambiguous ownership remain visible for reconciliation
  unless personally removed; hidden items retain their questions and history.
- Removing a request hides it only for that user, including default counts and
  badges. It remains accessible through Removed and related-item history.
  Polling, unchanged saves, automated retries, and classification alone do not
  restore it. Re-enabling its phase restores only still-actionable requests.
- Manual work that produces a fresh Inbox-worthy occurrence restores eligibility
  even when its questions or state value match the removed occurrence. Mere
  viewing does not. Delayed events do not undo a newer removal, and tenant and
  user isolation apply to suppression as well as visibility.
- An operations incident can hand off an issue without granting coding access;
  Paid platform health remains visible regardless of project phase switches.
- A through-merge grant does not authorize release or deployment. Independently
  enabled project release/deployment automation can continue afterward, with
  that possibility explained before a manual start. Release and deployment
  controls do not implicitly enable each other.

Tests are written against reconciled EARS claims before runtime implementation.
Run structural coherence checks and a final RDR closeout audit against the
complete implementation chain.

## Remaining Planning Work

No open architectural questions remain in this draft. LID planning must map
individual capabilities and request producers to the agreed phases, select
reliable legacy-classification evidence, and specify persistence and event
handling for continuation grants and personal removal. These implementation
details follow the phase, authorization, and Inbox rules established above.
