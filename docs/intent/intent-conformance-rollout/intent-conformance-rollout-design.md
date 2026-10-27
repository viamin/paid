---
parent: PAID
prefix: INTENT-CONFORMANCE-ROLLOUT
---

# Low-Level Design: Intent-Conformance Measured Rollout

> Implements RDR-067 issue #3870. This is the evaluation boundary for the
> approval-gated operating mode; it does not alter the reviewer’s semantic
> decision or authorize a merge.

**Current state (2026-10-23):** The 30-case corpus is frozen, but it has not
been independently adjudicated by two humans with auditable, distinct
provenance. The prior label-only record does not establish independence.
Issue #4205 is closed without qualifying adjudications; the audit trail and
the follow-up it requires live in the RDR-067 audit reports. #4594 adds the
explicitly selected solo-maintainer policy below so a one-maintainer project
can still produce qualifying reference labels; the corpus alone does not
authorize promotion.

## Purpose

The independent reviewer can be structurally correct yet operationally harmful
if it frequently stops conforming work or misses material changes. Before a
project enables either merge guard, Paid runs the reviewer in a separate,
read-only shadow mode and compares verdicts with blinded human adjudication.

## Rollout boundary

`intent_conformance_shadow_review` is the only flag enabled during shadow
evaluation. It schedules and runs the reviewer, persisting its normal,
head-and-revision-bound verdicts. It does **not** enable
`intent_conformance_enforcement`, `approved_intent_amendments`, the scanner
blocker, the Inbox lane, the amendment flow, or `VerifyAtMerge`. Therefore a
shadow verdict cannot affect merge eligibility.

No feature implementation issue may be released into the approval-gated mode
until both the scanner enforcement and final merge guard are active. The
enforcement transition is atomic at the operator level: disable the shadow
flag, enable `intent_conformance_enforcement` and
`approved_intent_amendments` for the same named project, then confirm a new
PR receives both a schedule and a merge-time check.

## Representative corpus and adjudication

The frozen corpus contains at least ten cases in each stratum, pinned to a
repository, base SHA, head SHA, approved design revision, and model/prompt
version:

| Stratum | Expected adjudication | Required shape |
|---|---|---|
| Accepted | `within_scope` | Implements an approved acceptance criterion while varying non-binding internals. |
| Intentionally drifted | `material_drift` | Changes an approved behavior, constraint, scope boundary, or acceptance criterion. |
| Uncertain | `uncertain` | Has incomplete, contradictory, or insufficient design/diff evidence; it must not be counted as accepted. |

Two project operators adjudicate each case independently while blind to the
reviewer output. They record the expected outcome, cited design claim, and
reason. A disagreement is resolved by a third operator and retained with the
case. The corpus manifest contains references and hashes only; repository
patches and prompt bodies remain in the repository/provider and are never
copied into telemetry.

## Solo-maintainer evaluation policy (#4594)

The two-operator team policy above is the default and remains unchanged. A
project with exactly one maintainer cannot satisfy it; fabricating a second
identity would be worse than an explicit weaker policy. An evaluation may
therefore declare the **solo-maintainer policy**, which must be:

- **Explicitly selected.** The declaration is recorded once, before any
  label, as an `evaluation_policy` ledger event naming the policy (`solo`)
  and the single authenticated maintainer who will label. A ledger with no
  declaration keeps the team policy; historical bot-authored records are
  never silently reinterpreted as solo human evidence.
- **Identity-bound.** Only the declared maintainer may record reference
  labels, revisions, or the freeze action, under the project's existing
  tenant/project authorization. No additional operator identities are
  created, and an agent may assist navigation/recording only through the
  authenticated maintainer's session — it cannot impersonate the decision.
- **Blinded before freeze.** While the evaluation is in the labeling state,
  the labeling surface provides navigation to the case's pinned diff and its
  declared approved-design artifacts at their recorded revisions, but never
  the reviewer outputs, the preassigned stratum, expected label, selection
  rationale, or free-text notes/context that could reveal an outcome. Evidence
  navigation validates repository access, every requested SHA, and each
  declared artifact before redirecting to a revision-bound GitHub URL.
  Navigation is refused outright when the manifest no longer matches the
  digest recorded at evaluation creation, so replacement evidence under an
  edited corpus cannot be inspected through an existing evaluation. It
  never falls back to a branch or moving default revision; missing, forbidden,
  malformed, or undeclared evidence is explicitly unavailable. Reviewer
  execution is refused until the reference set is frozen.

### Assurance limits (stated, not hidden)

A solo reference set has no independence: one human's mistake or bias is the
reference for every case, and no tie-break exists for internal doubt. It is
weaker evidence than the team policy and is acceptable only because the
alternative is no qualifying evaluation at all. The report must state the
policy and the declared maintainer next to every measure. A team that later
has two operators SHOULD re-run under the team policy before any promotion
decision relies on independence-sensitive measures.

### Labeling lifecycle

The maintainer works one case at a time on a minimal labeling screen reusing
Paid's project authorization and presentation patterns:

