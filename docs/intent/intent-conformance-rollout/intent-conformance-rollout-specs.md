# EARS Specs: Intent-Conformance Measured Rollout

> Testable claims for RDR-067 issue #3870. Status markers: `[x]` implemented
> · `[ ]` active gap · `[D]` deferred.

- [x] **INTENT-CONFORMANCE-ROLLOUT-001** — When a project enables only
  `intent_conformance_shadow_review` for a released feature intent with an
  approved design revision, the system SHALL schedule and run an independent
  conformance review, while the final merge guard remains disabled because it
  continues to require the complete enforcement pair.
  *Code:* `app/services/intent_conformance/schedule_review.rb`,
  `app/services/intent_conformance/review_run.rb`,
  `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/schedule_review_spec.rb`,
  `spec/services/intent_conformance/review_run_spec.rb`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-002** — Before a project enables the
  approval-gated operating mode, operators SHALL retain a frozen,
  independently adjudicated corpus containing accepted, intentionally drifted,
  and uncertain PR cases, and SHALL evaluate the reviewer in shadow mode.
  *Design:* `intent-conformance-rollout-design.md`.
  *Corpus:* `shadow-evaluation-manifest-2026-10-13.yml` freezes the 30-case
  corpus pinned to repository / base SHA / head SHA / approved design revision
  / model-prompt version.
  *Adjudication:* The prior label-only ledger is not qualifying evidence: its
  entries were introduced under one bot identity, so it cannot prove two
  independent human adjudicators. The corpus requirement remains unmet until
  two distinct, authenticated human operators adjudicate every case while
  blind to reviewer output. Only then may `shadow-run` record reviewer runs.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-003** — The rollout record SHALL measure
  false alarms, missed material drift, escaped changes, reviewer cost, human
  resolution time, rework, and delivery time against a predeclared same-project
  baseline and promotion rule.
  *Design:* `intent-conformance-rollout-design.md`.
  *Worksheet:* `shadow-evaluation-worksheet-2026-10-13.md` records the
  frozen corpus and marks every adjudication- and reviewer-derived measure
  `not established`. The promotion decision stays unestablished until the
  independent human adjudications and reviewer runs exist.

