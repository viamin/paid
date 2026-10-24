# EARS Specs: Confidence-Driven Delivery

Status: P01 foundation is implemented for `001`, `014`, and `015`; P10
implements publication, release and unified admission claims `002`–`006` and
`009`.

- [x] **CONFIDENCE-DELIVERY-001** — When enrolling a feature in confidence-driven delivery, Paid SHALL snapshot an explicitly selected policy; existing features SHALL retain their established policy unless deliberately migrated.
- [x] **CONFIDENCE-DELIVERY-002** — When a potential task has coherent purpose and scope but insufficient readiness, Paid SHALL publish a planning-held GitHub issue linked to its feature and prerequisites; speculative alternatives SHALL remain visible in Paid without requiring GitHub issues.
  *Tests:* `spec/services/feature_intents/publish_held_issue_spec.rb`, `spec/mcp/tools/publish_held_issue_spec.rb`.
  *Code:* `app/services/feature_intents/publish_held_issue.rb`, `app/mcp/tools/publish_held_issue.rb`.
- [x] **CONFIDENCE-DELIVERY-003** — When a confidence-driven issue's current material facet assessments pass, dependencies permit execution and relevant design documents expressing that scoped intent are merged, Paid SHALL automatically release its workflow-owned planning hold without requiring whole-feature human approval.
  *Tests:* `spec/services/feature_intents/release_issue_spec.rb`.
  *Code:* `app/services/feature_intents/release_issue.rb`.
- [x] **CONFIDENCE-DELIVERY-004** — When releasing a confidence-driven issue, Paid SHALL preserve unrelated labels and human holds and record the issue scope, policy, assessment/evidence revisions, thresholds and merged design baseline that justified release.
  *Tests:* `spec/services/feature_intents/release_issue_spec.rb`, `spec/models/agent_run_spec.rb`.
  *Code:* `app/services/feature_intents/release_issue.rb`, `app/models/agent_run.rb`.
- [x] **CONFIDENCE-DELIVERY-005** — When admitting confidence-driven work through auto-pick, eager enqueue, dequeue, API/chat, manual start or run creation, Paid SHALL enforce the same readiness/dependency contract and SHALL NOT interpret a missing assessment as ready.
  *Tests:* `spec/models/agent_run_spec.rb`, `spec/services/feature_intents/run_admission_spec.rb`, `spec/services/issues/enqueue_eligible_spec.rb`.
  *Code:* `app/services/feature_intents/run_admission.rb`, `app/services/issues/enqueue_eligible.rb`, `app/models/agent_run.rb`.
- [x] **CONFIDENCE-DELIVERY-006** — When external label edits or failed GitHub writes leave visible readiness inconsistent with local state, Paid SHALL reconcile idempotently and expose the discrepancy rather than silently bypass readiness or silently retain an unexplained feature gate.
  *Tests:* `spec/services/feature_intents/release_issue_spec.rb`, `spec/services/issues/bulk_enqueue_eligible_spec.rb`.
  *Code:* `app/services/feature_intents/release_issue.rb`, `app/services/issues/bulk_enqueue_eligible.rb`.
- [x] **CONFIDENCE-DELIVERY-007** — When confidence decreases or intent changes after a confidence-driven run starts, Paid SHALL preserve its admitted baseline and SHALL NOT pause or cancel the run solely for that finding, regardless of whether feature-flag isolation is possible.
- [x] **CONFIDENCE-DELIVERY-008** — When an impact assessment identifies a new finding affecting confidence-driven work, Paid SHALL update an appropriate unstarted issue or create a deduplicated follow-up linked as a blocking dependency of the overall completion issue. When the assessment fails, Paid SHALL raise for retry before creating or editing remote forward work.
- [x] **CONFIDENCE-DELIVERY-009** — When an unstarted issue's scope changes concurrently with admission, Paid SHALL either admit its revised ready scope or preserve the already-started snapshot and record follow-up work, without silently changing the active run's scope.
  *Tests:* `spec/services/feature_intents/release_issue_spec.rb`, `spec/models/agent_run_spec.rb`, `spec/jobs/process_run_queue_job_spec.rb`.
  *Code:* `app/services/feature_intents/release_issue.rb`, `app/models/agent_run.rb`, `app/jobs/process_run_queue_job.rb`.
