# RDR-022: Auto-Merge PR Merge Strategy

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-11
- **Status**: Final
- **Type**: Process
- **Priority**: Medium
- **Related Issues**: #1003 (Merge strategy decision), #948 (Umbrella auto-merge issue)
- **Related PRs**: #950 (umbrella), #927 (trigger routing), #1000 (max review rounds), #993 (bot wiring, merged), #921 (clean signal, merged)

## Problem Statement

PR #950 is a large umbrella implementation (+2355/-275 lines, 46 files) for auto-merge (#948) that has become stale. Two prerequisite PRs (#921 clean-signal detection, #993 bot account wiring) merged independently, leaving #950 in a DIRTY/conflicting state. Meanwhile, focused PRs #927 (trigger routing) and #1000 (max review rounds) cover portions of the same scope with smaller, reviewable changesets. A decision is needed on how to proceed.

## Context

### Current State (as of 2026-04-11)

| PR | Issue | State | Lines | Files | Overlap with #950 |
|----|-------|-------|-------|-------|--------------------|
| #950 | #948 | OPEN, DIRTY | +2355/-275 | 46 | Umbrella (conflicts with merged #921, #993) |
| #927 | #915 | OPEN, BLOCKED | +425/-20 | 9 | Trigger routing |
| #1000 | #944 | OPEN | +227/-3 | 5 | Max review rounds |
| — | #945 | OPEN, no PR | — | — | Proxy routing (largely done by #993) |
| — | #998 | OPEN, no PR | — | — | Body-only detection |

### Key Findings

1. **#950 is unmergeable as-is** — conflicts with 2 merged PRs on 8+ files, and uses the wrong bot login (`paid-agent[bot]` vs actual `paid-code-reviewer[bot]`).
2. **Core scanner work is partially done** — clean signal detection (#921) and bot identity registration (#993) are merged.
3. **4 hotspot files** are touched by all three open PRs: `scan_paid_prs_activity.rb`, `git_hub_poll_workflow.rb`, and their specs.
4. **#950 has scope creep** — 37 of its 46 files are unique to it and include unrelated changes (orphan branch reaper, priority tiers, issue sync timestamps, GoodJob config).
5. **#927 and #1000 are focused and conflict-free with each other** — they can be merged sequentially.
6. **Issue #945** (proxy routing) was largely addressed by merged #993.

## Decision

**Option 2: Close #950, merge incrementally.**

Close #950 as superseded. Merge the focused PRs (#927, #1000) and file new PRs for remaining uncovered scope (#998 body-only detection, any prompt changes from #950 not yet addressed).

## Rationale

### Why not Option 1 (rebase #950)?

- Rebasing a 46-file, +2355-line PR with conflicts against 2 merged PRs is high-effort and error-prone.
- The PR contains scope creep (unrelated changes) that would need to be stripped anyway.
- The wrong bot login (`paid-agent[bot]`) indicates the PR predates architectural decisions now locked in.
- Large PRs are harder to review, increasing risk of merging bugs.

### Why not Option 3 (split #950)?

- Splitting requires the same conflict resolution effort as rebasing.
- The focused PRs (#927, #1000) already exist and cover the highest-value portions.
- The remaining unique scope in #950 is mostly scope creep or already merged.

### Why Option 2?

- **Least effort**: #927 and #1000 are already written, reviewed, and conflict-free.
- **Safest**: Small, focused PRs are easier to review and less likely to introduce regressions.
- **No lost work**: The valuable parts of #950 are already covered by existing or planned PRs.
- **Unblocks progress**: #948 can proceed without waiting for a large rebase.

## Implementation Plan

### Immediate Actions

1. Close PR #950 with a comment explaining this decision and linking to this RDR.
2. Merge PR #927 (trigger routing, #915) after CI passes.
3. Merge PR #1000 (max review rounds, #944) after CI passes.

### Follow-up Actions

1. File a PR for issue #998 (body-only review detection).
2. Verify issue #945 (proxy routing) is fully addressed by merged #993; close if so.
3. Audit #950's diff for any valuable changes not covered by the incremental PRs. If found, file targeted PRs.
4. Update issue #948 checklist to reflect the incremental approach.

## Trade-offs

### Positive

- Faster unblocking of #948
- Smaller, reviewable changesets
- No conflict resolution needed for already-merged work
- Aligns with project's preference for incremental delivery

### Negative

- Requires coordination across multiple PRs
- Some prompt/config changes from #950 may need to be manually extracted
- Slightly more overhead in tracking which parts of #948 are done

## Validation

- All incremental PRs pass CI independently
- Issue #948 checklist accurately reflects completion state after each merge
- No regressions in scanner or auto-merge behavior after sequential merges
