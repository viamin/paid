---
parent: PAID
prefix: MANUAL-REVIEW-RECOVERY
---

# Low-Level Design: Manual Review Recovery By Cause

## Purpose

`paid_state: "manual_review"` is a hold, not a cause. Several unrelated
producers park an issue there: a reopened issue awaiting intent validation
(`ISSUE-REOPEN-REVIEW-001`), an issue blocked on an unresolved dependency
(`GITHUB-SYNC-016`), an enhancement round that stopped with questions or at
its round limit (`ISSUE-ENHANCEMENT-011`), an enhancement agent that produced
unusable structured output, a scanner-confirmed code-scanning recurrence
(`EAGER-QUEUE-014`), and a transport/evidence failure while refreshing
code-scanning context (`GITHUB-SYNC-019`).

The Inbox `manual_review` pane used to answer every one of those with the same
control — "Start enhancement run" — and the copy claimed that starting an
enhancement run was the only way to resume work. That is wrong for every
cause except one:

- a reopened issue needs its prior intent validated and a decision recorded
  before any new work is admitted;
- a dependency-blocked issue needs the dependency resolved, and an
  acknowledgment must never waive it;
- an enhancement round needs either its preserved questions answered or an
  explicit enhancement retry;
- a malformed-output or transport failure must not be answered with another
  enhancement attempt, because that reproduces the same failure;
- a scanner-confirmed recurrence needs the scanner's own recovery, not a
  generic retry.

This design routes recovery by cause. It adds no workflow, approval, or
evidence framework: it reuses the existing reopen-review gate, the existing
enhancement and clarifying-question surfaces, the existing scanner
verification path, and the existing run-queueing path.

## Cause classification

`ManualReviewRecovery::Cause` classifies a parked issue from the provenance
the parking producer already recorded — never from a guess about intent, and
never from an LLM. The recorded `manual_review_reason` is written by the
producer itself, so the classifier matches the producer's own fixed wording
(`ManualReviewRecovery::ReasonSignatures`) rather than free text. Structural
provenance wins over wording where both exist:

| Cause | Provenance |
| --- | --- |
| `reopen_review` | `Issue#reopen_review_pending?` — the dedicated reopen-review reason |
| `dependency_wait` | The producer's dependency-wait reason wording |
| `enhancement` | The enhancement round-limit reason, or a reason naming enhancement/clarifying questions |
| `scanner_recurrence` | A code-scanning synthetic issue whose reason is not a technical failure |
| `technical_failure` | The malformed-structured-output reason, or a code-scanning evidence/transport failure |
| `unknown` | No recorded provenance resolves a cause |

`unknown` stays visible with its recorded reason. It is never coerced into
another cause, because an unclassified hold that silently becomes "start
another enhancement run" is the failure mode this design removes.

## The plan

`ManualReviewRecovery::Plan` is the single read model for the lane. It
answers three questions for one parked issue:

1. **Why is it parked?** The classified cause, its label, and the recorded
   reason.
2. **What can the operator do?** A list of actions, each labelled with what
   it does — `records_decision`, `retries_analysis`, `resumes_implementation`,
   or `collects_evidence` — so the operator never has to guess whether a
   control writes a decision, retries analysis, resumes implementation, or
   collects evidence.
3. **Is anything already running?** The issue's queued and running runs,
   with the compatibility verdict for each.

### Actions per cause

| Action | Kind | Causes |
| --- | --- | --- |
| `answer_clarifying_questions` | `records_decision` | any cause whose parked round preserved questions |
| `record_reopen_intent` | `records_decision` | `reopen_review` |
| `resume_implementation` | `resumes_implementation` | `reopen_review` (after a decision), `scanner_recurrence` |
| `retry_analysis` | `retries_analysis` | `technical_failure` |
| `retry_enhancement` | `retries_analysis` | `enhancement` |
| `recheck_dependency` | `records_decision` | `dependency_wait` |

A cause never offers an action that cannot help it. A dependency-blocked
issue is never offered an enhancement retry, a reopened issue is never offered
an enhancement retry, and a malformed-output failure is never offered an
enhancement retry that would reproduce the same failure.

## Reopen review recovery

A reopened issue keeps the original closure and the remaining scope visible,
and the operator records a revision-bound intent-validation decision:

- the decision names whether the original intent still holds
  (`intent_valid`) or was superseded (`intent_superseded`);
