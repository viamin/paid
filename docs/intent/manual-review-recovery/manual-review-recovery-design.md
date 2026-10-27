```yaml
parent: operator-inbox
prefix: MANUAL-REVIEW-RECOVERY
```

# LLD: Manual-Review Recovery by Cause

## Problem

`manual_review` is a single `paid_state` with several unrelated causes. Paid
parks an issue there when enhancement stops for a human answer, when a reopened
issue needs its prior closure revalidated, when a merged remediation is
re-scanned and the finding is still open, when a completed issue is still
blocked on an unresolved dependency, and when a completion assessment finds
the merged implementation incomplete.

The operator Inbox treated all of them as one: the pane said "Starting a new
enhancement run is the only way to resume work" and its only action queued an
`enhance_issue` run (#4640). That is wrong for every cause except the
enhancement one:

- A reopened issue needs an intent-validation verdict recorded against the
  revision of the intent that was reviewed — an enhancement retry records no
  such verdict, so the reopen-review gate (`ISSUE-REOPEN-REVIEW-001`) stays
  unresolved and the required live-validation artifacts are never collected.
- An issue blocked on an unresolved dependency must wait for that dependency.
  Offering enhancement asks for work the issue cannot do, and an
  acknowledgment that clears the hold would waive a real dependency.
- A scanner-confirmed recurrence needs a new remediation to be authorized
  explicitly; an enhancement run does not produce one.
- A completion assessment that found the work incomplete needs the existing
  partial-closeout continuation, not a fresh enhancement.

## Cause classification

`Issues::ManualReviewCause` classifies a parked issue from explicit
provenance only:

| Cause | Provenance |
| --- | --- |
| `reopen_review` | the dedicated reopen-review reason (`Issue::REOPEN_REVIEW_REQUIRED_REASON`) |
| `enhancement` | the enhancement stop paths (`IssueEnhancements::StopForManualReview`, the round-limit and parse-failure stops) and preserved clarifying questions |
| `dependency_wait` | unresolved dependency edges (local, deployment, external) |
| `scanner_recurrence` | scanner remediation evidence (`CodeScanningRemediationAttempt`) |
| `partial_closeout` | the recorded partial-completion assessment |
| `unknown` | none of the above |

The producers of a park record the cause on `issues.manual_review_cause`, so a
newly parked issue is classified exactly. Rows parked before that column
existed carry no cause; the classifier derives it from the provenance listed
above and, when it cannot establish one, keeps the issue `unknown`. An unknown
cause stays visible in the lane with the recorded reason — the lane never
infers a cause from the prose of a free-text reason, and never hides a parked
issue it cannot explain.

Every applicable cause is returned, not only the first one, so simultaneous
holds (a reopened issue that is also blocked on a dependency) stay visible
instead of one hold concealing the other.

## Recovery routing

`Issues::ManualReviewRecovery` is the single authorized entry point for
recovering a parked issue. The Inbox pane, the chat tools, and the API all
call it, so cause routing, authorization, duplicate suppression, and the
inspection of already-queued work behave identically wherever the operator
acts.

| Cause | Action | Effect |
| --- | --- | --- |
| `reopen_review` | `record_intent_validation` | records a decision |
| `enhancement` (questions preserved) | answer form + `retry_enhancement` | records a decision / retries analysis |
| `enhancement` (no questions) | `retry_enhancement` | retries analysis |
| `dependency_wait` | `reevaluate_dependency` | retries analysis |
| `scanner_recurrence` | `authorize_scanner_remediation` | resumes implementation |
| `partial_closeout` | `request_continuation` | resumes implementation |
| `unknown` | `retry_enhancement` | retries analysis |

An action that does not match the issue's cause is refused with the cause that
does apply, so a dependency wait cannot be answered with an enhancement retry
and a reopen review cannot be cleared without a recorded verdict.

### Reopen review

The pane shows the original closure (when the issue closed, the merged pull
requests or the no-code-required outcome that closed it) and the remaining
scope (the current title and body, any preserved questions, the last
analyzer verdict). The operator records an intent-validation decision with a
reason. The decision is bound to a revision digest of the issue's intent
(title, body, and GitHub revision timestamp): if the intent changes after the
verdict, the recorded verdict no longer describes the current intent and the
lane asks for a fresh one.

The verdict is idempotent per revision. A repeated submit returns the recorded
verdict instead of writing a second one.

### Dependency wait

A dependency wait names its blockers, the repository that owns each one, and
the action that resolves it. The offered action re-evaluates the dependency;
it never waives it. While the dependency is unresolved the action reports the
blocker and leaves the hold in place — an acknowledgment is not a resolution.
Once the dependency resolves, the re-evaluation returns the issue to the queue.

### Scanner recurrence

The scanner cause reuses the scanner evidence the closeout diagnostics
already surface (alert number, attempt status, blocked reason, merge
evidence). The supported recovery is an explicit authorization of new
remediation, recorded as a decision and executed as one implementation run.

### Partial closeout

The partial-closeout cause reuses `Issues::RequestContinuation` — the same
authorization, budget check, blocker explanation, and single-run guarantee the
`partial_closeout` lane uses.

## Existing work

Every action that resumes work inspects the issue's queued and running runs
first:

- A queued or running run with the same goal is reused: no second run is
  created and the operator is told which run already covers the work.
- A queued or running run with a different goal is incompatible. The action
  refuses and names the run; it does not clear the hold, so an automatic run
  that was queued before the park cannot proceed behind the operator's back.

Recording a decision inspects the same runs before it clears the hold. The
verdict is recorded either way, but the hold stays until the queued run is
reconciled, and a later submit clears it once the queue is clear.

## Decisions

| Decision | Rationale | Alternatives considered |
| --- | --- | --- |
| Classify from explicit provenance, keep `unknown` visible | A parked issue the lane cannot explain is still a parked issue; hiding it or guessing a cause both lose information. | Keyword-matching the free-text reason: rejected, the reason is prose that changes with the producer's wording. |
| Record the cause at the producers | The producer knows the cause exactly; deriving it later from a shared state column loses that. | Deriving every cause from existing signals only: rejected, a dependency-blocked issue also receives a partial-completion assessment, so the two causes are indistinguishable after the fact. |
| One authorized service behind every surface | Cause routing and duplicate suppression must not depend on which surface the operator used. | Per-surface routing: rejected, it is what produced the generic enhancement-only recovery. |
| Reuse an active run instead of queueing a second one | A second run duplicates work, spends budget, and can conflict with the first. | Cancel and replace the active run: rejected, cancelling in-flight work is a separate, explicit operator action. |
| A dependency wait cannot be waived by an acknowledgment | The dependency is real work owned elsewhere; an acknowledgment does not resolve it. | Letting an acknowledgment clear the hold: rejected, it would silently waive a dependency. |

## Related intent

- [`issue-reopen-review`](../issue-reopen-review/issue-reopen-review-design.md)
  owns the reopen gate this cause validates against.
- [`issue-enhancement`](../issue-enhancement/issue-enhancement-design.md) owns
  the enhancement stop paths and the answer form this cause preserves.
- [`partial-closeout-recovery`](../partial-closeout-recovery/partial-closeout-recovery-design.md)
  owns the continuation this cause reuses.
- [`operator-inbox`](../operator-inbox/operator-inbox-design.md) owns the lane
  and the pane this recovery is offered from.
