# RDR-069–071 Final Umbrella Acceptance Audit — 2026-10-22

- **Umbrella**: [#4309](https://github.com/viamin/paid/issues/4309)
- **RDRs**: [RDR-069](RDR-069-question-centered-chat-exploration.md),
  [RDR-070](RDR-070-facet-confidence-and-clarification.md), and
  [RDR-071](RDR-071-confidence-driven-issue-delivery.md)
- **Conclusion**: **Do not close #4309.** All three RDRs are **Partially
  Implemented**. The audit corrects the evidence ledger for shipped
  completion-forward-work behavior, but bounded investigation, held-issue
  publication, activation/isolation reporting, and the representative
  assessment corpus remain required work.

This audit is the umbrella's own final-acceptance pass. It compares the
accepted RDRs and their LLD/EARS claims with current code and focused test
results. It does not count closed children, historical closeouts, or approval-
gated RDR-066/067 foundations as evidence for the new policy.

## Acceptance evidence

| User outcome | Result | Current implementation evidence |
| --- | --- | --- |
| Open an Inbox question in contextual chat, retain partial answers, and explore/comment on a safe question-linked diagram | Shipped, subject to browser-environment verification | `ClarifyingQuestions::OpenChat`, `ClarifyingQuestions::SaveProgress`, `ChatDiagram`, `ChatDiagrams::Comment`, `ChatDiagrams::Replace`, and their model/service/request specs implement question linkage, durable textual context, safe typed cards, attributed comments, replacement, and stale-element protection. `QUESTION-EXPLORATION-003`–`006`, `009`, `011`, and `013` are marked implemented in the EARS ledger. |
| Correct an assessment, retain attributable evidence, and see why scoped work is ready | Shipped | `FeatureIntents::AssessFacet`, `ChallengeFacetAssessment`, `ScopedReadiness`, and `ExplicitPreferences` preserve independent scores, evidence revisions, correction precedence, explicit scoped preferences, and independent 80/80 readiness checks. `spec/services/feature_intents/assess_facet_spec.rb`, `challenge_facet_assessment_spec.rb`, and `scoped_readiness_spec.rb` cover the contract. |
| Release a confidence-driven issue only from an immutable, scoped readiness baseline, while retaining approval-gated policy | Shipped | `FeatureIntents::ReleaseIssue` snapshots the passing scope and removes only Paid's `planning` label; `RunAdmission` rechecks the contract for every linked feature. `release_issue_spec.rb` and `run_admission_spec.rb` cover label preservation, failed reconciliation, multiple feature links, dependencies, scope races, and admission. |
| Keep active work moving while new findings create completion-blocking forward work | Shipped | `FeatureIntents::CompleteForwardWork` records a deduplicated finding, reads back the completion dependency, prevents completion with pending/open work, and reopens a completed cycle. `DesignAmendments::EvaluateImpact` routes confidence findings without an amendment pause. The EARS ledger now correctly marks `CONFIDENCE-DELIVERY-011` and `012` implemented. |
| Start a bounded exploration investigation with budget/policy reservation, overage authorization, progress, cancellation, reconnect, and API/tool parity | **Gap** | `QUESTION-EXPLORATION-010` remains unchecked. The investigation portion of `QUESTION-EXPLORATION-012` consequently remains unchecked. Focused owner: [#4317](https://github.com/viamin/paid/issues/4317) (P08). |
| Publish coherent-but-not-ready work as a planning-held issue while keeping speculative alternatives in Paid | **Gap** | `CONFIDENCE-DELIVERY-002` remains unchecked. The existing release path reconciles a linked held issue; it does not implement this publication contract. Focused owner: [#4319](https://github.com/viamin/paid/issues/4319) (P10). |
| Verify feature activation/isolation and the representative confidence corpus before claiming full delivery | **Gap** | `CONFIDENCE-DELIVERY-013` remains unchecked, and RDR-070's required corpus/measurement evidence has not been recorded. Focused owners: [#4321](https://github.com/viamin/paid/issues/4321) (P12) and [#4323](https://github.com/viamin/paid/issues/4323) (C70). |

## Verification

The following focused, database-backed audit suite passed on 2026-10-22:

```text
bundle exec rspec \
  spec/models/chat_diagram_spec.rb \
  spec/models/chat_diagram_comment_spec.rb \
  spec/services/chat_diagrams/comment_spec.rb \
  spec/services/chat_diagrams/replace_spec.rb \
  spec/services/clarifying_questions/save_progress_spec.rb \
  spec/services/explicit_preferences/persist_spec.rb \
  spec/services/explicit_preferences/context_spec.rb \
  spec/services/feature_intents/assess_facet_spec.rb \
  spec/services/feature_intents/challenge_facet_assessment_spec.rb \
  spec/services/feature_intents/scoped_readiness_spec.rb \
  spec/services/feature_intents/release_issue_spec.rb \
  spec/services/feature_intents/run_admission_spec.rb \
  spec/services/feature_intents/complete_forward_work_spec.rb \
  spec/services/feature_intents/complete_forward_work_concurrent_first_findings_spec.rb \
  spec/services/design_amendments/evaluate_impact_spec.rb \
  spec/services/intent_conformance/verify_at_merge_spec.rb \
  spec/system/chat_diagrams_spec.rb \
  spec/requests/chat_diagram_comments_spec.rb \
  spec/requests/api/v1/chat_diagram_comments_spec.rb
```

Result: **135 examples, 0 failures, 3 pending**. The three pending examples
are the browser-dependent `spec/system/chat_diagrams_spec.rb` cases; Chromium
is not installed in this audit environment. They remain required evidence for
the RDR-069 mobile/keyboard acceptance slice and must run in a browser-enabled
environment before closure.

`bin/ci` was also invoked. Its setup phase could not connect to PostgreSQL on
the configured local socket while preparing the database, so this audit does
not present the full CI wrapper as passing. No destructive database recovery
was attempted; the focused suite above is the executable evidence for this
audit.

## Rollout guards and closure disposition

RDR-069's project-level exploration setting remains the gate for the
feature-conversation path. RDR-070's shadow-mode rule remains a constraint on
confidence release until the complete RDR-071 path has evidence. RDR-071's
policy snapshot keeps approval-gated features unchanged and does not pause
active work. This audit changes none of those guards, project settings, policy
snapshots, or run state.

No duplicate issues are filed: every required gap already has a focused owner.
The closeout records must use `Tracks #4309`; only a later umbrella audit may
use closing language after these gaps and the browser/corpus evidence resolve.
