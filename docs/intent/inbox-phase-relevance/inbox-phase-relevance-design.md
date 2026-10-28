---
parent: PAID
prefix: INBOX-PHASE-RELEVANCE
---

# Low-Level Design: Inbox Phase Ownership and Relevance

Implements the Inbox half of
[RDR-077](../../rdrs/RDR-077-automation-phases-and-work-item-authorization.md).

## Phase ownership

Ownership is assigned when the request is produced and persisted in
`inbox_request_ownerships`, keyed by the stable request key
`"<kind>:<record_id>"`. Producers that own issue state call
`Inbox::PhaseOwnership.record!` as they write the request (for example the
enhancement stop paths that write `needs_input` / `manual_review`).

`Inbox::PhaseOwnership.classify(entry)` covers legacy and derived requests from
existing evidence — record kind, `manual_review_reason`, the latest run goal,
`pr_review_phase`, and notification metadata:

| Kind | Phase |
| --- | --- |
| `clarifying_questions`, `plan_review` | issue preparation |
| `merge_approval` | merge |
| `escalated_pr`, `manual_review` (CI/conflict/dependency reasons), `retry_limited`, `intent_conformance`, `change_intent_draft`, `partial_closeout`, `test_review_pending`, `traceability_gap` | coding |
| `manual_review` (enhancement rounds) | issue preparation |
| `action_required` | operations |
| `feature_decision`, `project_setup_pending` | discovery |
| `traceability_gap` (unverifiable coverage) | platform (no phase) — an access problem a disabled coding phase must not hide |

A request whose evidence does not resolve to a phase is recorded with
`responsible_phase = NULL` and `classification_state = "unknown"`. Unknown
ownership stays visible in the default Inbox with an explicit classification
gap: ambiguity must never silently hide work or imply execution authority.
Project-independent platform, credential, and safety requests are recorded as
platform requests (no phase) and follow the same visibility rule.

## Request identity and occurrences

`Inbox::RequestIdentity` derives:

- `request_key` — `"<kind>:<record_id>"`, stable across rebuilds.
- `occurrence` — the producer-owned timestamp the request has been waiting
  since (`needs_input_since`, `manual_review_started_at`, `blocked_since`,
  `waiting_since`, `created_at`, …), or a deterministic producer-state token
  for derived requests such as project setup. Polling, re-reading, routine
  readiness evaluation, and unchanged saves never change it; a fresh manual
  occurrence or materially changed producer state does.

## Relevance

`Inbox::PhaseRelevance` returns, per entry, one of:

- `:actionable` — phase enabled, or an active grant covers the phase and work,
  or the request completes an outstanding explicitly started manual action
  (`Automation::ContinuationGrantLookup` also answers "is this work under an
  outstanding manual action"), or the request is platform/unknown.
- `:disabled_phase` — phase-owned and none of the above; hidden from the
  default list, visible in the **Disabled phases** view with its stop reason and
  recovery action.

Hiding never resolves, clears, comments, or changes readiness.

`Inbox::Queue` accepts `scope:` (`actionable` default, `disabled_phases`,
`removed`), and `Inbox::Count` / `Inbox::Availability` derive from the same
call so lists, counts, badges, and indicators cannot disagree.

## Personal removal

`inbox_removals` stores `(user, request_key, occurrence, phase, entry_kind,
project_id, removed_at, cleared_at)`. A request is suppressed for that user
while a removal row exists whose occurrence is not older than the request's
current occurrence. Removal is presentation-only: the underlying work,
questions, comments, and authorization are untouched, other users are
unaffected, and the item stays inspectable via the **Removed** filter, direct
link, and related-item history.

Return events:

- **Phase enablement** — `Automation::PhaseSettings::Update` returns the phases
  that transitioned disabled → enabled. Saving an already-enabled phase is not
  a transition. `Inbox::Removals::RestoreOnPhaseEnablement` clears suppressions
  for phase-owned requests in those phases that are still actionable.
- **Fresh manual work** — a new occurrence makes the stored removal older than
  the request, so eligibility returns automatically, including when the
  questions are unchanged. Delayed events carrying an older occurrence cannot
  resurrect an item removed after it.

Classifying a legacy request never clears a removal.

## Rollout

Phase relevance is behind `FeatureFlags.enabled?(:automation_phases, project:)`;
while the flag is off, phase-owned requests remain in the default list.
Personal removal is an independent per-user presentation control and applies
to the default and Removed views regardless of that rollout flag.

## Bounded badge counting

The nav badge retains its indexed candidate counts while phase rollout is off.
When a user has active personal removals, it validates only each removed
stable request identity through the queue's `removed` scope and subtracts the
ones still suppressed. It MUST NOT construct the unfiltered queue merely
because a removal exists. This preserves occurrence-aware suppression while
bounding materialization to the removal set. Ordered issue lanes keep project
joins for predicates and ordering, but preload projects in a separate query so
large project audit histories are not repeated in each issue result row.
