---
parent: PAID
prefix: MANUAL-REVIEW-RECOVERY
---

# Low-Level Design: Manual Review Recovery

## Purpose

`paid_state: manual_review` is a single parking state with several causes.
The reopen-review gate (`ISSUE-REOPEN-REVIEW-001`), the enhancement stop
(`ISSUE-ENHANCEMENT-011`), the dependency-blocked parking
(`GITHUB-SYNC-016`) and the scanner-confirmed recurrence (`EAGER-QUEUE-014`)
all park an issue there, but each one is released by a different action.

The Inbox lane used to treat every parked issue as an enhancement stop and
offered exactly one recovery: start a new enhancement run. That recovery is
wrong for the other causes. It does not record the intent validation a
reopened issue needs, it does not resume the technical work a reopened issue
is waiting for, and it competes with a run that is already queued for the
issue.

This segment owns the classification of a parked issue and the routing of its
recovery. It reuses the existing intents rather than adding a workflow: the
reopen-review gate stays where it is, the enhancement answer form and the
enhancement retry stay as they are, the scanner evidence stays as it is, and
the closeout dependency diagnostics stay the source of the dependency
explanation.

## Cause classification

`Inbox::ManualReviewCause` reads explicit provenance only:

| Cause | Provenance |
| --- | --- |
| `reopen_review` | the issue is parked with `Issue::REOPEN_REVIEW_REQUIRED_REASON` |
| `scanner_recurrence` | a recorded scanner verification attempt is awaiting, blocked or failed |
| `dependency_wait` | the issue is parked with the dependency-blocked reason, or it still has unresolved dependency edges and no enhancement evidence |
| `enhancement` | the enhancement stop reason, the preserved clarifying questions, or an `enhance_issue` run produced the stop |
| `unknown` | none of the above |

An unclassified cause stays visible as `unknown`. It is never folded into the
enhancement lane, because the enhancement retry is a claim about the cause.

Every recorded hold is reported, not only the primary cause. A reopen
validation recorded while a dependency is still unresolved keeps the issue
parked on the dependency: an acknowledgment never waives a dependency.

## Recovery by cause

| Cause | Supported recovery | Effect |
| --- | --- | --- |
| `reopen_review` (decision pending) | record the intent-validation decision | records a decision |
| `reopen_review` (validated) | enhancement retry or implementation run | retries analysis or resumes implementation |
| `dependency_wait` | open the blocking work | collects evidence in the blocking issue |
| `scanner_recurrence` | authorize a new remediation run | resumes implementation |
| `enhancement` | answer the preserved questions, or retry the enhancement | retries analysis |
| `unknown` | retry the enhancement | retries analysis |

`Issues::ResolveReopenReview` records the reopen-review decision. The
decision names the operator's own reason and is bound to the revision of the
issue scope the operator reviewed (a digest of the title and body), so a
decision made against a different scope is refused and an edited scope asks
for a fresh validation. The decision releases the reopen gate and nothing
else: an unresolved dependency keeps the issue parked.

`Issues::ResumeManualReview` performs the resume. It authorizes the actor
against the issue's account, routes by cause, and inspects the work that is
already queued or running before it creates anything:

* a queued run with the same goal is reused, and the hold is lifted with the
  run named in the message;
* a queued run with a different goal is reported with its identity and
  status, and the hold stays;
* a second run is never created for the same issue and goal.

## Dependency re-evaluation

The dependency-blocked parking state is a hold, not a verdict. When the
blocking issue closes, `Issues::ReleaseDependencyBlockedDependents`
re-evaluates the issues that were parked on it and returns them to the
pipeline once no unresolved dependency is left.

## Surfaces

The Inbox pane renders the classification, the holds and the supported
action for the cause, and states what the action does (records a decision,
retries analysis, resumes implementation, collects evidence). The API
payload and the inbox chat context expose the same classification and the
same actions, and the resume and decision paths are the same authorized
services the Inbox uses, so every surface refreshes the same state.
