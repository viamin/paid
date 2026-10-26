# Operator runbook — RDR-070 corpus evaluation

Reproducible procedure for measuring facet-confidence readiness and
clarification quality against the frozen corpus. Every command is plain Ruby;
no Rails environment is required.

## 1. Freeze (done)

The corpus
[`../assessment-corpus-manifest-v1.yml`](../assessment-corpus-manifest-v1.yml)
is committed with `corpus_version: facet-confidence-corpus-v1`. Do not edit a
frozen corpus: bump to a new versioned manifest file instead, so recorded
ledger events keep validating against the content they were measured with.

## 2. Assess each case

In the application environment that serves `claude-sonnet-4-6`, run the
shipped assessment path for the target project:

```bash
bin/rails "facet_confidence:corpus:run[<project-id>]"
```

The task retries only cases whose latest event is `failed`; a provider/runtime
failure has no verdict and therefore is not a replay of certainty. It appends
one provenance-complete event per attempted case to the repository ledger. It
does not change readiness, thresholds, rubric, or release policy.

The lower-level append command remains available for operator-recorded
follow-ups and recovery. For each corpus case, replay the frozen evidence
(in `occurred_at` order, honoring `supersedes`) through the production
assessment path — or an operator-controlled harness that uses the same rubric
`facet-confidence-v1`, model `claude-sonnet-4-6`, and prompt contract as
`FeatureIntents::AssessFacet` — and record the outcome:

```bash
bin/facet-confidence-assessment-evaluation append \
  --corpus docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml \
  --ledger docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl \
  --event '{"event_id":"run-FC-CORPUS-01","recorded_at":"<ISO-8601>","type":"assessment_run",
            "case_id":"FC-CORPUS-01","rubric_version":"facet-confidence-v1","model_version":"claude-sonnet-4-6",
            "input_revision":2,"status":"completed","intent_score":<0-100>,"technical_score":<0-100>,
            "evidence_references":["<case references>"],"cost_cents":<int>}'
```

Rules enforced by `validate`:

- The first run of a case must assess the frozen baseline revision (the
  case's evidence count, shown as `evidence_revision` by `load_corpus`).
- A re-run after a verdict must advance `input_revision` and have an
  intervening `correction` event at that revision — identical input cannot be
  replayed to inflate certainty. A failed provider/runtime attempt records no
  verdict and can be retried on its same frozen input.
- `completed` runs require both bounded scores and evidence references drawn
  from the case; `explicit_correction` cases must cite the correction
  evidence and must not cite the superseded statement.

## 3. Record follow-ups

A human challenge after a run is a `correction` event (statement + new input
revision); downstream rework caused by a run outcome is a `rework` event
(referencing that run's `event_id` and a cost):

```bash
bin/facet-confidence-assessment-evaluation append --corpus <manifest> --ledger <ledger> \
  --event '{"event_id":"correction-FC-CORPUS-01","recorded_at":"<ISO-8601>","type":"correction",
            "case_id":"FC-CORPUS-01","input_revision":3,"statement":"<human correction>","supersedes_reference":"<ref>"}'
bin/facet-confidence-assessment-evaluation append --corpus <manifest> --ledger <ledger> \
  --event '{"event_id":"rework-FC-CORPUS-01","recorded_at":"<ISO-8601>","type":"rework",
            "case_id":"FC-CORPUS-01","run_event_id":"run-FC-CORPUS-01","cost_cents":<int>,"description":"<what was redone>"}'
```

## 4. Validate and compile

```bash
bin/facet-confidence-assessment-evaluation validate --corpus <manifest> --ledger <ledger>
bin/facet-confidence-assessment-evaluation compile   --corpus <manifest> --ledger <ledger>
```

`compile` exits `pending operator input` (2) until every corpus case has at
least one run. Once complete it prints the outcome worksheet — false
readiness, unnecessary clarification, human corrections, assessment cost,
downstream rework, band divergences, operational failures, and the tuning
gate — which the operator
mirrors into [`outcome-worksheet-2026-10-23.md`](outcome-worksheet-2026-10-23.md).

## 5. Evaluate quality before tuning

Use the compiled measures to evaluate assessment quality first. Any threshold
or rubric tuning proposal must cite these metrics and explain why the change
reduces false readiness or unnecessary clarification without hiding real
uncertainty; do not tune scores solely to increase release throughput.
