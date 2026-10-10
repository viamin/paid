# RDR-066 Continuation Audit — 2026-10-10

- **RDR**: [RDR-066: Feature Intent and Approval Lifecycle](RDR-066-feature-intent-approval-lifecycle.md)
- **Umbrella issue**: [#3860](https://github.com/viamin/paid/issues/3860) (open)
- **Conclusion**: **Partially Implemented.** The attachment and admission
  gaps identified in the October 1 audit are shipped. The epic must remain
  open because FEATURE-APPROVAL-019 is still an explicit EARS gap and RDR-067
  has not met its rollout-evaluation prerequisite.

This continuation checks the post-audit merges rather than treating their
closed child issues as proof: #4113 merged on 2026-10-02 and supplies the
feature/design/issue attachment path; #4114 merged on 2026-10-02 and supplies
the release-admission and design-PR reconciliation path.

## Acceptance evidence

| Criterion | Result | Code and test evidence |
| --- | --- | --- |
| Feature creation and LID planning attach to one held tree | Shipped | `FeatureIntents::AttachFromAgentRun` creates a feature, records API-sourced RDR/LID PR heads, and links filed issues; its callers are `Projects::AgentRunsController` and `CreatePullRequestActivity`. Coverage: `spec/services/feature_intents/attach_from_agent_run_spec.rb`, `spec/requests/projects/agent_runs_create_feature_spec.rb`, and `spec/temporal/activities/create_pull_request_activity_spec.rb`. |
| Every implementation run entry is held before release | Shipped | `Automation::Strategies::AutoPick::DefaultCandidateSource` excludes linked unreleased/missing-revision issues; `AgentRun` validates `FeatureIntents::RunAdmission` and snapshots the revision; `AgentRuns::RecheckIssueEligibility` cancels a newly-held queued run; `ProcessRunQueueJob` rechecks immediately before dispatch. Coverage: `spec/services/feature_intents/run_admission_spec.rb`, `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`, `spec/jobs/process_run_queue_job_spec.rb`, and `spec/models/agent_run_spec.rb`. |
| Reconciliation fails closed and records only authorized direct merges | Shipped | `FeatureIntents::ReconcileDesignPullRequest` calls `MarkApproved`, matches the provider-authenticated human to a Paid user, and invokes `Release` only after all required artifacts merge at the approved heads. Bot, incomplete, stale, unverified, and closed-unmerged cases stay held or return to design. Coverage: `spec/services/feature_intents/reconcile_design_pull_request_spec.rb`, `spec/services/feature_intents/release_spec.rb`, and `spec/requests/api/github_webhooks_spec.rb`. |
| Run-emitted questions and inferred decisions reach the Inbox | **Gap** | `AttachFromAgentRun` records only the brief, design PRs, and issue links. It does not create `FeatureIntentDecision` records from an explicit run summary; this is the documented open EARS claim FEATURE-APPROVAL-019 in `docs/intent/feature-approval/feature-approval-specs.md`. |
| RDR-067 interlock | Partially ready | The current RDR-067 status documents its independent review and final merge guard as shipped. Its rollout remains blocked on valid replacement evaluation evidence and an operator's scoped enablement of the amendment/enforcement flags; the flags are intentionally default-off. |

## Closure decision and prerequisites

Do **not** close #3860. The two merged implementation slices supersede the
October 1 attachment and admission gaps, so reopening #3863 or #3865 would
duplicate shipped work. Before closure, an owner must either implement
FEATURE-APPROVAL-019 with tests or explicitly amend the approved intent to
remove that requirement. Separately, RDR-067 needs its valid replacement
evaluation and a deliberate scoped production enablement; those are human
rollout decisions, not changes this audit may infer.

## Verification limitation

Dependency installation completed, but `bin/rails db:prepare` could not reach
PostgreSQL because this environment has no configured `DATABASE_URL` and no
local PostgreSQL socket. Consequently, this audit records static code and
spec evidence but does not claim a passing runtime test suite. Restore the
configured database service before relying on this audit as execution proof.
