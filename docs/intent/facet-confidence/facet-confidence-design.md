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
Builders get applicable scores, explanations and source summaries; inferred
fit is labeled as such, never as a new expressed preference. After admission,
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
