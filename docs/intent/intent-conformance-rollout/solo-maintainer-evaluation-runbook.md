# RDR-067 solo-maintainer evaluation runbook (#4594)

This runbook covers the solo-maintainer evaluation policy end to end: freeze
a corpus, label it blinded as the single authenticated maintainer, freeze the
reference set, execute the real conformance reviewer, and compile the
reproducible report. The team policy (two independent operators plus a
tie-break) remains the default; see
[`shadow-evaluation-2026-10-13/operator-runbook.md`](shadow-evaluation-2026-10-13/operator-runbook.md)
for that flow. This runbook's policy is **explicitly selected** — nothing on
this page may be used to reinterpret a historical bot-authored ledger as
human evidence.

An agent may navigate, prepare the corpus, and pre-fill context, but every
reference label, revision, and freeze action must be recorded through the
authenticated maintainer's session. Model agreement is never independent
human validation.

## 1. Freeze a versioned corpus and rubric

1. Build or review the corpus manifest (same format as
   `shadow-evaluation-manifest-2026-10-13.yml`): every case pinned to
   repository, base SHA, head SHA, approved design revision, and
   model/prompt identity, with at least ten cases per stratum. Cases may come
   from historical implemented/closed tickets through their exact PR
   base/head diff and the approved design applicable at that time;
   merge/closure status never determines the reference label.
2. Review the corpus for answer leakage and suitability. Never treat the
   intended stratum as ground truth — the stratum stays hidden during
   labeling.
3. Include deliberate material-drift mutations and harmless implementation
   variations, explicitly identified as constructed evaluation cases in the
   retained evidence.
4. Commit the manifest and record the immutable `manifest_commit` SHA.

## 2. Start the evaluation (UI)

Open the originating partial-closeout Inbox item for the project and use
**Start evaluation**. Choose the solo policy and name yourself the
maintainer; the declaration is recorded before any label. Repeated opens
resume the same evaluation for that evidence generation (project + purpose +
manifest digest). A changed corpus or evidence revision supersedes prior
completion visibly instead of mutating it.

The equivalent CLI declaration for the repository-visible JSONL ledger is:

```bash
bin/intent-conformance-shadow-evaluation init \
  --manifest docs/intent/intent-conformance-rollout/<manifest>.yml \
  --ledger docs/intent/intent-conformance-rollout/<run>/adjudication-ledger.jsonl \
  --manifest-commit <frozen-manifest-sha> \
  --policy solo \
  --maintainer "<authenticated-maintainer-identity>"
```

Both paths use the same shared policy validation
(`lib/intent_conformance/shadow_evaluation_policy.rb`).

## 3. Label blinded (UI)

Work one case at a time: the pinned diff references (base…head), the
approved design revision and its documents, and supporting context. Record
`within_scope`, `material_drift`, or `uncertain` with a cited approved claim
and a reason. Save/resume is durable; a case may be skipped and a skipped
case is never counted as completed. Reviewer outputs and strata stay hidden
until freeze — the screen cannot show them, and execution is refused.

## 4. Freeze the reference set

The explicit **Finish labeling** action refuses while any case is unlabeled
or skipped. Freezing stamps the reference labels; from that point answers
become visible and execution is allowed.

## 5. Execute the real reviewer (queued job)

After freeze, queue the actual conformance reviewer for every case through
`agent_harness`. The UI action (or the documented command below) only
authorizes and enqueues an idempotent background job — the corpus never runs
inside the request:

```bash
bin/rails "intent_conformance:shadow_evaluation:execute[<evaluation-id>]"
```

The evaluation screen shows the durable execution state (`queued → running →
completed | partial | failed | cancelled`) with per-case progress and
recorded cost, refreshing while execution is active. Any project operator may
request cancellation — it takes effect between cases, preserves collected
evidence, and never fabricates unevaluated results:

```bash
bin/rails "intent_conformance:shadow_evaluation:cancel[<evaluation-id>]"
```

The execution records actual verdicts, reviewer model, prompt digest, cost,
and per-case failures. Missing or failed reviewer output is recorded as not
evaluated — prerequisite validation alone is never presented as execution.
A retry (UI action or the same command) resumes from the collected evidence
and only evaluates cases that lack an evaluated verdict, so completed-case
spend is never repeated. A killed worker, expired request, or lost lock is
recovered by the periodic sweep: the evaluation returns to a retryable
state with its evidence preserved rather than staying stuck as executing.

For the repository-visible JSONL ledger, the operator appends the recorded
`shadow_run` events with the CLI `append` command after the run, one event
per git commit, exactly as in the team runbook.

## 6. Review disagreements, revise, compile

After the run, disagreements surface for maintainer review. A post-result
revision is appended with its own reason and timestamp; the original blinded
label and every score derived from it are preserved. Compile the report:

```bash
bin/intent-conformance-shadow-evaluation compile \
  --manifest docs/intent/intent-conformance-rollout/<manifest>.yml \
  --ledger docs/intent/intent-conformance-rollout/<run>/adjudication-ledger.jsonl \
  --manifest-commit <frozen-manifest-sha>
```

or open the evaluation in the UI. The report records the solo policy and the
declared maintainer next to every measure, exact case/rubric/model/prompt/
design identities, original reference labels, appended revisions, reviewer
verdicts, confusion counts, false alarms, missed drift, uncertainty
handling, cost, and provenance.

## 7. What this does not do

- Missing production measures (escaped changes, delivery baseline, rework,
  human time) stay `not established` with an explicit rollout follow-up.
- The 30-case target and numerical promotion thresholds are unchanged; any
  change must be approved before evaluating, never tuned after results.
- Completing labels or a passing evaluation attaches evidence and refreshes
  acceptance status only. It never attests issue completion, closes GitHub
  work, or enables enforcement. Enforcement promotion remains the explicit
  human decision the RDR-067 rollout guard requires.