- it carries the operator's reason and the remaining scope the operator
  still expects;
- it is bound to the issue's current **evidence revision** — a digest of the
  issue's title, body, and GitHub update timestamp — so any later content
  change invalidates it and the operator must validate again.

The decision alone does not release the hold. It authorizes the supported work
continuation: with a current `intent_valid` decision the lane offers
`resume_implementation`, which queues a `create_pr` run. With an
`intent_superseded` decision the lane says the issue no longer needs new
implementation work and leaves the release to the operator's own close.

The decision is recorded in `IssueReopenReviewDecision`, which stores the
issue, the project, the deciding user, the decision, the reason, the
remaining scope, and the evidence revision it was bound to.

## Dependency wait recovery

A dependency-blocked issue names the blocking dependency and its owner
(local `#123`, or `owner/repo#123` for an external dependency) and the action
that resolves it. It never asks for an enhancement, and acknowledging the
wait never waives the dependency: the acknowledgment records that a human is
watching the dependency, and the issue stays in `manual_review`.

`recheck_dependency` re-evaluates the dependency. While the dependency is
still unresolved, the issue stays parked. Once it resolves, the lane offers
`resume_implementation` — the supported work continuation for work that was
deferred behind the dependency.

## Technical failure recovery

A malformed enhancement payload and a code-scanning evidence/transport failure
are technical failures, not enhancement outcomes. Their supported recovery is
`retry_analysis`: a fresh `analyze_issue` run that re-derives the issue's
intent from the current evidence, instead of another enhancement round that
would reproduce the same failure. If the parked round preserved clarifying
questions, the answer form stays available alongside it — the questions are
still the answerable surface.

## Scanner recurrence recovery

A scanner-confirmed recurrence keeps the scanner's own evidence visible (the
existing `Issues::CloseoutStatus.scanner_verification_blockers` surface) and
offers the supported recovery: explicitly authorize new remediation, which
queues a `create_pr` run and re-enters the scanner verification path that
collects the evidence.

## In-flight work

Before any action queues work, the plan inspects the issue's queued and
running runs:

- a queued run with the same goal is **reused** — no second run is created;
- a queued or running run with an incompatible goal is **explicitly
  reconciled**, never silently ignored: the action reports the conflicting
  run and asks the operator to reconcile it;
- the manual-review hold is never silently cleared while an incompatible
  automatic run remains queued.

The hold is only released at queue time, in the same transaction that creates
the run, exactly as `ISSUE-ENHANCEMENT-011` requires.

## One authorized service

`ManualReviewRecovery::Recover` is the only entry point that changes state.
The Inbox UI, the API, the chat, and the MCP tool all call it with the same
arguments and the same authorization:

- the actor must be authorized for the issue's project (`run_agent?`), and
  the issue must belong to that project and to the actor's account — a
  cross-tenant issue is refused, never partially applied;
- a repeated submit is idempotent: it reuses the already-recorded decision or
  the already-queued run instead of recording a second one.

Every surface refreshes the Inbox from the same persisted state, so the lane
and the badge agree after the action.

## Decisions

| Decision | Rationale | Alternatives considered |
| --- | --- | --- |
| Classify from recorded producer wording and structural provenance | The hold's cause is already recorded; matching the producer's own fixed wording cannot drift into a semantic guess | An LLM classification adds cost and can mislabel a hold; a new `manual_review_cause` column adds a second source of truth to keep in sync |
| Keep `unknown` as a first-class, visible cause | An unclassified hold must stay visible; silently coercing it into an enhancement retry is the bug this design removes | Hiding unknown holds loses work; guessing a cause repeats the original defect |
| Bind the reopen-review decision to an evidence revision | A decision about the issue's intent must not silently cover a later edit of that issue | Binding only to the issue id lets an edit slip past an already-recorded validation |
| Route malformed output to a fresh analysis rather than another enhancement | The same malformed payload would fail again; the loop is the defect | Another enhancement attempt reproduces the failure |
| Record a dependency acknowledgment without releasing the hold | An acknowledgment is not a resolution; releasing on it would waive the dependency | Releasing on acknowledgment silently drops a real blocker |
| One authorized service behind every surface | UI, chat, API, and tools must not drift into different recovery policies | Per-surface handlers duplicate authorization and drift |
