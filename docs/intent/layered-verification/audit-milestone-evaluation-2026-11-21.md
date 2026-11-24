# RDR-076 first usable audit milestone evaluation — 2026-11-21

This is the independent-evaluation record for #4434. It evaluates the first
usable audit milestone only; it does not close #4385, authorize a repair, or
enable the add-on. The result is **failed / not yet accepted**.

## Basis and boundaries

The only live controlled execution admitted for this evaluation was audit run
`30343`. The issue's maintainer receipt records that it failed, retained
authentic results, retained findings `1` and `2`, created review package `1`,
and recorded no approvals. Its five-minute live allowance is exhausted and the
rollout gates have been restored off. The receipt also distinguishes a private
completion replay from a live audit and says it authorizes neither repair nor
enablement. See [the source receipt](https://github.com/viamin/paid/issues/4434#issuecomment-7061339020).

This repository checkout cannot independently query that run: `DATABASE_URL`
was not supplied to this evaluation environment. The source commit named by
the receipt (`ab025c1e7`) is not reachable from this shallow checkout. These
are reproducibility limits, not a substitute for the retained production
record.

## Criterion-level verification plan and result

| Issue criterion | Smallest credible verification | Result |
| --- | --- | --- |
| Synthetic fixtures with and without models; green local checks beside a known discrepancy | Permanent request/service examples for business/model conflict, no-model plans, TLC output, and ingested result synthesis | Mechanical coverage exists; live controlled adjudication is not established. |
| Wrong business interpretation; plans; unavailable tools and execution errors | Focused plan, TLC-runner, and ingest-result examples | Mechanical coverage exists; independent false-positive/miss adjudication is not established. |
| Project/chat initiation, report, Inbox/chat/deferral, clarification persistence, cancellation | Request and Inbox examples plus the retained failed run | Partial: request/Inbox behavior is mechanically covered; a complete independently reviewed live journey is not established. |
| Audit/clarification cannot repair or mutate maintained artifacts | Audit-completion and Inbox decision examples; no repair or approval in run `30343` | Supported for the retained run and mechanical boundary checks; this is not a repair closeout. |
| Expected/observed findings, misses, reproducibility, cost, human effort | This record and the live-run receipt | Failed: findings are retained, but expected-case labels, adjudication, costs, and review minutes were not recorded. |
| V1–V4, V6–V7, V17–V19 and audit portions of V10–V11/V20 | The reconciliation below, anchored to canonical EARS and focused test files | Failed: implementation claims are exercised, but the independent evaluation evidence is incomplete. |

The cited test files are durable regression evidence, not evidence that an
agent's own prose is correct. This evaluator ran the focused request, plan,
TLC, ingestion, Inbox, and audit-completion set: **189 examples, 0 failures**
(seed `43664`). The maintainer also reported 113 passing mechanical examples
for the layered-verification surfaces and 28 for Inbox decision, staleness,
deduplication, tenant-isolation, audit-workflow, and completion-replay
surfaces in the source receipt. `bin/rails db:prepare` could not connect to a
development PostgreSQL endpoint, so the retained live run cannot be inspected
from this environment.

## Controlled findings ledger

| Control | Expected finding / outcome | Observed evidence | Independent verdict |
| --- | --- | --- | --- |
| Formal-model ownership discrepancy with green model and unit checks | Source-grounded correspondence finding, not a green-check pass | Relevant fixture is present; run `30343` retained two findings, but the retained finding contents were not supplied here | Not adjudicated |
| No-formal-model eligibility contradiction | Source-grounded finding or explicit uncertainty without requiring a model | Relevant fixture is present; no live case-to-finding mapping is recorded in this evaluation | Not adjudicated |
| Business/model or business/spec misinterpretation | Finding or explicit uncertainty; formal notation cannot win by itself | Relevant request fixture is present; no independent label is recorded | Not adjudicated |
| Justified single-layer plan | Accepted only with fit, exclusions, inputs, assumptions, cost, and residual gaps | Focused plan fixture is present | Mechanically covered; no live adjudication |
| Missing tool / execution error | Explicit gap or error, never a silent pass | Focused TLC and ingestion fixtures are present | Mechanically covered; no live adjudication |
| Ambiguous authority | Unresolved finding; no silent authoritative choice | No independently reviewed live observation is recorded | Not adjudicated |

False positives and misses are therefore **not computable**, not zero. The
review package has no approval, so it cannot serve as independent confirmation
of either retained finding.

## Journey and safety reconciliation

| RDR review references | Canonical EARS | Concrete evidence | Evaluation state |
| --- | --- | --- | --- |
| V1–V4 | `LAYERED-VERIFY-006`, `-007`, `-021`, `-022`, `-024` | `spec/requests/projects/layered_verification_audits_spec.rb`; `spec/services/layered_verification/checks/tlc_runner_spec.rb`; `spec/services/layered_verification/audits/ingest_results_spec.rb` | Mechanical coverage only; controlled labels missing. |
| V6–V7 | `LAYERED-VERIFY-021`, `-023` | `spec/services/layered_verification/plans/build_spec.rb`; review-package specs listed by `LAYERED-VERIFY-023` | Mechanical coverage only; no independent business review approval. |
| Audit part of V10–V11 | `LAYERED-VERIFY-008`, `-010` | `spec/services/layered_verification/audits/ingest_results_spec.rb`; `spec/temporal/activities/complete_layered_verification_audit_activity_spec.rb`; run `30343` has no repair or approval | Supported boundary; the run failed rather than silently passed. |
| V17–V19 | `LAYERED-VERIFY-015`, `-016`, `-017`, `-018` | `spec/requests/inbox_spec.rb` (layered-verification cases from line 2965); `spec/services/layered_verification/audits/synthesize_coverage_spec.rb` | Inbox/deferral/persistence/dedup/staleness are mechanically covered; full independent journey not established. |
| Audit part of V20 | `LAYERED-VERIFY-013`, `-014` | `spec/requests/projects/layered_verification_audits_spec.rb`; `spec/mcp/tools/request_layered_verification_audit_spec.rb` | Mechanical request preview/start coverage only; live initiation-to-cancellation review incomplete. |

Chat, acknowledgment, and deferral are specifically evaluated as non-resolving
actions; clarification remains pending canonical persistence, and a separately
authorized repair remains required. No finding, review package, or test result
in this record authorizes repair or mutation of canonical intent, models,
specs, tests, or production code.

## Resource and review accounting

| Measure | Recorded value | Limitation |
| --- | --- | --- |
| Live execution allowance | 5 minutes spent | No per-check elapsed times retained in the supplied receipt. |
| Audit results / findings / packages | retained / 2 / 1 | Finding contents and their control-case mapping were not available in this environment. |
| Approvals | 0 | No independent reviewer verdict exists. |
| Agent/model cost | not recorded | Cannot be inferred from elapsed allowance. |
| Human review effort | not recorded | No reviewer identity, minutes, or adjudication ledger exists. |
| Reproducibility | limited | Local database unavailable; source closeout commit absent from shallow history; a new live run is not authorized by this record. |

## Focused gaps

1. Preserve a controlled-case ledger outside agent-authored reports: immutable
   case ID, expected finding/uncertainty, observed finding IDs, independent
   reviewer verdict, false-positive/miss classification, provenance, elapsed
   time, model/resource cost, and human review minutes.
2. Capture the complete issue-less audit journey once a new, separately
   authorized allowance exists: project and chat/MCP initiation, report,
   Inbox context/chat/deferral, clarification persistence, cancellation, and
   proof that neither audit nor approval starts repair or mutates maintained
   artifacts.

These are focused evaluation gaps, not a generic readiness audit. Until they
are resolved with inspectable evidence, retain the default-off rollout guard
and keep #4385 open.
