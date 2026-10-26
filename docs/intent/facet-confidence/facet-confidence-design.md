---
parent: PAID
prefix: FACET-CONFIDENCE
---

# Facet Confidence

## Context

[RDR-070](../../rdrs/RDR-070-facet-confidence-and-clarification.md) defines
numerical judgments of evolving intent and feasibility. New claims are planned,
not implemented. Extend feature/question records; do not replace the canonical
repository design with a score database.

## Domain model

The implementation needs these responsibilities, not necessarily one table per
row:

| Concept | Required information |
|---|---|
| Facet | Subject feature/issue, design claim, question links, candidate directions |
| Evidence | Attributable statement/result, source, actor, time, supersession and textual context |
| Assessment | Separate intent/technical scores or unknown, explanation, evidence revision, rubric/model version |
| Issue prerequisites | Material facets/directions and relevant design artifacts with mapping rationale |
| Explicit preference | User's statement, user/project/feature scope as explicitly expressed, owner and source |

Use tenant isolation, foreign keys, indexed links and audit history for records
whose changes affect readiness. Extend existing decision links rather than
creating a disconnected question system. No new migration is included in this
design PR; implementation must use Rails generators.

## Assessment pipeline

Persist a human answer or investigation result, advance the evidence revision,
and enqueue assessment through `agent_harness`. Supply relevant prior intent,
candidate directions, explicit preferences and repository evidence. The result
contains bounded numeric scores, explanation, and source references. Validate
the response structurally and apply it only if its evidence revision is still
current. Duplicate evidence is idempotent. Failed or stale output does not
produce a passing assessment.

Unknown is distinct from zero and from 100. The rubric describes evidence
strength, not formulaic increments per answer. Human corrections replace
superseded statements; collaborator disagreement produces a targeted question.
Preserve old assessments for explanation, but readiness uses the applicable
current one. Assessors cannot mutate project thresholds to make their own
assessments pass.

## Clarification and preferences

Show a compact list of relevant facets, both scores and explanations in the
conversation. Ask discriminating questions about uncertainty; support A/B,
both/neither, conditions and free text. Selecting a response is evidence only
when it expresses an answer, not when merely previewing an alternative.

Feature-decision Inbox entries use the existing durable decision and
reassessment path. They render a single choice, multiple choice, or free text
only when the decision producer supplies that structured input contract; the
Inbox never derives choices from natural-language prose. Saving one statement
resolves only that decision with its human attribution and cannot approve a
feature or authorize execution. A stale response is rejected rather than
attached to a replacement decision.
Validation failures preserve the submitted draft for that same decision; a
successful response leaves unrelated open decisions and their drafts intact.
Drafts live in the operator's session, keyed by feature intent and decision,
so partial progress survives the redirected render, refreshes, and navigation;
responses are limited to 500 characters before submission to fit bounded cookie
storage. Only the draft whose decision was successfully saved is cleared.

Explicit preference persistence is separate from inference about current
intent. A statement's scope must be explicit or clarified. User-scoped settings
do not overwrite shared project choices. Inspection/correction/deletion uses
the same authorization as the equivalent setting. Deleting a preference stops
its future use; historical decision evidence remains attributable under normal
retention policy rather than being rewritten as if it never existed.

## Readiness handoff

For each issue, the agent proposes which facets materially constrain its scope
and which documents define it. An explicit coverage assessment prevents an
empty list from passing by vacuous truth. Structural code requires every
mapped prerequisite's intent and technical score to pass separate project
thresholds, default 80/80. Settings changes are authorized and audited. Pending,
failed and unknown assessments fail initial readiness with an explanation.

Do not evaluate the entire feature for every issue. Research work can proceed
with a clear investigation scope/method while dependent implementation waits.
Builders get every relevant active candidate direction with independent scores,
the admitted issue baseline and mapped design paths, and source summaries.
Human statements and corrections are expressed intent; repository facts and
experiment results are demonstrated feasibility. Inferred fit is a dedicated
structured assessment, labeled as such and never as a new expressed preference.
Missing evidence and scores remain unknown. After admission,
new findings follow the delivery segment rather than revoking the run.

## Decisions and alternatives

| Decision | Rationale | Alternative |
|---|---|---|
| Agent judgment, deterministic enforcement | Matches ZFC and permits semantic evidence review | Keyword/count scoring |
| Two axes for each facet/direction | Distinguishes desired behavior from feasible approach | Combined confidence |
| Unknown is explicit | Missing discussion is not approval or rejection | Fill missing scores with defaults |
| Minimum per prerequisite | Exposes blockers without holding unrelated scope | Average across the feature |

## Validation

