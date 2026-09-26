# RDR-067 Audit Report — 2026-09-26

- **RDR**: [RDR-067: Approved Intent Conformance for Feature PRs](RDR-067-approved-intent-conformance.md)
- **Audit date**: 2026-09-26
- **Closeout issue**: [#3871](https://github.com/viamin/paid/issues/3871) (epic [#3861](https://github.com/viamin/paid/issues/3861))
- **Conclusion**: **Partially Implemented.** The current-head/current-design
  merge guard and Inbox escalation have shipped with passing tests. Evaluation
  results are absent, and the independent reviewer has no production trigger.

Follows the [RDR Closeout Checklist](closeout-checklist.md). This audit is
against the current branch on 2026-09-26. It does not infer implementation
from issue state: #3866–#3869 are closed, while #3870 remains open.

## Acceptance Criteria vs. Shipped Implementation

| Issue #3871 criterion | Status | Evidence |
|---|---|---|
| Current-head/current-design merge protection and Inbox escalation are proven by tests. | Satisfied | `IntentConformance::VerifyAtMerge` checks the exact PR head and approved design revision before merge ([`app/services/intent_conformance/verify_at_merge.rb`](../../app/services/intent_conformance/verify_at_merge.rb):44–55, 74–79), and `MergePullRequestActivity` exercises the guard's push/design-revision race paths ([`spec/temporal/activities/merge_pull_request_activity_spec.rb`](../../spec/temporal/activities/merge_pull_request_activity_spec.rb):202–298). The scanner signal is current-head-bound ([`app/services/intent_conformance/signal.rb`](../../app/services/intent_conformance/signal.rb):23–29, 39–41; [`spec/services/intent_conformance/signal_spec.rb`](../../spec/services/intent_conformance/signal_spec.rb)), and the distinct Inbox lane exposes failed `intent_conformance_ok` blockers ([`app/services/inbox/intent_conformance.rb`](../../app/services/inbox/intent_conformance.rb):25–29, 64–93; [`spec/services/inbox/intent_conformance_spec.rb`](../../spec/services/inbox/intent_conformance_spec.rb)). |
| False-alarm and missed-drift evaluation results are recorded. | Not satisfied | A case-insensitive repository search finds no evaluation harness, fixtures, metrics, or recorded results for RDR-067 false alarms or missed drift. The only matches are the RDR requirement and the prior audit. Open [#3870](https://github.com/viamin/paid/issues/3870) owns this work. |
| The audit updates RDR-067 and its README row only when evidence supports the status. | Satisfied | The evidence above supports **Partially Implemented**, not Implemented: this audit updates the RDR status section and README row accordingly. |
| The closeout PR visibly closes epic #3861 only if fully implemented. | Satisfied | This is a partial closeout. The report and RDR explicitly require tracking language only; epic [#3861](https://github.com/viamin/paid/issues/3861) remains open. |

## Test Evidence

The following focused suite passed during this audit:

```text
bundle exec rspec \
  spec/services/intent_conformance/verify_at_merge_spec.rb \
  spec/temporal/activities/merge_pull_request_activity_spec.rb \
  spec/services/intent_conformance/signal_spec.rb \
  spec/services/inbox/intent_conformance_spec.rb \
  spec/services/inbox/queue_spec.rb \
  spec/requests/inbox_spec.rb \
  spec/temporal/activities/scan_paid_prs_activity_spec.rb
```

## Remaining Gaps

1. **Independent review trigger.** `IntentConformance::ReviewRun` is a tested
   service, but CodeGraph finds no production caller from the PR scanner or
   another runtime path. Thus a feature PR can have the correct fail-closed
   `verdict_missing` result without receiving the review required by RDR-067.
   A focused child issue must schedule/de-duplicate review runs per current
   PR HEAD and approved design revision. The audit attempted to file it, but
   the environment has no GitHub write credential. Until that issue exists,
   this report tracks #3871 rather than closing it.
2. **Evaluation and rollout evidence.** No false-alarm/missed-drift results
   are recorded. Existing open issue [#3870](https://github.com/viamin/paid/issues/3870)
   already owns this gap, so no duplicate issue is needed.
3. **Design-document population.** RDR-066 lifecycle work owns population of
   `feature_intents.design_document_paths`; until then `ReviewRun` correctly
   records `not_evaluated` rather than treating missing evidence as approval.

## Status Decision

**Partially Implemented** is the only supported closeout status. The core
guard and Inbox acceptance criterion has shipped with executable test evidence,
but the reviewer trigger and representative evaluation results are absent.
`Implemented`, `Superseded`, and `Abandoned` are unsupported by the current
code and documentation.

## Epic Closure

Do **not** close [#3861](https://github.com/viamin/paid/issues/3861). The PR
description must say `Tracks #3861` and `Tracks #3871`, not `Closes` either
issue. #3871 remains open until the child gap issue exists and the issue owner
accepts this partial closeout workflow.