- [x] **CONFIDENCE-DELIVERY-010** — When reviewing a confidence-driven PR, Paid SHALL use its admitted scope/design baseline, preserve ordinary CI/security/quality/current-head/merge controls and SHALL NOT impose the approval-gated amendment pause solely because later feature intent differs.
  *Tests:* `spec/services/intent_conformance/signal_spec.rb`, `spec/services/intent_conformance/verify_at_merge_spec.rb`, `spec/services/feature_intents/admitted_intent_context_spec.rb`.
  *Code:* `app/services/intent_conformance/signal.rb`, `app/services/intent_conformance/verify_at_merge.rb`, `app/services/feature_intents/admitted_intent_context.rb`.
- [x] **CONFIDENCE-DELIVERY-011** — When attempting feature completion, Paid SHALL verify acceptance and all implementation/follow-up dependencies, including pending external writes and concurrent findings, before reporting completion.
  *Tests:* `spec/services/feature_intents/complete_forward_work_spec.rb`.
  *Code:* `app/services/feature_intents/complete_forward_work.rb`, `app/models/feature_intent_completion.rb`.
- [x] **CONFIDENCE-DELIVERY-012** — When a finding arrives after feature completion, Paid SHALL reopen completion or create a linked completion cycle and SHALL NOT leave the unresolved gap represented as completed.
  *Tests:* `spec/services/feature_intents/complete_forward_work_spec.rb`, `spec/services/feature_intents/complete_forward_work_concurrent_first_findings_spec.rb`.
  *Code:* `app/services/feature_intents/complete_forward_work.rb`, `app/models/feature_intent_completion.rb`.
- [ ] **CONFIDENCE-DELIVERY-013** — While implementing confidence-driven features, Paid SHALL use feature flags where feasible and SHALL require follow-up completion before declaring readiness for activation; impossible isolation SHALL NOT itself pause in-flight work, and activation SHALL follow project release policy.
- [x] **CONFIDENCE-DELIVERY-014** — When enabling automatic confidence-driven release, Paid SHALL require admission, policy-specific review and completion wiring to be available; shadow assessment alone SHALL NOT change execution eligibility.
- [x] **CONFIDENCE-DELIVERY-015** — When confidence-driven enrollment is disabled, Paid SHALL preserve existing feature policy snapshots, evidence and run state and SHALL NOT automatically release held issues or pause active runs.
- [x] **CONFIDENCE-DELIVERY-016** — When rendering a confidence-driven feature in the Inbox, Paid SHALL evaluate linked issue mappings with `ScopedReadiness` and SHALL admit it only for a recorded concrete human decision. It SHALL expose the policy, scoped blockers, and the specific answer-or-direction action through the web and supported API surfaces; it SHALL NOT offer feature approval, treat background assessment or dependency waits as an Inbox action, or let an answer/evidence submission attest readiness or execution authority.
  *Tests:* `spec/services/inbox/queue_spec.rb`, `spec/services/inbox/feature_decision_summary_spec.rb`, `spec/serializers/api/v1/inbox_entry_serializer_spec.rb`, `spec/views/dashboard/inbox_detail_feature_decision_partial_spec.rb`.
  *Code:* `app/services/inbox/feature_decision_readiness.rb`, `app/services/inbox/queue.rb`, `app/services/inbox/feature_decision_summary.rb`, `app/serializers/api/v1/inbox_entry_serializer.rb`, `app/views/dashboard/_inbox_detail_feature_decision.html.erb`.