- [x] **INTENT-CONFORMANCE-ROLLOUT-004** — Operators SHALL not release
  feature work into the mode until scanner enforcement and the final merge
  guard are active; rollback SHALL disable both guard flags, stop new mode
  releases, and hold outstanding candidates rather than treating an absent
  review as approval.
  *Design:* `intent-conformance-rollout-design.md`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-005** — When a project operator explicitly
  selects the solo-maintainer evaluation policy for a frozen corpus, the
  system SHALL record the declaration before any label, restrict labeling,
  revision, and freeze actions to the declared authenticated maintainer under
  existing tenant/project authorization, support durable save, resume, and
  skip per case, and SHALL refuse to freeze while any case is unlabeled or
  skipped. A ledger without a declaration SHALL retain the two-operator team
  policy and SHALL NOT reinterpret historical bot-authored records as solo
  human evidence.
  *Design:* `intent-conformance-rollout-design.md` §Solo-maintainer
  evaluation policy.
  *Code:* `lib/intent_conformance/shadow_evaluation_policy.rb`,
  `lib/intent_conformance/shadow_evaluation_ledger.rb`,
  `app/services/intent_conformance/shadow_evaluation/start.rb`,
  `app/services/intent_conformance/shadow_evaluation/record_label.rb`,
  `app/services/intent_conformance/shadow_evaluation/freeze_labels.rb`.
  *Test:* `spec/lib/intent_conformance/shadow_evaluation_policy_spec.rb`,
  `spec/lib/intent_conformance/shadow_evaluation_ledger_spec.rb`,
  `spec/services/intent_conformance/shadow_evaluation/`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-006** — While an evaluation's reference
  labels are unfrozen, the labeling surface SHALL NOT expose reviewer
  outputs, preassigned strata, or expected labels, and reviewer execution
  SHALL be refused until the reference set is frozen.
  *Design:* `intent-conformance-rollout-design.md` §Blinded before freeze.
  *Code:* `app/services/intent_conformance/shadow_evaluation/case_view.rb`,
  `app/services/intent_conformance/shadow_evaluation/execute_reviewer.rb`.
  *Test:* `spec/requests/projects/shadow_evaluations_spec.rb`,
  `spec/services/intent_conformance/shadow_evaluation/execute_reviewer_spec.rb`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-007** — After reference labels are frozen,
  a documented command or job SHALL execute the actual conformance reviewer
  for every corpus case through `agent_harness` and record actual verdicts,
  reviewer model, prompt digest, cost, and failures; missing or failed
  reviewer output SHALL be recorded as not evaluated rather than counted as
  agreement, and prerequisite validation alone SHALL NOT be presented as
  execution.
  *Design:* `intent-conformance-rollout-design.md` §Labeling lifecycle.
  *Code:* `app/services/intent_conformance/reviewer_llm.rb`,
  `app/services/intent_conformance/shadow_evaluation/execute_reviewer.rb`,
  `lib/tasks/intent_conformance.rake`,
  `bin/intent-conformance-shadow-evaluation`.
  *Test:* `spec/services/intent_conformance/shadow_evaluation/execute_reviewer_spec.rb`,
  `spec/bin/intent_conformance_shadow_evaluation_spec.rb`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-008** — The evaluation record SHALL produce
  a reproducible report with exact case/rubric/model/prompt/design
  identities, original reference labels, reviewer verdicts, confusion
  counts, false alarms, missed drift, uncertainty handling, cost, and
  provenance; post-result label revisions SHALL be appended with reason and
  timestamp without overwriting the original blinded label or the scores
  computed from it. Before creating an evaluation, the system SHALL resolve
  the manifest commit and reject a manifest that is absent from that commit
  or whose local bytes differ from its committed blob.
  *Design:* `intent-conformance-rollout-design.md` §Labeling lifecycle.
  *Code:* `app/services/intent_conformance/shadow_evaluation/compile_report.rb`,
  `app/services/intent_conformance/shadow_evaluation/revise_label.rb`,
  `lib/intent_conformance/shadow_evaluation_worksheet.rb`.
  *Test:* `spec/services/intent_conformance/shadow_evaluation/compile_report_spec.rb`,
  `spec/lib/intent_conformance/shadow_evaluation_worksheet_spec.rb`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-009** — The originating partial-closeout
  Inbox item SHALL offer Start evaluation / Resume labeling with labeling
  progress and queued/running/failed/completed execution state, SHALL resume
  the existing evaluation for the same evidence generation instead of
  duplicating it, SHALL return to the same Inbox context without accepting
  an arbitrary external return URL, and finishing labels or a passing
  evaluation SHALL attach evidence without automatically attesting issue
  completion, closing GitHub work, or enabling enforcement.
  *Design:* `intent-conformance-rollout-design.md` §Labeling lifecycle.
  *Code:* `app/views/dashboard/_inbox_detail_partial_closeout.html.erb`,
  `app/controllers/projects/shadow_evaluations_controller.rb`.
  *Test:* `spec/requests/projects/shadow_evaluations_spec.rb`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-010** — Before a blinded labeler can open
  case evidence, the system SHALL authorize the project request, SHALL refuse
  the request when the corpus manifest no longer matches the digest recorded
  when the evaluation was created (a changed corpus is a new evidence
  generation), and SHALL validate the case repository, exact base/head or
  approved-design revision, and any declared design artifact through the
  project's repository-access service.
  It SHALL navigate only to fixed, revision-bound repository URLs, SHALL never
  render or execute repository content in the labeling request, and SHALL
  report unavailable evidence without substituting a branch, selection
  rationale, notes, context, stratum, expected label, or reviewer output.
  A corpus case without declared approved-design artifacts remains unavailable
  for that evidence and SHALL NOT be treated as independently assessed
  acceptance.
  *Design:* `intent-conformance-rollout-design.md` §Solo-maintainer evaluation
  policy and §Labeling lifecycle.
  *Code:* `app/services/intent_conformance/shadow_evaluation/evidence.rb`,
  `app/controllers/projects/shadow_evaluations_controller.rb`,
  `app/views/projects/shadow_evaluations/_labeling.html.erb`.
  *Test:* `spec/services/intent_conformance/shadow_evaluation/evidence_spec.rb`,
  `spec/requests/projects/shadow_evaluations_spec.rb`.

- [x] **INTENT-CONFORMANCE-ROLLOUT-011** — When an authorized operator starts,
  retries, resumes, or cancels an Inbox-linked frozen shadow evaluation, the
  system SHALL use one idempotent background lifecycle with queued, running,
  partial, failed, cancelled, and completed states. It SHALL expose durable
  per-case evaluated progress and cost, preserve collected evidence on
  cancellation, resume only cases without evaluated verdicts, compile available
  reports in the worker, and recover an interrupted worker without stranding a
  running evaluation. The UI and documented task SHALL use the same lifecycle.
  *Code:* `app/services/intent_conformance/shadow_evaluation/queue_reviewer_execution.rb`,
  `app/services/intent_conformance/shadow_evaluation/cancel_reviewer_execution.rb`,
  `app/jobs/intent_conformance/shadow_evaluation/execute_job.rb`.
  *Test:* `spec/jobs/intent_conformance/shadow_evaluation/execute_job_spec.rb`,
  `spec/requests/projects/shadow_evaluations_spec.rb`.
