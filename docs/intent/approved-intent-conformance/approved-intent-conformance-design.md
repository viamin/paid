# Design: Approved Intent Conformance (PR scanner + Inbox surface)

## Policy scope

This document defines the **approval-gated** feature policy. Its whole-feature
approval, amendment holds and latest-approved-revision rules do not govern
features explicitly enrolled in the planned [confidence-driven policy](../../rdrs/RDR-071-confidence-driven-issue-delivery.md).
Those features use issue-level readiness and completion-blocking follow-ups;
existing features retain their policy until deliberately migrated. Shared
record types and ordinary CI/security/quality checks remain reusable.

> Segment: approved-intent-conformance · Status: partial (issue #3867 scope)
> Specs: [approved-intent-conformance-specs.md](approved-intent-conformance-specs.md)
> RDR: [RDR-067](../../rdrs/RDR-067-approved-intent-conformance.md)

## Problem

RDR-067 requires an independent conformance verdict on every feature PR, and
material drift, uncertainty, missing evidence, or reviewer failure must block
auto-merge until a human resolves it. Issue #3867 scopes the PR-scanner and
Inbox half of that decision: persist the verdict, add it to the auto-merge
blocker snapshot, and give a human a typed Inbox decision — cited claim,
relevant diff, reviewer evidence, and the three resolution actions (fix PR,
bounded exception, design amendment).

The independent reviewer run that *produces* a verdict (agent_harness call
comparing PR diff to the approved design) and the final-merge-activity race
check are out of this segment's scope — RDR-067's own implementation plan
splits those into separate issues (the reviewer run, and final-merge
enforcement). This segment defines the verdict/decision persistence contract
because nothing else in the repository does yet, and the blocker/Inbox surface
cannot exist without something to read.

## Approach

1. **Verdict persistence** (`IntentConformanceVerdict`) — one row per
   reviewer run, keyed by `(issue, pr_head_sha)`. `outcome` is one of
   `within_scope`, `material_drift`, `uncertain`, `not_evaluated`. The most
   recently evaluated row for the PR's current HEAD is authoritative; a row
   for an older HEAD is not consulted — a new commit always invalidates the
   old verdict (RDR-067 Decision section, "A changed PR head... invalidates
   the verdict").
2. **Signal integration** — `IntentConformance::Signal.ok?` computes a new
   `intent_conformance_ok` boolean signal, added to
   `Automation::Strategies::AutoMerge::Signals` and
   `AutoMerge::HUMAN_SIGNAL_DEFINITIONS` (human-authored PRs only; bot/
   dependency-update PRs are not feature PRs bound to an approved design).
   `ok?` is true when the current HEAD has a `within_scope` verdict, or a
   matching `bounded_exception` decision. It is false — blocking auto-merge —
   for `material_drift`, `uncertain`, `not_evaluated`, and a missing verdict
   alike, since RDR-067 requires all four to fail closed.
3. **Rollout gate** — enforcement is behind the `intent_conformance_enforcement`
   feature flag (default off, per project). RDR-067's own rollout guard ties
   enforcement to the RDR-066 named feature operating mode, which does not
   exist in this codebase yet; the flag is the interim substitute and is
   documented to be replaced once RDR-066 ships.
4. **PR-scanner wiring** — `ScanPaidPrsActivity` already persists the auto-merge
   blocker snapshot to `issues.auto_merge_blockers` every scan pass
   (RDR-067's "PR scanner already persists blockers" precedent). This segment
   adds `issues.last_scanned_head_sha`, persisted alongside the snapshot, so
   the Inbox can look up the verdict for the exact HEAD the scanner just
   evaluated without an extra GitHub call.
5. **Inbox lane** (`intent_conformance` kind) — `Inbox::IntentConformance`
   mirrors `Inbox::MergeApproval`'s "read the persisted blocker snapshot,
   filter to one signal" shape, but the `intent_conformance_ok` signal is
   deliberately excluded from `Inbox::MergeApproval::APPROVAL_SIGNALS` so a
   material-drift block can never be miscategorized as an ordinary
   owner-approval wait (RDR-067 Decision section). The detail pane shows the
   verdict's cited design claims, cited diff locations, reasoning summary,
   and outcome, plus the most recent human decision if one exists.
6. **Human decision** (`IntentConformanceDecision`) — one row per resolution,
   scoped to `(issue, action, head_sha)`. `bounded_exception` only clears the
   blocker while the PR HEAD still matches the recorded `head_sha`
   (`IntentConformanceDecision.active_bounded_exception?`); a new commit
   requires a fresh decision. `design_amendment` records the human's intent
   to route the PR's feature back through RDR/LID review — the pause/impact
   mapping this triggers (RDR-067 "Revision impact") is explicitly out of
   this segment's scope. `fix_pr` records that the human asked the agent to
   bring the PR back into scope; it does not itself change the blocker state
   — a fresh `within_scope` verdict on a new HEAD does.

## Non-goals (this segment)

- Producing a verdict (the independent `agent_harness` reviewer run).
- Final-merge-activity race enforcement (a fresh verdict/head check
  immediately before requesting merge).
- Design-amendment impact mapping across open PRs, unstarted issues, and
  dependency closure.
- Tying enforcement to the RDR-066 named feature operating mode (that mode
  does not exist yet; `intent_conformance_enforcement` is the interim gate).
