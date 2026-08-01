---
parent: PAID
prefix: LID-PR-CONFIRM
---

# Low-Level Design: LID Planning PR Confirmation

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the docs-only Planning PR loop for LID adoption and
> conversion work.

## Purpose

`lid_planning` turns inferred intent into a reviewable Planning PR. The PR
body must enumerate the inferred decisions that need confirmation, and follow-up
runs on that PR must treat review comments on `[inferred]` lines as intent
corrections, not ordinary copy edits.

## Checklist derivation

Planning PRs derive a "Confirm These Inferred Decisions" checklist directly
from the branch contents. The checklist includes:

1. Changed lines that still carry a `[inferred]` marker.
2. Open questions surfaced under an LLD's `## Open Questions` section.

The source of truth is the changed docs on the branch, not a parallel database
record or a manually curated summary.

## Review-loop behavior

The existing PR follow-up path remains the correction mechanism. When a docs-only
Planning PR receives review feedback on an inferred line, the follow-up prompt
must tell the agent to:

1. Replace the `[inferred]` marker with the reviewer's authored rationale.
2. Cascade the correction into related LLD/EARS or open-question text on the
   same branch.
3. Leave comment-only feedback deferable and approvals as confirmation.