1. **Start / resume.** Starting from the originating partial-closeout Inbox
   item opens (or resumes) the evaluation for the current evidence
   generation — the tuple of project, evaluation purpose, and frozen corpus
   manifest digest. Repeated clicks resume the same evaluation; they never
   create duplicates, and a changed corpus or evidence revision visibly
   supersedes prior completion rather than mutating it. Before creation, the
   manifest's repository-relative path and local bytes are verified against
   its resolved Git commit; the recorded provenance therefore identifies an
   exact recoverable corpus.
2. **Label.** Each case presents a one-case-at-a-time evidence surface. The
   diff and approved-design links are resolved only from repository and
   revision identities stored in the frozen corpus; a case without declared
   approved-design paths remains unavailable for design evidence and cannot
   be represented as independently assessed acceptance. Each label records
   `within_scope`, `material_drift`, or `uncertain`, with a cited approved
   claim and a reason. Saves are durable and resumable; any case may be
   skipped, and a skipped case is never counted as completed.
3. **Freeze.** The explicit finish action refuses to freeze while any case
   is unlabeled or skipped, then stamps the reference set frozen. Answers
   (strata and reviewer outputs) become visible only from freeze onward.
4. **Execute.** After freeze, an authorized operator queues the real conformance reviewer through the supported background-job lifecycle. The request returns promptly; the durable evaluation records `queued`, `running`, `partial`, `failed`, `cancelled`, or `completed`, per-case progress and accumulated cost. The reviewer queue is a platform-required worker queue: a stored per-tenant queue allocation is re-normalized so the queue stays served and its per-queue threads stay inside the worker thread budget, so a stored allocation that predates the reviewer queue cannot strand a queued evaluation. Cancellation is authorized and cooperative between cases: it preserves collected evidence and never creates invented unevaluated outcomes. A retry/resume reuses the same frozen identity and only spends on cases without an evaluated verdict. Bounded job retry/recovery converges an interrupted worker to `partial` or `failed`, so a lost worker or advisory lock cannot strand execution as running. The real conformance reviewer runs for every
   case through `agent_harness` (the documented operator command or the
   equivalent UI action), recording actual verdicts, reviewer model, prompt
   digest, cost, and failures. Missing or failed reviewer output is recorded
   as not evaluated; prerequisite validation alone is never presented as
   execution.
5. **Review and revise.** Disagreements surface for maintainer review after
   the run. A post-result revision is appended with its own reason and
   timestamp; it never overwrites the original blinded label, and blinded
   scoring always uses the original reference labels.
6. **Report.** Compilation produces a reproducible report with exact
   corpus/rubric/model/prompt/design identities, original reference labels,
   appended revisions, reviewer verdicts, confusion counts, false alarms,
   missed drift, uncertainty handling, cost, and provenance.

Missing production measures (escaped changes, delivery baseline, rework,
human time) stay `not established` with an explicit rollout follow-up;
fixture accuracy cannot fabricate production effectiveness. Completing
labels, or even a passing evaluation, implements acceptance only — it never
automatically attests issue completion, closes GitHub work, or enables
enforcement. Enforcement promotion remains the explicit human decision the
RDR-067 rollout guard already requires.

## Telemetry and promotion criteria

For every shadow review retain the existing verdict identity/evidence,
review-schedule timestamps, reviewer model, and reviewer `AgentRun` cost when
available. For every human resolution retain its timestamp and action. The
rollout worksheet reports:

| Measure | Calculation |
|---|---|
| False alarms | Adjudicated `within_scope` cases returned as `material_drift` or `uncertain` ÷ adjudicated accepted cases. |
| Missed material drift | Adjudicated `material_drift` cases returned as `within_scope` ÷ adjudicated drift cases. |
| Escaped changes | Post-merge material drift found by a follow-up issue or amendment after a `within_scope` verdict, ÷ merged `within_scope` PRs. |
| Review cost | Reviewer token/API plus linked reviewer-run infrastructure cost per verdict. |
| Human time | Verdict evaluation to human resolution, reported separately from active adjudication time. |
| Rework | PRs with a `fix_pr` decision or a second reviewed head ÷ reviewed PRs. |
| Delivery time | PR creation to merged/closed timestamp, compared with a same-project pre-shadow baseline. |

Baseline is the prior 30 comparable feature PRs for the named project,
stratified by changed-file band. Promotion requires at least 30 adjudicated
cases (including ten in every stratum), zero missed intentionally drifted
cases, false-alarm rate at or below 10%, no increase in escaped-change rate,
and median delivery time no worse than 20% above baseline. Review cost and
human time have no hidden pass condition: their observed medians, ranges, and
budget exceptions must be explicitly accepted by the project operator.

## Operator rollout and rollback

The project operator publishes the corpus manifest, aggregate worksheet, and
flag snapshot in the project’s rollout record. If any promotion criterion is
missed, the project remains shadow-only and documents the corrective action.
After enforcement, operators review the same aggregate weekly for the first
30 production PRs.

To roll back, disable `intent_conformance_enforcement` and
`approved_intent_amendments`, stop releasing new feature work into the mode,
and hold outstanding candidates until the guard is restored or a human moves
them to another policy. Disabling the reviewer is never treated as a passing
verdict. `intent_conformance_shadow_review` may remain enabled for diagnosis.
