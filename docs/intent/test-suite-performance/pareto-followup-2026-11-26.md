# Pareto test follow-up — 2026-11-26

Base: `db3a26f081c248565ca600eac8e8a55b3190f789`. Acceptance environment:
Paid devcontainer, Ruby 3.4.13, PostgreSQL 16.15. No production deployment exists.
LID remains Full, version 1.3.0; TEST-SUITE-017 owns reducing repeated setup
without losing distinct regression checks.

## Changes

- Baseline-statistics examples calculate the same six-run distribution once,
  retaining metric-name/count, mean, deviation, sample-count and p95 checks.
- PR follow-up creation runs once for the normal creation case, retaining
  persistence, goal, status, project, issue, runner, trigger, auto-pick and
  initiating-user checks. Different goals, invalid inputs, runner resolution,
  queueing and duplicate-run cases remain separate.
- Both files reuse the existing stable project context. Automatic audit specs
  share their explicit account/owner/project graph, refinding records and
  rebinding associations per example. The actor is still created before the
  token creator: the generic project factory would reverse their first-owner
  roles, so it is deliberately not substituted here.
- Inbox browser fixtures retain named issue records for expected route IDs,
  avoiding association reads after asynchronous browser requests begin.
  History traversal positively waits for the visible collection before the
  next history action. Existing URL, heading and detail-pane assertions and
  the global five-second default wait remain. Inbox navigation alone uses a
  fifteen-second bound, matching the existing Cuprite transport timeout, for
  asynchronous route/DOM restoration under concurrent load. It adds no sleeps
  or retries and does not change the expected destinations or content.

The three service files retain all **99 original matcher statements byte for
byte**, while examples decrease **48 → 40**. This is a static source comparison,
not proof of equivalent runtime coverage or a measured speedup. Local aggregate
failures retain diagnostics for related checks in the two consolidated examples.
All factory callbacks, validations, tenant enforcement and coverage gates remain.

## Evidence and remaining checks

A parser inspected 30,750 literal examples on frozen integration revision
`a6adb09e159c0f3c4fe6719e43684967034983c5`. No byte-identical example bodies
shared the same AST context and metadata. Comparing repeated action prefixes,
then separating distinct actions inside expectation blocks, identified 188
candidate groups with 315 potentially repeated executions. These are a review
queue, not automatically redundant tests; lazy inputs, assertion side effects
and spec IDs still require inspection.

Further review candidates include `MarkEscalatedActivity` comment/state checks,
`HandleNoOutputIssueRunActivity` completion checks, provider outcome statistics,
and MCP tool-provisioning outcome checks. Each repeats an apparent action, but
its lazy inputs and matcher behavior need inspection before consolidation.
`ProcessRunQueueJob` needs distinct project/account graphs for global scheduling;
`FetchIssuesActivity` mixes database-backed contexts and six `:no_db` examples.
Neither is a safe target for blanket fixture replacement.

That frozen revision's local system run reports 179 examples, two failures and
one existing pending case. One failure builds a route from a nil result of
`project_a.issues.first` after navigation. The other fails a forward-history
heading assertion, with the expected heading present in the later screenshot.
The changes above require focused browser verification; they are not yet proof
that all intermittent failures are eliminated.

Changed-file lint, coherence and static assertion comparison pass. The first
focused run completes 56 examples: all 40 service examples and six filter-dialog
examples pass; two navigation examples fail on asynchronous URL/heading checks.
After the scoped wait adjustment, all ten navigation examples pass with zero
failures or pending cases. Both focused runs use seed 6579 and coverage
instrumentation; the first run remains recorded as a failed attempt. Together
they verify every changed spec file, not the whole suite. Controlled
before/after factory profiles, application coverage comparison, ownership and
isolation probes, and full CI remain required before claiming a performance gain.

The ongoing integration benchmark overlaps the verification needed for this
requested check-in. Its timing is diagnostic, not a controlled speedup result.
A host restart also increased RAM from approximately 21 to 28 GiB and cleared
swap. The 50% whole-suite target remains unproven; use a comparable original-source
control before attributing a final runtime improvement to these changes.

Raw source comparisons, candidate scans, screenshots and results are retained
under `/tmp/paid-testprof-audit/`, including `pareto-assertion-check.json`,
`repeated-action-review.json`, `pareto-followup-focused.{json,log}` and
`integrated-full-retry/`.