Use a versioned evaluation corpus with provisional directions, corrections,
repeated agent suggestions, collaborator conflict, research scopes and strong
technical/unknown intent cases. Test evidence freshness, duplicate handling,
cross-tenant references and threshold boundaries deterministically. Report
human corrections, inappropriate releases, unnecessary clarification, cost
and later rework; do not optimize for rising scores alone.

The corpus is delivered as
[`assessment-corpus-manifest-v1.yml`](assessment-corpus-manifest-v1.yml)
(`facet-confidence-corpus-v1`), frozen against rubric `facet-confidence-v1`
and model `claude-sonnet-4-6`, including the 79/80 threshold-boundary shape.
`lib/facet_confidence/assessment_corpus_ledger.rb` validates the corpus,
binds every recorded assessment run to the corpus version/digest, rubric
version, model version, and input evidence revision, and rejects replays of
identical case input. An operational failure is not a verdict: it records no
scores, so it neither inflates certainty nor consumes the input revision a
later verdict run has to advance from — a provider outage cannot leave the
frozen corpus permanently unmeasurable. It locks validation and append as one
operation, and a re-run after a correction must cite that correction event as
its evidence.
`lib/facet_confidence/assessment_outcome_report.rb`
computes false readiness, unnecessary clarification, human corrections,
assessment cost, and downstream rework against the frozen expected bands, and
blocks threshold/rubric tuning proposals on incomplete metrics — throughput
alone never justifies tuning. A `failed` run is an operational
(provider/runtime) failure rather than an assessment verdict: it is reported
separately as an operational failure and never counted as unnecessary
clarification, false readiness, or a band divergence. Operators record runs
and follow-ups through
`bin/facet-confidence-assessment-evaluation`; the current measured values are
recorded in
[`assessment-evaluation-2026-10-23/`](assessment-evaluation-2026-10-23/README.md)
and remain not established until the operator-executed runs exist.

## Corpus measurement execution

The outcome measures are only meaningful when they come from the shipped
assessment path, so the corpus is executable rather than a document an operator
transcribes by hand. The runner materializes one frozen case as production
facet records — the facet, its candidate direction, and the case's ordered
attributable evidence with the corpus supersession applied — and runs
`FeatureIntents::AssessFacet` over them. The rubric, the prompt contract, the
model request, and the response validation are the shipped assessor; the
runner only supplies the case and reads the result back.

Those records exist only inside a rolled-back transaction. A corpus
measurement must never reach the readiness path, never leave synthetic tenant
data behind, and never enroll an old feature in a new assessment.

The run is recorded in the repository-visible corpus ledger through the shipped
append operation, which binds the corpus version and digest, the rubric and
model version, and the input evidence revision to every event and rejects a
replay of identical case input. The runner refuses to record a run the
provider served from another model than the corpus pins: the frozen corpus
measures one rubric under one model, and a substitute model's output is not
that measurement. A refused run is reported with its reason and never
silently attributed.

Cost provenance is the harness's own metadata; a run that measured no cost
records zero rather than an invented estimate. A failed run is an operational
failure, not an assessment verdict, and stays out of the false-readiness,
unnecessary-clarification, and band-divergence measures.

## Closeout evaluation entry point

A partial-closeout Inbox item that needs this measurement renders its current
evaluation packet before an operator starts work: the originating work item,
project, accepted-design/source revision, frozen corpus digest, rubric and
model identities, and corpus input-evidence revisions. This is an operator
surface over the shipped corpus and reporting machinery, not a second corpus
or a readiness override.

The entry point is blocked until the closeout's recorded prerequisites resolve.
Each blocker is rendered with the owner and recovery route supplied by the
closeout status, so an operator can distinguish missing implementation from a
pending measured run. The packet deliberately says that scores are policy
assessments rather than calibrated probabilities, and that a completed
evaluation neither closes the source issue nor enables delivery or changes the
default 80/80 thresholds.

Start/Resume begins one persisted evaluation per originating closeout, pinned
to the frozen corpus digest: repeated clicks resume the same evaluation, and a
changed corpus digest is a new evidence generation that supersedes the old
record rather than mutating it. The operator who starts the evaluation is its
sole reference judge. They record one blinded reference judgment per corpus
case — verdict status, intent band, technical band, readiness, one cited
evidence reference, and a reason — while the case shape, selection rationale,
and frozen expectations stay hidden from the labeling surface; a judgment's
readiness must follow from its judged bands (no averaging across axes).
Freezing requires every case labeled (skips block), re-checks the corpus
digest, and compiles the reproducible report comparing the frozen judgments
with the frozen expected bands, including citation compliance for cases that
name required or forbidden evidence. The report is retained on the evaluation
and reachable from the originating Inbox item. Judgments and the report are
evidence only: they never close the source issue, enable delivery, or change
the 80/80 defaults.
