# PgHero repair audit — 2026-11-28

The audit remains in progress. Findings are grouped by the repair that resolves
them; matching titles or tables do not establish overlap.

## Scanner implementation

Commit `4022f5aa558e5c1777abfea4e6a3c0bc6dadba7a` on
`fix/pghero-repair-aware-filing` implements persisted repair ownership, aggregate
resolution, bounded AI assessment, explicit publication readiness, catalog
index evidence and persisted assessment history. Each bounded assessment must
include the oldest or never-assessed finding. Only detailed assessments advance
that history. Failed inference does not create new repair proposals.

Recovery adopts a remote issue after local rollback, including a repair retained
by an earlier publication cap. Coverage added to an existing issue reuses its
repair owner. Coverage markers alone do not transfer lifecycle control over an
external issue to the scanner.

Commit `2b8a464ca1816ca636fc2995d0ab490d334d296b` additionally preserves
each source repair's instructions and rationale when a trusted PR consolidates
existing repairs. The regression failed before the fix; the scanner/job/rake
suite passed 89 examples, and the operating consolidation suite passed 21.

The source and migrations are installed in the operating development workspace.
Unrelated workspace edits were preserved. Development is the only operating
environment; there is no production deployment.

## Coverage review and consolidation

The immutable audit of 148 open PgHero-related PRs found 140 index-removal PRs
with 143 distinct target indexes. No repeated removal target or removal of
another repair's retained coverer was found. The other PRs address seven
constraint validations and the earlier scanner fix. These distinct targets do
not justify consolidation merely to reduce the PR count.

Superseded issues were closed as not planned, with canonical links:

| Superseded issue | Canonical issue | Repair PR |
| --- | --- | --- |
| #5457 | #5454 | #5641 |
| #5572 | #5571 | #5730 |
| #5591 | #5590 | #5746 |
| #5792 | #5791 | #5824 |
| #5814 | #5811 | #5830 |
| #5815 | #5811 | #5830 |
| #5781 | #5780 | #5834 |

The normal scanner imported #5824 and persisted both membership observations
under repair `1118`, canonical issue #5791, before #5792 was closed. No active
Paid source run was present. Its historical issue link remains available.

Their underlying observations remain monitored; those closures do not claim
that the database repairs have been accepted.

Issues #5803 and #5804 have `waiting` and specific evidence requirements.
Zero scans alone do not justify deleting either knowledge-chunk index.
`KnowledgeChunk.full_text_search` uses the existing full-text index's column;
a sequential plan with tenant-policy subplans warrants investigation while
preserving tenant isolation. Only unclaimed queued runs were cancelled.

## Implemented repair handoffs

| Source | Draft PR | Commit | Coverage | Validation |
| --- | --- | --- | --- | --- |
| #5806 | #5812 | `942da7724d1ecb25c0f401acae32c2cc9d38113f` | Two staged-closeout mapping prefix indexes | 20 examples, zero failures |
| #5799 | #5813 | `fd5164049023566de7e9be40844a857ec5e0315a` | Three runner-auth attempt prefix indexes | 43 examples, zero failures |
| #5791 and #5792 | #5824 | `415e0ff6e96c14d7bcad9d78cf40ab8f961df898` | Two membership prefix indexes | 15 examples, zero failures |
| #5811, #5814 and #5815 | #5830 | `0c0b1557df52b21ff9ac3ca0c7174a3882eb7441` | Three exposure indexes | 15 examples, zero failures |
| #5780 and #5781 | #5834 | `0d478a7b27d0d6785bbd7c4f6e2ebc03f22f6168` | Two convention-detection prefix indexes | 13 examples, zero failures |

All five PRs contain substantive concurrent, reversible migrations and `Fixes`
references. Source issues have `waiting`; PRs have `paid-automation`. Tests used
fresh isolated devcontainer databases. None of these repairs has been applied to the
operating database, and live disappearance and workload acceptance remain open.

## Verification and limitations

The scanner's feature-worktree suite passed 88 examples. The focused operating
workspace suite passed 83 examples. Commit lint and secret checks passed.
Coherence completed with five preexisting reverse-reference warnings.

Successful native scans assessed different scopes rather than repeatedly
selecting the same findings. The 04:23 scheduled job assessed 20 findings,
published five catalog-supported repairs under the existing cap, and reopened
no aliases. A later manual invocation through the job failed scope selection,
assessed zero findings and published five previously assessed repairs. It
reopened no aliases and closed nothing. That failed assessment is not evidence
of assessment progress.

The development supervisor recorded a process failure at 04:30. The web and
job services were later restored through `bin/dev --detach`. Normal GoodJob validation run
`b26844a7-cee2-4458-82df-115fd207b401` finished at 04:59:37 UTC without a job
error. Its scan was incomplete: inference timed out, assessed zero findings,
and published five previously assessed repairs. No aliases reopened and nothing
closed. That run did not prove healthy post-restoration assessment.

A tiny application inference probe also timed out. A focused request through
`runner:34` returned an unsuccessful response: the provider reports that the
configured organization cannot use Codex while enrolled in its API Credits
benefit. That specific route requires an eligible credential/organization arrangement.
No billing or credential changes were performed. The full configured route later
completed a normal assessment; this is not a current global inference blocker. Evidence is in
`/tmp/paid-pghero-audit-20261128/inference-blocker.json`. That route failure
did not justify changing scanner prompt limits or claiming successful assessment.

The 04:42 snapshot contains 252 current findings. A per-finding ledger and
immutable PR/catalog evidence are retained locally under
`/tmp/paid-pghero-audit-20261128/`. This is historical accounting, not a claim
that every finding is resolved. Read current GitHub and Paid run state before
acting, especially before touching actively executing work.

Read-only generic plans were obtained for 22 of the snapshot's 25 slow queries.
One query requires consistent normalized parameter identity for `DISTINCT ON`;
two have redacted SQL that cannot be planned. Representative tenant-scoped
bindings, workload replay and before/after measurements remain required.
Estimated plans alone do not prove an effective repair.

Remaining work includes distinct index repairs, individual evidence review,
PR acceptance, and repeated healthy normal scans proving stable ownership and
safe aggregate resolution. No merge, deployment or verified live closeout is
claimed.

Normal job `e6b7544a-97dd-4ba3-946c-936a5c535813` finished at 05:05:54 UTC.
It collected 253 findings and imported the shared membership PR. Inference
timed out: zero findings were assessed, five previously assessed repairs were
published, one issue was updated, and none reopened or closed. This is ownership
import and failure-path evidence, not healthy assessment evidence. The next native scan confirmed that #5792 remained closed.

Normal job `48b15f3f-d585-4ed0-9432-37bc63c5cb54` finished at 05:15:02 UTC
with complete collection, three assessed findings, three published repairs, one
updated issue, no reopens or closures, and no planning error. The newly assessed
work-item account-prefix indexes were absent from the earlier immutable PR
removal inventory. All three exposure findings share repair `1129`, issue #5811
and PR #5830; live metadata checks retained every source instruction and rationale.
Issues #5814 and #5815 were then closed as superseded. The 05:23 native hourly run subsequently confirmed both exposure aliases
remained closed.

The 05:23 hourly job `af07364e-11ec-4447-99bb-1376f66b8a4d` finished at
05:25:07 UTC: 255 findings, one assessed finding, one created repair issue,
no updates, reopens, closures or planning error. The new worktrees prefix-index
issue #5835 is distinct from the earlier PR removal inventory.

Normal job `c3c1a0f3-6abb-4bfe-8d3e-a5b8aebd7320` finished at 05:28:38 UTC:
255 findings, three assessed findings, zero creates/reopens/closures, one issue
update and no planning error. It persisted both convention-detection findings
under repair `1111`, issue #5780, PR #5834. Issue #5781 was then closed as
superseded; its native post-closure check remains pending.

These are three consecutive successful normal scans with different assessed
scopes. The latest assessment deferred one execution-audit INSERT and two
runner-auth INSERT observations with specific missing causal evidence. It did
not claim that the existing runner-auth index-removal PR resolves slow writes
without measurements. Zero creates in that run therefore accompanied genuine
assessment progress.

## Full-text investigation evidence

Issue #5804 now carries a controlled PostgreSQL 16.15 planner experiment. Under
a non-superuser, non-BYPASSRLS role, a 10,000-row synthetic fixture returned ten
rows using a sequential scan with forced row security. The comparison without
row security on that fixture used its GIN index and returned the same ten rows.
All fixture changes rolled back. The runnable
[SQL recipe](experiments/pghero-fts-rls-2026-11-28.sql) was executed and verified;
recorded plans are in
`/tmp/paid-pghero-audit-20261128/fts-rls-recipe-verification.json`.

PostgreSQL documents that policy checks generally precede query conditions,
with exceptions for leakproof functions
([row-security documentation](https://www.postgresql.org/docs/16/ddl-rowsecurity.html)).
The controlled result supports the investigation of the operating full-text
plan's security interaction. It is not representative application workload
acceptance. A repair still needs tenant-scoped bindings, before/after plans and
measurements, and cross-tenant isolation checks. Removing the existing index
remains unjustified; shared coverage of the slow-query finding is not yet proven.

## Scanner publication and refreshed audit

Existing scanner PR #5605 now publishes the repair-aware implementation as a
draft at `d522c63057f2ec63361edfeba33a078926181d52`, with `paid-automation`.
The update fast-forwards its existing branch and retains its earlier commit.
Ported recovery contracts cover closed-owner recovery, oldest-open selection,
persisted-owner preference and later-publication failure after remote success.
The publication worktree and operating workspace each passed 93 focused examples.
Commit lint/security checks passed; coherence completed with existing warnings.
The changed runtime files match the publication source. Unrelated operating
workspace edits remain outside this PR. Full repository CI was not run locally.

Normal job `f0ca2291-3d67-4daf-9344-a98861125d09` finished at 05:50:32 UTC:
255 findings, 11 assessed findings, zero creates, updates, reopens or closures,
and no planning error. All 11 were previously unassessed in the pre-run snapshot.
The convention alias #5781 remained closed. Four consecutive normal scans have
now made assessment progress without planning errors or alias reopening.

The 05:52 immutable-head refresh covers 153 current PgHero PRs. Five older PRs
changed heads, alongside the updated scanner PR and five new repair PRs. Their
migration changes retain the same removal scopes. The current map contains
145 index-removal PRs and 155 distinct targets, with no duplicate target and no
removal of a covering index observed in the catalog snapshot. Active Paid PRs
were only read. Evidence is retained in
`/tmp/paid-pghero-audit-20261128/pr-refresh-0550/`.

The goal remains incomplete. The latest assessment retained specific evidence
deferrals rather than opening overlapping knowledge-search work. Remaining
index repairs, query/workload evidence, PR review and operating acceptance still
need completion; proposed migrations are not verified operating closeout.

## Style-guide and token-usage consolidation

Draft PR #5836 (`088a790457bb1d3bdf468f9d1ebe4b792f1b4f9c`) implements
three redundant style-guide test/version index removals. Its isolated migration
and service checks passed 10 examples. Draft PR #5839
(`657cf8e4eca888b1ccf55053cbc3bf9215b58559`) implements two redundant
token-usage index removals; migration, model and aggregation checks passed
32 examples. Both have `paid-automation`; source issues have `waiting`.
Neither physical repair has been applied to the operating database.

Scheduled job `516d3dbc-c77b-4088-993b-55e100728646` finished at 06:24:28 UTC
on November 28 without a job error. Subsequent database reads verified all
three style-guide memberships under repair 1127 / issue #5809 / PR #5836,
and both token memberships under repair 1136 / issue #5820 / PR #5839.
Every source instruction and rationale remains present in its canonical repair.
There were no active source agent runs at verification. Issues #5810, #5816
and #5821 were closed as superseded at 06:33 UTC; canonical findings remain
open pending operating acceptance. A post-closure normal scan is still required
to verify these aliases remain closed. Terminal job status alone does not prove
the scan's detailed planning or publication results.

Ownership and requirement evidence is retained in
`/tmp/paid-pghero-audit-20261128/style-token-ownership.json`,
`style-token-source-requirements.json`, and
`/tmp/pghero-two-group-requirements-result.log`.

The 06:34 UTC refresh collected every category successfully: 258 current
findings, 192 with repair ownership, 66 unowned, and 178 open scanner-labeled
issues. The refreshed unfinished-work ledger is
`/tmp/paid-pghero-audit-20261128/post-style-token/finding-dispositions.json`.
It records 168 findings with implementation PRs awaiting review and operating
acceptance, 24 owned findings requiring implementation or evidence, and 66
unowned findings requiring assessment or specific query/usage evidence.
These are finding counts, not distinct PR counts or completed repairs.

## Strategy index handoff

Draft PR #5840 at `441e5c33d47464bc2d054eee4e5927fdd2933a0a` covers
issues #5807 and #5808 with concurrent removal of the redundant decision-type and
strategy-id prefixes. It retains compound lookup indexes, version uniqueness,
and single-active-version uniqueness. Both source issues have `waiting`; the
PR has `paid-automation`. Only unclaimed queued runs 32201 and 32202 were
cancelled; preflight found no active source runs or existing covering PR.

In isolated database `paid_test_pghero_strategies`, the empty migration failed
the removal regression. The implemented migration passed 60 examples across
migration, version model, selection service and tenant-policy checks. Lint,
commit hooks and coherence passed (existing coherence warnings remain).
Generated schema changes contain only the version and two index removals.
No additional abstraction was needed in the simplicity review; prose was kept
to the persistence contract. The physical migration was not applied to the
operating database. Full repository CI has not been verified.

Evidence: `/tmp/pghero-strategies-{red,green,migrate,lint,commit}.log`,
`/tmp/pghero-strategy-preflight.log`, and
`/tmp/paid-pghero-audit-20261128/strategy-source-requirements.json`.
Normal scanner import and canonical alias consolidation remain pending.

The 06:23 scheduled scan's native result was recovered from the operating log:
256 findings, one assessed finding, zero creates/reopens/closures, three
updates, 64 deferrals, no planning error and no incomplete category. Evidence:
`/tmp/paid-pghero-audit-20261128/hourly-0623-result.log`. This supports
successful assessment and ownership import; it predates the three alias closes.

The current lexical search implementation already applies chunk project and
active-status filters before full-text search (`Knowledge::Search::Semantic`).
The latest generic plan uses `index_knowledge_chunks_on_project_id_and_status`
and a hashed project-authorization subplan. Adding the same explicit filters
or merely rewriting that EXISTS as IN is not a demonstrated repair. The
full-text GIN/RLS mechanism remains supported by the controlled experiment;
representative tenant-scoped execution evidence is still needed for an
application repair and shared-finding closeout.

Normal job `5f3368ca-63d9-4ffe-bc81-2b1e09288c2b` finished at 06:44:44 UTC.
Its result is incomplete: 258 findings, zero assessed, creates, reopens or
closures, one update, 66 deferred, `AgentHarness::TimeoutError`, and no
incomplete collection categories. It does not extend the successful-assessment
streak. Source alias issues #5810, #5816 and #5821 remained closed after this
run, but successful post-closure assessment remains to be demonstrated.

Independent persisted-state verification confirmed both strategy findings
under repair 1125 / issue #5807 / PR #5840, with all instructions and rationales
retained and no active source runs. Issue #5808 was closed as superseded at
06:45 UTC. Operating acceptance and successful post-closure validation remain
open. Evidence: `strategy-validation-{receipt.json,result.log}` and
`strategy-ownership.json` under `/tmp/paid-pghero-audit-20261128/`.

The next supervisor family (#5817–#5819) passed a read-only preflight: no active
source runs or existing closing PR, and all three redundant prefixes have
retained compound coverers. Only unclaimed queued runs were observed. Worktree
`/tmp/paid-pghero-supervisor-indexes` on `fix/pghero-supervisor-indexes` is
prepared at the base revision; no repair implementation or handoff has yet
been made for that family. Refresh active state before claiming it.

## Supervisor repair and recovered query evidence

Draft PR #5841 at `b9cd2e1c7d03ade260b4394a422f2fcbc645ed6e` implements
concurrent removal of the three supervisor prefixes for issues #5817–#5819.
Retained compound indexes cover audit incident/time, incident account/status,
and snapshot account/retention lookups. Incident fingerprint uniqueness,
append-only audit guards, retention behavior and tenant policies remain intact.
Sources have `waiting`; the PR has `paid-automation`. Only unclaimed queued
runs 32212–32214 were cancelled. A final source check found no active Paid runs.

In isolated database `paid_test_pghero_supervisor`, the empty migration failed
two expected regressions; the implementation passed 25 examples covering the
migration, incident/snapshot models and retention purge service. Concurrent
up/down, staged lint, commit hooks and coherence passed (existing coherence
warnings remain). The generated schema contains only the version and three
index removals. Simplicity and prose review found no extra abstraction needed.
The operating database was not migrated; full repository CI remains unverified.
Logs: `/tmp/pghero-supervisor-{red,green,migrate,lint,commit}.log`.

Normal scanner job `5d4a55a8-5c17-4fbd-af65-2cf0e70fcb6f` was enqueued at
06:50:04 UTC. Its import, assessment result and post-closure checks remain
pending. Receipt and source requirements are retained under
`/tmp/paid-pghero-audit-20261128/`; use `/tmp/pghero-supervisor-job-state.rb`
and `/tmp/pghero-supervisor-ownership.rb` for verification before closing aliases.

For slow-query hash `7683496056364026771`, the source at
`app/jobs/recover_missing_pull_request_labels_job.rb:137–138` confirms matching
`COALESCE` constants (zero and empty string) in DISTINCT ON and ORDER BY.
Replacing only the four mismatched normalized placeholders with those original
literals made the read-only generic EXPLAIN valid. Its estimated Limit cost is
2526.54; no query execution or performance acceptance was performed. The
source-confirmed query, replacements and plan are recorded in
`/tmp/paid-pghero-audit-20261128/recovery-query-source-confirmed-plan.json`.
The 06:34 snapshot ledger now records 26 queries needing workload measurements
and five needing usable SQL; snapshot counts remain historical.

## Successful supervisor import and fair reassessment

Normal job `5d4a55a8-5c17-4fbd-af65-2cf0e70fcb6f` finished at 06:51:43 UTC:
257 findings, six assessed, one update, zero creates/reopens/closures, 65
deferrals, no planning error and no incomplete category. All six assessments
addressed specific slow-write observations. The earlier aliases remained closed: #5808, #5810, #5816 and #5821. All supervisor observations share repair
1133 / issue #5817 / PR #5841, retaining all three source instructions and
rationales. No active source runs were present. Issues #5818 and #5819 were
closed as superseded; their successful post-closure scan remains pending.
Evidence: `supervisor-validation-result.log`, `supervisor-ownership.json` and
`supervisor-run-assessed-findings.json` in the audit artifact directory.

The 06:53 immutable refresh covers 157 open PgHero PRs: 149 index-removal PRs
and 165 distinct removal targets, with no duplicate removal or observed coverer
removal. Evidence: `pr-refresh-0652/heads.json` and `repair-map.json`. Active Paid
work was read only. The eight work-item prefix findings have no active source
runs or existing closing PRs in their preflight; they are not implemented yet.

Review of assessment history exposed starvation under continuously incoming
observations: older deferrals remained behind every never-assessed finding.
Scanner PR #5605 now contains `ff560bd223cdcdb2040d9b787f61f4a577d525df`,
requiring both a never-assessed observation and the oldest previously assessed
pending observation when each exists. Semantic scope and ownership remain AI
judgments; only scheduling and selection validation changed. Two regressions
failed first; 95 examples passed in both publication and operating workspaces.
Lint, commit hooks and coherence passed with existing coherence warnings.
Simplicity review found no additional runtime abstraction needed. An initial
broad run used an absent worktree development database; the corrected isolated
connection run passed. Full repository CI remains unverified.

The validated patch was copied into the operating workspace while preserving
unrelated changes, and into the local audit feature branch (commit 6681d8fea).
Hashes and validation are in `fairness-publication-manifest.json`; prior
assessment state is in `fairness-baseline.json`. Normal job
`4917fdf9-25c3-4e33-94a3-15ab2aea3411` was enqueued at 06:58:14 UTC. Verify
its native result, progress on an older deferral and closed-alias stability
before claiming this revision has passed operating acceptance.

## Execution-index handoff and selector boundary correction

Normal job `4917fdf9-25c3-4e33-94a3-15ab2aea3411` finished at 07:00:36 UTC
with incomplete assessment: 252 findings, zero assessed/creates/reopens/closures,
one update, 60 deferred and `invalid_selection`. It is not successful fairness
acceptance. All six earlier aliases remained closed at subsequent GitHub reads.
Evidence: `fairness-validation-result.log`. A diagnostic preview likewise
rejected selection and committed no repair state or GitHub writes; its structural
checks are in `fairness-selection-diagnostic.json`. Raw responses were not
retained, so those checks do not establish the exact original rejection cause.

A separate failing regression reproduced an ambiguity introduced by the fairness
change: with no never-assessed finding, both required input fields named the
same observation. The scanner now omits the redundant secondary requirement.
PR #5605 publishes `fb918dc58dc60fcea2bbc6993910de575612c094`; the operating
workspace and local feature branch (`cec97b7c1`) contain the correction.
The publication and operating suites each passed 96 examples; lint and hooks
passed. No additional runtime abstraction was needed. Tested hashes and logs
are in `single-frontier-publication-manifest.json`. Operating acceptance remains
pending; this does not prove every source of invalid selection is resolved.

Draft PR #5843 (`63eb2304f01eaf88f9c6591c00b0ef13fdb25f47`) covers
issues #5825–#5828 with four concurrent assignment/continuation-grant prefix removals.
It retains both assignment lookup directions and uniqueness, grant endpoint and
active-state lookup, other indexes, rows, foreign keys and tenant policies.
Sources have `waiting`; the PR has `paid-automation`. Only unclaimed queued runs
32219–32222 were cancelled, and a final source check found no active run.
The empty migration failed two expected regressions; 20 implemented migration,
grant-model and assignment-service examples passed in isolated database
`paid_test_pghero_work_execution`. Concurrent up/down, lint, commit hooks and
coherence passed (existing coherence warnings remain). Generated schema changes
are limited to four index removals and its version. No operating physical
migration or full repository CI was run. Simplicity/prose review found no
additional abstraction needed. Evidence: `/tmp/pghero-work-execution-*.log` and
`work-item-execution-source-requirements.json` in the audit artifact directory.

Normal job `0b9e6e22-d722-4520-90be-91356307ce2e` was enqueued at 07:08:49 UTC
to validate the corrected selector and import PR #5843. Use
`/tmp/pghero-work-execution-job-state.rb` and
`/tmp/pghero-work-execution-ownership.rb`; do not close its source aliases until
persisted ownership and retained requirements are verified. The active Paid run
on #5782 was left untouched; refresh all run states before selecting more work.

## Execution consolidation and selection metadata validation

Normal job `0b9e6e22-d722-4520-90be-91356307ce2e` finished at 07:10:38 UTC
with 252 findings, zero assessed/creates/reopens/closures, one update, 60 deferred,
`invalid_selection` and no incomplete category. The frontier-identity correction
did not resolve this operating rejection. No successful fairness acceptance is
claimed for that revision.

Persisted verification independently confirmed all four execution findings under
repair 1140 / issue #5825 / PR #5843, retaining every source instruction and
rationale and with no active source run. Issues #5826–#5828 were closed as
superseded at 07:13 UTC. Physical repair and operating acceptance remain open
under #5825. Evidence: `work-execution-validation-result.log` and
`work-execution-ownership.json` in the audit artifact directory.

A fresh-process diagnostic preview recorded five response fields where selection
expected exactly three. It contained two known, non-repeated finding IDs, both
required observations, one known work number and a string reason. The extra
fields triggered strict shape rejection before detailed assessment. Evidence:
`single-frontier-selection-diagnostic.json`; preview writes rolled back and no
GitHub write occurred. The correction consumes only the declared selection
fields and ignores extra metadata. Required fields, known selected identities,
output size and scope bounds remain checked; detailed repair validation remains
strict. A regression proves extra selection repair metadata cannot become a
published proposal; unknown identities, missing fields and oversized responses
remain rejected.

PR #5605 now publishes `eb6c0b6f64d3e6d9055f98d7476cf575062f27a5`. The
metadata regression failed first; 98 examples passed in both publication and
operating workspaces. Lint, hooks and coherence passed with existing warnings.
Simplicity review found no additional abstraction needed. The checked patch
preserved unrelated operating edits and is also committed on the local audit
feature branch (`6548bb695`). Hashes and validation are recorded in
`selection-metadata-publication-manifest.json`. Full repository CI remains
unverified.

Normal job `24031b12-18b1-412b-8870-2f3e47be2729` was enqueued at 07:18:22 UTC.
Use `/tmp/pghero-selection-metadata-job-state.rb` and compare persisted assessment
history against `selection-metadata-baseline.json` to prove progress on an older
deferral. Verify closed aliases again after this scan. Do not substitute preview
or failed-selection evidence for normal acceptance.

The remaining work-item account-prefix family (#5829, #5831–#5833) passed a
read-only preflight with no active source run or existing closing PR. Worktree
`/tmp/paid-pghero-work-item-identity-indexes` has only a generated empty migration
`20261128071130`; it has no implementation, tests, source claim or handoff yet.
Refresh active state before proceeding. None of the 19 earlier deferred duplicate
index targets was found in the 06:53 immutable PR removal map; they still need
current catalog assessment and justified implementation rather than assumed
coverage by an existing PR.

## Recovered worker and two successful normal scans

The queued validation job remained unstarted while GoodJob's heartbeat stopped
at 07:17:49 UTC. Database reads showed no running jobs; all queue schedulers
reported occupied threads. Graceful restart failed with a thread-allocation
error while creating its shutdown timer. Only the stalled GoodJob process
(1475075) was forcibly terminated after that failure; Overmind replaced it with
1837378 and a fresh heartbeat. The web and Temporal agent workers remained
running. The same queued job was preserved. The underlying stall cause remains
undiagnosed; this recovery is not a runtime-code fix. Evidence:
`worker-recovery.json` and `/tmp/pghero-worker-*.log`.

Normal job `24031b12-18b1-412b-8870-2f3e47be2729` then started at 07:24:29 UTC
and finished at 07:26:05: 245 findings, two assessed, one update, no
creates/reopens/closures, 53 deferred, no planning error or incomplete category.
It reassessed the cache-rate finding last reviewed at 04:14:57 and assessed a
never-assessed token aggregate. The latter was correctly deferred rather than
attributed to index-removal PR #5839 without causal workload measurements.

Normal job `f236cec1-542e-40ce-898a-183083b9133a` finished at 07:36:14 UTC:
245 findings, two assessed, one create, one update, no reopens/closures,
52 deferred and no planning error or incomplete category. It advanced another
04:14 deferral: assignment index `idx_on_style_guide_ab_test_id_653b807c99`.
New issue #5846 / repair 1149 is expected distinct work: its valid retained
unique `(style_guide_ab_test_id, agent_run_id)` index covers the nonunique prefix,
and that target was absent from the audited PR removals. The other assessment
requested causal measurements for a slow model-selection aggregate instead of
assuming existing agent-run index work resolves it.

Both runs therefore advanced older deferred work alongside never-assessed
observations. GitHub reads after the second run confirmed all 16 earlier
aliases still closed. Evidence: `selection-metadata-assessment-progress.json`,
`work-identity-assessment-progress.json`, both native result logs and
`two-normal-scans-alias-verification.json` in the audit artifact directory.
The scanner publication manifest now records these normal acceptance results;
full repository CI and physical repair acceptance remain unverified.

## Work-item identity handoff and refreshed accounting

Draft PR #5845 at `6278fed7ca250e8245fd0128b4f34ae33b520c56` covers #5829
and #5831–#5833 with four concurrent account-prefix removals. It preserves
all other index definitions, native/provider identity and global/project
lifecycle uniqueness, rows, foreign keys and tenant policies. Sources have
`waiting`; the PR has `paid-automation`. Only unclaimed queued runs 32223–32226
were cancelled; the final source check found no active run. Five migration
checks and existing model checks passed 19 examples in isolated database
`paid_test_pghero_work_identity`. A lookup test was corrected to accept either
valid retained lifecycle compound index. Lint, commit hooks and coherence passed
with existing coherence warnings. Simplicity review found no additional
abstraction needed. The generated schema changes only four indexes and its
version. No physical operating migration was run.

The second normal scan imported all four observations under repair 1144 /
issue #5829 / PR #5845, retaining every source instruction and rationale.
Issues #5831–#5833 were closed as superseded after verification; their next
post-closure scan remains required. Evidence: `work-identity-ownership.json`,
`work-identity-source-requirements.json` and `/tmp/pghero-work-identity-*.log`.

The 07:40 snapshot records 245 findings, 193 owned, 52 unowned, 170 repair
entities and 170 open scanner issues. The refreshed ledger accounts for 181
findings with reviewed implementation PRs awaiting review/operating acceptance,
12 owned findings needing implementation or specific evidence, 18 older catalog
deferrals needing reassessment, 18 queries needing representative measurements,
one cache-rate evidence gap and 15 unused-index usage/catalog reviews. These
are explicit unfinished dispositions, not goal completion. Evidence:
`post-identity/{snapshot,finding-dispositions}.json`.

The 07:43 immutable refresh covers 159 current PRs: 151 index-removal PRs,
173 distinct targets, no duplicate removal and no observed coverer removal.
Active Paid work was read only. The historical shared-coverer audit found the
knowledge-chunk pair already consolidated in PR #5746 and no additional shared
coverer spanning different audited PRs. Evidence: `pr-refresh-0745/` and
`shared-coverer-audit.json`. Issue #5783 is now active in Paid; refresh run state
before selecting further work. New issue #5846 may fit an implemented extension
to the existing style-guide PR, but its current code does not cover that target;
verify active execution and the immutable head before changing that PR.

## Style-guide repair extended without another PR

Issue #5846 is now implemented by an extension to draft PR #5836, commit
`6a969ec0fa8869b5c8d931ff88978d7451216b76`. Its unmerged migration removes
four prefixes, adding assignment index `idx_on_style_guide_ab_test_id_653b807c99`
to the existing variants/tests/versions cleanup. The retained unique test/run
index, agent-run and variant lookup indexes, assignment scores/rows and the
four earlier uniqueness rules remain intact. The extended fixture covers all
five uniqueness rules. The added removal/lookup regressions failed first;
10 migration, winner-promotion and result-recording examples passed. Concurrent
rollback/up succeeded in isolated `paid_test_pghero_style_tests`; the regenerated
incremental schema delta is exactly the assignment index removal. Lint, hooks
and coherence passed with existing coherence warnings. Simplicity review found
no extra abstraction needed. No operating physical migration was run.

Only unclaimed queued run 32252 for #5846 was cancelled after adding `waiting`.
The PR had no active Paid execution, and its head was verified before updating.
It remains draft with `paid-automation` and now includes `Fixes #5846` alongside
its three earlier closing references. Source requirements were captured before
import in `assignment-extension-source-requirements.json`.

Normal job `3718603a-6145-4907-b4d1-697b53e6deaf` finished at 07:57:58 UTC:
244 findings, six assessed, five creates, two updates, no reopens/closures,
46 deferred, no planning error and no incomplete category. It imported all
four style memberships under repair 1127 / issue #5809 / PR #5836, preserving
every source instruction and rationale. Source #5846 was closed as superseded
after verification; its next post-closure normal check remains pending.
Evidence: `assignment-extension-ownership.json`, native result/receipt and
`/tmp/pghero-assignment-extension-*.log`.

The six assessments include five 04:14 catalog deferrals and one never-assessed
slow aggregate. The five created issues (#5848–#5852) are catalog-proven repair
leads for mapping targets, project versions, project account lookup, prompt
versions and provider API key lookup. None of their targets appears among the
173 removals in the latest immutable audit. This is expected newly actionable
work, not proven operating repair. Evidence:
`assignment-extension-assessment-progress.json` and
`assignment-extension-new-repairs.json`. All 19 earlier aliases remained closed
after this third consecutive successful normal scan. The source dependency
cross-check found no current covering-index/removable-index chain;
`coverer-dependency-chains.json` records that historical snapshot result.

Next, inspect #5848 against the existing work-item identity PR #5845. Its current
four-index implementation does not remove the mapping-target index. A tested
extension may absorb that work without another PR; refresh active execution,
immutable head and catalog evidence before changing it. The other new repair
issues also require actual implementation or a specific evidence/decision block.
The goal remains incomplete; no physical repair acceptance or full repository
CI is implied by the scanner's successful assessment progress.

## Mapping-target repair implemented in the existing identity PR

Draft PR #5845 now also implements issue #5848 at
`e6cc4830e07bbcd05cbbd04117e4c6e292f4b84e`. Its existing concurrent migration
removes `index_mapping_targets_on_mapping`, retaining the unique mapping/project
compound index and the independent project lookup index. All five source issues
are declared in closing references. No additional PR was opened.

The mapping-target regression failed against the previous implementation.
The extended migration and work-item/project-mapping/lifecycle model checks passed
in isolated database `paid_test_pghero_work_identity`: 20 examples, zero failures.
Repeated up/down preserves exact other index definitions, rows, partial lifecycle
uniqueness and mapping/project uniqueness. Schema regeneration changes only the
new removal relative to the previous PR head. Lint, hooks and coherence passed
with existing warnings. Simplicity review found no additional abstraction needed.

Issue #5848 carries `waiting`; only its unclaimed queued run 32256 was cancelled.
The active-run guard found no source or PR execution. Original requirements for
all five sources are captured in private
`mapping-target-extension-source-requirements.json`. Normal external GoodJob scan
`739d657e-383d-4538-9b78-78ecd87f0796` started at 08:21:11 UTC. Its completion,
coverage import, requirements retention and alias stability remain to be checked.
Issue #5848 remains open until that verification. Physical operating-database
migration and full repository CI remain unrun.

Normal scan `739d657e-383d-4538-9b78-78ecd87f0796` finished successfully at
08:23:28 UTC: 245 findings, nine assessed, one created, three updated, zero
reopened or closed, 46 deferred, no planning error and no incomplete categories.
All five identity findings now belong to repair 1144 / canonical issue #5829 /
PR #5845. Exact original instructions and rationale for all five were verified
retained. With no active source runs, issue #5848 was closed as superseded at
08:23:57 UTC. Its post-closure scan stability remains pending. All 20 earlier
aliases, including #5846, were fetched closed after this scan.

Assessment made progress through eight older findings and one never-assessed
slow query. One older provider-identity account-prefix finding became repair
1155; its new issue requires a fresh implementation overlap check. The unused
knowledge-audit covering index was explicitly deferred because removing it
would conflict with repair #5589 / PR #5745. Slow INSERT latency and incomplete
query text received specific evidence requirements, rather than unsupported
index-removal coverage claims. Full assessment evidence is in private
`mapping-target-extension-assessment-progress.json`; ownership/requirements are
in `mapping-target-extension-ownership.json`.

## Fresh full accounting and provider trust repair

The 08:24:54 UTC live collection found 244 findings: 199 owned and 45 unowned,
with all collection categories successful. The trusted work snapshot contained
174 open scanner issues. These are historical snapshot counts, not completion.
Private `post-mapping-target/finding-dispositions.json` accounts for all 244:
183 findings have reviewed implementation PRs awaiting review/operating acceptance;
16 owned findings still require implementation or specific evidence; 12 old
catalog deferrals require reassessment; 18 slow queries require investigation or
representative tenant workloads; one cache finding needs workload evidence; and
14 unused indexes require representative usage and catalog review.

The immutable 08:25:59 UTC audit inspected 159 open PgHero PR heads: 151 index
removal PRs and 175 distinct removed indexes. No duplicate target or removal of
an observed covering index was found. Evidence is in private
`pr-refresh-0825/heads.json` and `repair-map.json`. Active Paid work was read only.

Neither provider-trust removal was implemented in that audit. Draft PR #5857
now implements both source issues #5823 and #5854 at
`95e2cc11b427b944ebe1477d70291cef3c401dcc`. One concurrent migration removes
the account-only prefixes from provider identity mappings and trusted identities;
all compound identity, partial account-default, project-scope and independent
lookup indexes remain intact. The common acceptance boundary is the existing
provider trust-admission service, not merely similar table names.

After an initial pending-migration guard stopped test discovery, the isolated
schema was prepared. Empty `up` then failed two real removal/lookup regressions.
The final migration/model/trust-admission suite passed 15 examples, zero failures
in `paid_test_pghero_provider_trust`. PostgreSQL selected a different retained
compound index for one mapping lookup; the test accepts either valid retained
path, while exact definitions and constraints remain independently asserted.
Generated schema changes only the two removals and version. Lint, commit hooks
and coherence passed with existing warnings. Simplicity review found no extra
abstraction. Operating migration and full repository CI remain unrun.

Both sources carry `waiting`; only unclaimed queued run 32218 was cancelled.
No active source run was found. PR #5857 is draft with `paid-automation` and
both closing references. Original requirements are captured in private
`provider-trust-source-requirements.json`. Normal job
`499bd9e5-47f6-4edd-b21c-96b9b7e60f6d` was enqueued at 08:29:42 UTC;
coverage import and post-closure stability verification remain pending.

Provider-trust job `499bd9e5-47f6-4edd-b21c-96b9b7e60f6d` finished at
08:31:39 UTC with successful ownership import but **incomplete assessment**:
245 findings, zero creates, one update, zero reopened/closed, 45 deferred,
zero assessed, all collection categories successful, and
`AgentHarness::TimeoutError`. Job-level error was nil because inference failure
is represented in the scan result; it is not a healthy deduplication run.
Detailed log evidence is private `provider-trust-validation-result.log`.

Both findings now belong to repair 1139 / canonical issue #5823 / PR #5857,
with exact original instructions and rationale verified retained and no active
source runs. Issue #5854 was closed as superseded at 08:32:40 UTC. Physical
acceptance remains pending under #5823. Issue #5848 was fetched closed after
this scan; #5854 post-closure stability remains pending. A normal retry is
appropriate after the terminal timeout; preserve this failed-assessment evidence.

## Convention repair extended and repeated assessment timeout investigated

The provider-trust retry `9413e793-8594-4325-95ba-95a0f816dae9` finished at
08:36:21 UTC with another incomplete assessment: 245 findings, zero creates,
one update, zero reopens/closures, 45 deferred, zero assessed, successful
collection categories and `AgentHarness::TimeoutError`. This is not successful
assessment progress. Private `provider-trust-retry-validation-result.log` records
both the deferred-assessment and incomplete-scan events.

Job-correlated logs show three managed Codex credential-1 lease timeouts,
including a 71.8-second execution wait, followed by deferred harvest/cleanup and
the isolated request timeout. No detailed assessment-start event occurred.
The standalone executor bounds lease waiting by the request deadline, so this
explains time consumed before inference. A later `lsof` observation found the
Temporal worker's open lock descriptor, while `lslocks` did not show that auth
lease currently locked. Do not infer a permanently stuck lock or bypass credential
coordination; active Paid work was not interrupted and runtime code was unchanged.

Draft PR #5834 was substantively extended at
`80116d9e8f6b49d1cbb4c03600173d932c94f252` to cover sources #5782 and #5783
in addition to #5780/#5781. Its existing concurrent migration now removes
four convention detection/override/recommendation prefixes. Compound lookup,
detector and override uniqueness and pending-only recommendation uniqueness
remain intact. The new removal regression failed against the prior implementation.
The final migration and three model suites passed **48 examples, zero failures**
in isolated `paid_test_pghero_conventions`; concurrent redo and generated schema
show only two incremental removals. Lint, hooks and coherence passed with existing
warnings. Simplicity/prose review found no extra abstraction. No operating
migration or full repository CI was run.

Both new sources carry `waiting`; no active source/PR run or queued run requiring
cancellation was found. Three original repair records covering four historical
findings are captured in `convention-extension-source-requirements.json`.
PR #5834 remains draft with closing references and `paid-automation`. Normal
external job `d0104deb-bd43-48e2-b8ae-31e6334a99fe` was enqueued at 08:38:35 UTC;
coverage import, requirements retention, alias closure and scan health remain to
be verified before declaring consolidation complete.

The convention scan completed successfully at 08:40:42 UTC: 245 findings,
four assessed, one created, one updated, zero reopened/closed, 44 deferred,
no planning error and no incomplete categories. It assessed three older findings
and one new slow query. An old quality-gate project-prefix finding became repair
1157; its new issue needs an implementation overlap check. Knowledge-artifact
unused indexes remained deferred with specific evidence requirements, including
an explicit conflict with retaining a covering index in an existing repair.
Evidence: private `convention-extension-validation-result.log` and
`convention-extension-assessment-progress.json`.

All four convention findings now belong to repair 1111 / canonical #5780 /
PR #5834, with exact original instructions and rationale verified retained and
no active source runs. Source issues #5782 and #5783 were closed as superseded;
physical and representative-workload acceptance remains pending under #5780.
All 22 earlier aliases were fetched closed after this successful scan, including
issues #5848 and #5854. Post-closure stability for the two newest aliases remains pending.

Metadata-only cache evidence sampled all 245 user tables at 08:40:03 and
08:40:22 UTC. Shared buffers are 128MB. The 19-second interval recorded 388 heap
reads and 33,966 heap hits (98.87%). Issues accounted for 312 interval reads;
historical leaders such as style-guide exposures had no additional heap reads.
This short uncontrolled interval does not establish a representative workload,
disk I/O latency, or a cache repair. PostgreSQL block reads can be served by the
OS cache. The concrete remaining evidence is a representative interval with
query attribution and latency/I/O measurements, before proposing configuration
or query/index changes. Statistics were not reset and settings were not changed.
Private `cache-workload-{start,end,interval}.json` preserves the measurements.

## Audit correction: Paid tracking PRs and preserved safety requirements

The earlier “no duplicate removals” result covered a filtered PR set, not all
current PgHero PRs. Paid's newer PRs use non-closing `Tracks #...` references,
which that audit predicate omitted. Do not use that earlier result as full
backlog completeness evidence. The scanner's trusted work inventory already
contained these PRs; the omission was in the audit's candidate filter.

A fresh 08:42:35 UTC collection found 245 findings, 201 owned and 44 unowned,
173 open scanner issues and all categories collected. The expanded immutable
audit includes historical members, closing/finding references, explicit tracking
references and PgHero title candidates, then reads actual diffs. Its 164-PR
membership was captured before the subsequent duplicate PR closures. At the
08:45:24 UTC head snapshot it contained 156 removal PRs, 181 distinct targets,
and two duplicate targets: recommendations in #5847/#5834 and overrides in
PRs #5844/#5834. No observed covering index was targeted for removal. This is a
snapshot, not a claim that every listed PR remains open. Evidence and the
constant-aware removal parser are in private `pr-refresh-complete-0845/` and
`/tmp/pghero-refresh-repair-map-complete.py`. Static constant names are resolved
without executing remote code; unparsed removals fail the audit.

Immutable PR #5847 at `976f4acc87303132e1fd15c2094e79efb2607a0c` implements only
the recommendation removal already in #5834. Its acceptance requirements are
covered there; it was closed as superseded at 08:45:20 UTC after checking its
comments/reviews and the active-run guard.

Immutable PR #5844 at `70920a57b060ccac33f72843cc3763f3c7118950` adds the same
override removal plus a covering-index guard. That guard was preserved before
closing the PR: canonical #5834 now requires the exact valid, non-partial unique
project/key coverer before any DDL when the redundant override index exists.
Missing/nonunique guard regressions failed before implementation. The final
suite passed **52 examples, zero failures** in isolated
`paid_test_pghero_conventions`, including partial coverers and a genuinely invalid
index left by a failed concurrent unique build. Lint, hooks and coherence passed.
No schema changes beyond the prior two removals were needed. Simplicity review
retained only the guard needed to preserve the source PR's safety requirement.
Published and remotely verified head:
`76186e62f92a1b224a1da422778be81818e5cc12`. PR #5844 was closed as superseded at
08:48:40 UTC. Operating migration and full repository CI remain unrun.

Existing Paid draft PRs #5853 (`4ddd972ee740fb4c3f64d59643cf42d940f0c1b3`) and
PR #5856 (`5d947c8856a34e8004f50473d92bf158f4c3534c`) already implement the delegation
checkpoint and settlement removals for #5784/#5789. Actual diffs were read;
reported tests/acceptance were not independently executed. No additional
implementation PR was created. The unused generated empty migration was removed
from the clean preparation worktree `/tmp/paid-pghero-delegation-indexes`; its
new isolated test database remains empty. Preserve the existing implementations
and append-only/lookup acceptance when considering their consolidation.
`Tracks` is discovery context, not automatic full coverage or a closing reference.

The corrected private `post-conventions/finding-dispositions.json` accounts for
all 245 findings: 187 reviewed implementations awaiting review/acceptance; two
Paid implementations requiring independent validation/acceptance; 12 owned
findings needing implementation or specific evidence; ten old catalog deferrals;
19 query investigations/workload evidence gaps; one cache evidence gap; and 14
unused-index usage/catalog reviews. It explicitly discovers tracked candidate
PRs, excludes the two verified closed duplicates, and annotates the independently
unexecuted implementations. These dispositions do not prove goal completion.

Normal follow-up job `22069afb-e1fb-4059-9c59-d52b89115ba7` completed successfully
at 08:51:20 UTC: 245 findings, seven assessed, two created, zero updates,
reopens or closures, 40 deferred, no planning error and all categories collected.
It advanced four older duplicate-index observations into two shared repair
entities: quality-metric agent-run/prompt-version prefixes (1158) and quality
pause/recovery project prefixes (1159). Three incomplete slow queries were
specifically deferred; shared table names were not accepted as causal repair
coverage. New repairs still require immutable implementation overlap checks.
Evidence: private `convention-guard-validation-result.log`,
`convention-guard-assessment-progress.json`, `convention-guard-new-repairs.json`.

The convention canonical remains repair 1111 / #5780 / PR #5834, with all four
findings and original source instructions/rationale retained. All 24 closed
issue aliases were fetched closed after this successful follow-up, including
both latest convention aliases. Private `convention-guard-alias-verification.json`
records each result. PRs #5844/#5847 are closed; the two delegation PRs remain
open and unmodified. No new delegation PR or operating schema change was made.

## Slow-query evidence truncation repaired in the operating workspace

Repeated native assessments could not establish query scope because the
collector truncated sanitized SQL at 1,000 characters. Scanner revision
`74b96fc09dfbf263f8ce50d35cf878e67248670b`, published in existing draft PR #5605,
retains slow-query SQL with literals redacted up to 16,000 bytes and records
`query_truncated`. This is evidence completeness, not permission to infer a
repair from incomplete SQL. Finding identity remains the query hash. Other query
categories keep their previous bounds and identities; assessment input and
publication limits remain unchanged. No provider-specific parser was added.

Failing-first tests detected the missing predicate/order tail and truncation
metadata. Diff review caught an unintended long-running-query change before
publication; a regression failed for its changed excerpt-derived identity, then
passed after its old bound was restored. The final focused suite passed 101
examples, zero failures in the operating devcontainer using isolated database
`paid_test_pghero_repair_filing`. Publication-worktree tests also passed. Lint,
commit hooks and coherence passed with existing warnings. Simplicity review
retained one bounded collector change and reused the literal-redaction boundary.

The checked patch was applied locally and mirrored into the original feature
worktree. Baseline hash checks protected unrelated operating edits; LID updates
were incremental and preserved unrelated intent sections. Matching collector,
spec, planner and filer source hashes are recorded in private
`query-evidence-publication-manifest.json`. Full repository CI remains unverified.
No physical operating migration was applied.

A read-only 08:58:34 UTC collection found 22 slow queries, four with evidence
longer than the old excerpt, none truncated at the new limit, and all categories
collected. Private `query-evidence-collector-probe.json` records identities,
byte lengths and truncation flags without query text. Normal external GoodJob
job `e1b48362-714a-4e51-92b5-af8754c3798f` was enqueued at 09:00:07 UTC;
its assessment result, persisted evidence and alias stability remain pending.

Normal job `e1b48362-714a-4e51-92b5-af8754c3798f` finished at 09:02:44 UTC with
incomplete inference: 249 findings, zero creates, one update, zero reopens or
closures, 44 deferred, zero assessed, all categories collected and
`AgentHarness::TimeoutError`. No detailed assessment-start event was recorded.
This is not healthy assessment evidence. A separate 09:03:31 UTC persisted-state
read verifies the normal worker did use the new collector: all 23 active slow
query rows have explicit truncation flags and fit the 16,000-byte bound; five
retain more than the former excerpt. Private `query-evidence-persisted.json`
records lengths and identities without query text. The three queries previously
deferred for truncated scope now retain 3,014, 4,054 and 4,073 sanitized bytes
under their original identities. Readiness and causal workload proof remain
separate requirements. Preserve the timeout evidence and retry only after the
terminal job, through the normal unfinished-job guard.

Normal retry `694b52d3-9a89-42fb-bf8b-988015b28c3f` was enqueued at 09:04:00 UTC
after the prior job was confirmed terminal. Its receipt is private
`query-evidence-retry-validation-receipt.json`; assessment success and post-change
alias stability still require verification.

Retry `694b52d3-9a89-42fb-bf8b-988015b28c3f` finished at 09:05:52 UTC with another
incomplete assessment: 248 findings, zero creates/updates/reopens/closures,
43 deferred, zero assessed, all categories collected and
`AgentHarness::TimeoutError`. Again no detailed assessment began. Correlated
logs show managed Codex credential-1 lease waits of 72.16 seconds, 4.96 seconds
and zero remaining time. This supports an execution-capacity/lease-wait
investigation; it does not establish a permanent lock or justify interrupting
active Paid runs. No further blind retry was queued. The collector's persisted
evidence is verified, but successful assessment on revision 74b96fc remains
unverified. Private `query-evidence-retry-validation-result.log` preserves the
failure. Continue independent repair work and investigate bounded routing/lease
budgets through the existing Llm::Request and harness interfaces rather than
loosening evidence checks or adding provider-specific wrappers.

## Routing capacity verified and quality-event repair implemented

Configured routing metadata lists six candidates, which does not establish
that each can actually execute. A separate 30-second Llm::Request capacity
probe, run in tenant context from 09:09:46 to 09:10:12 UTC, returned the expected
response. Attempt metadata shows Claude skipped for a missing managed credential,
API Codex returning an unsuccessful response after 11.46 seconds, then subscription
Codex succeeding after 14.44 seconds with a 19-second allocation. No routing
configuration or provider-specific execution code was changed. This small probe
is not normal scanner acceptance; private `routing-probe-private.json` records
only trace metadata and a response boolean.

After that new availability evidence, normal job
`6e273e90-e88e-4cc8-91b9-e7c02d1f36be` completed successfully at 09:12:32 UTC on
scanner code revision 74b96fc: 249 findings, eight assessed, one created, zero
updates/reopens/closures, 43 deferred, no planning error and all categories
collected. It advanced six older findings and two new observations. All 24
closed aliases were fetched closed after this run. Evidence is private
`query-evidence-recovered-{validation-result.log,assessment-progress.json,alias-verification.json}`.
This is the first verified successful normal assessment on the richer-query
revision; the two earlier timeouts remain failed assessment evidence.

Seven project UPDATE observations received specific causal-evidence requirements,
not an inferred missing-index repair. A read-only 09:15:55 UTC catalog/activity
snapshot confirms a valid unique primary `projects(id)` index and no current
lock waits or transactions over 30 seconds. The absence of waits in one snapshot
does not disprove historical contention. Representative bindings, wait/trigger
or write-overhead measurements remain needed before choosing a repair.
Private `write-contention-snapshot.json` contains sanitized SQL and catalog
metadata; no operating UPDATE or EXPLAIN ANALYZE was executed.

Sources #5858 and #5861 had no active Paid runs or related open PRs at the fresh
preflight. One implemented quality-event migration now removes three project
prefixes while retaining compound gate filtering and pause/recovery history
paths. Draft PR #5864 at `1422fdc76d92b89a87cc8b2d1ffc7813862fc739` includes
both closing references and `paid-automation`. Both sources carry `waiting`;
only their unclaimed queued runs 32263 and 32264 were cancelled. Original
instructions/rationale are private `quality-events-source-requirements.json`.
The independent metric uniqueness/lookup repair #5860 remains separate.

An empty-migration removal regression failed as expected. The final migration
and gate/pause/recovery model suite passed 35 examples, zero failures in isolated
`paid_test_pghero_quality_events`. Concurrent redo regenerated schema with only
three removals and version. Exact retained index definitions/validity, event
metadata/recovery results, rows, repeated rollback and usable lookup paths were
checked. Lint, hooks and coherence passed with existing warnings. Simplicity
review found no additional abstraction needed. Full repository CI, representative
workload performance and operating migration remain unrun. Ownership import,
requirements retention and alias consolidation still need normal-scan verification.

Quality-event normal job `3e9675b3-912c-4ccb-997e-80ba529efa30` finished at
09:20:28 UTC: 248 findings, zero creates, three updates, zero reopens/closures,
42 deferred, zero assessed, all categories collected and
`AgentHarness::TimeoutError`. This is incomplete inference, not another healthy
assessment. Its independent explicit-coverage import succeeded: all three
findings belong to repair 1157 / canonical issue #5858 / PR #5864. Both source
instructions and rationale were verified retained, with no active source or PR
run. Alias #5861 was closed as superseded; physical/representative-workload
acceptance remains pending under #5858. Post-closure stability of that newest
alias still needs a later normal scan. The independent #5860 repair remains
unimplemented. Private `quality-events-ownership.json` and
`quality-events-validation-result.log` preserve ownership and timeout evidence.
No further blind retry was queued.

## Quality-metric handoff and scanner lock correction

The later all-open-PR audit at 09:33:53 UTC inspected 190 trusted open PRs,
including work without PgHero titles or closing references. Complete immutable
base/head comparisons found 158 PRs with index removals, 187 distinct targets,
no repeated removal targets and no observed covering-index removals. This is an
explicit index-removal audit, not a semantic review of every unrelated change;
it predates PR #5866. Private `pr-all-0930/` preserves the evidence.

Draft PR #5866 at `ac4916b1ac3bfb0d1ef61e96e7096b09f81ddf1a` implements
source #5860 with two redundant quality_metrics index removals. It preserves the
unique agent-run/metric-type index, the full prompt-version/time index and the
partial scored-row history index. The full index remains necessary for unscored
rows. Source waiting and PR paid-automation are set; only unclaimed queued run
32265 was cancelled. In isolated `paid_test_pghero_quality_metrics`, the red
regression failed and migration/model/trend/sample validation passed 71 examples;
final migration validation passed four examples. Lint, hooks and coherence
passed. No operating physical migration or full repository CI was run.

Normal job `82ee435b-3361-41e0-b910-57085f3dd9a9` finished at 09:38:37 UTC:
248 findings, six assessed, one created, no updates/reopens/closures, 41 deferred,
all categories collected and no planning error. Both metric members remain
repair 1158 / issue #5860 / PR #5866 with source instructions and rationale
retained. Private `quality-metrics-*` artifacts preserve the evidence. Earlier
actual cron job `1ff8b514-f7e5-48bf-9910-2e768308ea2e` ended in an inference
timeout with zero assessed; all 25 closed aliases were fetched closed afterward.
That timeout is not successful assessment evidence.

A real two-connection regression demonstrated that the scanner's FOR UPDATE
project lock blocks ordinary project updates while collection waits. Scanner
revision `2796c2b2c` replaces it with a project-specific transaction-scoped
advisory lock, retaining dirty-record rejection, preview rollback and same-project
serialization. Different projects and non-key updates can proceed independently.
The five concurrency examples and full focused scanner suite passed 105 examples,
zero failures in both publication and operating workspaces. Lint and commit hooks
passed; coherence completed with existing unrelated warnings. Simplicity review
found no additional abstraction needed. The original worktree commit is
`c0992aa22`; all intended changes are also applied locally. No PgHero job was
unfinished at rollout. This establishes a causal contention defect, not proof
that every historical slow UPDATE has been repaired.

Normal external job `04bcd0bb-0a31-48f5-9003-cac34586fd94` began at
09:58:48 UTC. At 09:59:04 UTC, a separate tenant-scoped transaction acquired
FOR NO KEY UPDATE NOWAIT on project 19 while the scanner advisory lock was
granted, then rolled back without data changes. Private
`scan-lock-operating-observation.json` records this operating contention proof.
The scan reported 248 findings, zero creates, three updates, zero reopens/closures,
41 deferred and zero assessed, with all categories collected and an inference
timeout after 122,367 ms. This is failed assessment evidence despite successful
collection and lock behavior. `scan-lock-validation-{manifest.json,result.log}`
records source hashes and results. The live 10:00:22 UTC snapshot has 248 findings,
207 owned, 41 unowned and 176 open scanner issues, with three active Paid runs.
Physical repair acceptance and complete current finding accounting remain
outstanding; no blind retry was queued.

## Requirements retained when assessment expands an existing repair

Revision `907314f27` corrects a second preservation gap: assessment could attach
new findings to an existing repair while dropping the assessment's instructions
and rationale. Existing requirements and newly assessed exact paragraphs now
remain together, once and in order, without changing canonical ownership or
rewriting the repair title. No semantic grouping is performed by this text merge.
Externally managed work retains its existing no-rewrite lifecycle contract.

The new regression first failed because the added unscored-row requirement was
absent. The focused scanner suite passed 106 examples, zero failures; final
issue-filer validation in the operating workspace passed 25 examples, zero
failures. Both used isolated `paid_test_pghero_repair_filing`, not operating
finding data. Lint, commit hooks and coherence completed; existing unrelated
coherence warnings remain. Simplicity/prose review retained the direct paragraph
union with no new helper or dependency. Original worktree commit `34defb865` and
operating files contain the same change. No physical migration was needed.
Normal external assessment on this revision remains unverified; the preceding
inference timeout is not evidence for this fix.

The refreshed snapshot has four unowned duplicate-index observations: two
runner_credentials prefixes, service_container_metrics' container prefix and
service_containers' account prefix. The former auth-materialization observation
now belongs to repair 1161 / issue #5867. Before implementing any of these,
refresh all open PRs and active runs, inspect catalog and callers, and compare
concrete repair coverage. No issue was closed merely from this classification.

## Current accounting and run-resource ledger repair

The 10:05:32 UTC snapshot still contains 248 findings, 207 owned and 41 unowned,
with three active Paid runs. An all-open-PR comparison completed at 10:07:25 UTC:
191 trusted PRs, 159 with explicit index removals, 189 distinct removal targets,
no repeated removal targets and no observed covering-index removals. Private
`pr-all-run-resource/` preserves complete immutable comparison evidence. Active
PRs were read only. The subsequent PR #5869 is not included in that audit.

`pre-run-resource/finding-dispositions.json` accounts for all 248 findings:
189 match a named index removal in an open PR; eight have PR claims requiring
causal implementation review; 12 catalog redundancies require implementation;
22 queries need causal evidence; 16 unused-index observations need representative
usage and dependency evidence; one cache observation needs representative workload
evidence. These are explicit unfinished dispositions, not verified closeout.
Closing or Tracks references alone do not establish causal coverage. Before
mutations, refresh active runs and PR heads again.

Sources #5855 and #5867 now share draft PR #5869 at
`065a00451bd028acd1d79507c360dbf1c2aa49c9`, with both closing references and
paid-automation. Both sources carry waiting; only unclaimed queued runs 32262 and
32269 were cancelled. Original source instructions and rationale are retained in
private `run-resource-source-requirements.json`. The migration removes two
nonunique agent-run prefixes, retaining full unique provisioning run/kind/attempt
identity and runner-auth run/runner/container provenance, plus all other indexes.
The partial provisioning request-ID index is not used as the sole coverer.

In new isolated `paid_test_pghero_run_resources`, confirmed empty before schema
loading, the removal regression failed against the empty migration (four examples,
one failure). Concurrent upgrade/rollback/upgrade succeeded. Final migration,
ProvisioningIntent, LocalDockerRunner and managed-auth/login-flow checks passed
236 examples, zero failures. Checks cover retained index definitions/validity,
unchanged ledger rows and credential-generation provenance, uniqueness and usable
run-prefix/full-identity paths including intents without request IDs. Schema
is Rails-generated with exactly two removals and version change; a later dump's
unrelated trigger-order churn was discarded in favor of that generated snapshot.
Lint, hooks and coherence completed, with existing unrelated coherence warnings.
Simplicity/prose review found no additional abstraction necessary.

Physical migration, representative workload measurements and full repository CI
remain unrun in the operating environment. Normal job
`47290059-6bd7-4a98-a075-ecce577adef6` ran from 10:13:50 to 10:15:35 UTC on
scanner code `907314f27`: 248 findings, three assessed, two created, two updated,
zero reopens/closures, 39 deferred, no planning error and all categories collected.
It reassessed two older 04:14:58 UTC deferrals and one never-assessed aggregate
query. The two new issues #5870/#5871 cover different runner_credentials prefixes
and retain different covering indexes; no existing removal target overlapped.
The aggregate query received specific plan/schema/representative-evidence needs.
This is successful normal assessment evidence, not merely a zero-create count.

Both run-resource members now share repair 1156 / canonical #5855 / PR #5869,
with both sources' instructions and rationale verified retained. No source or PR
run was active at the closeout guard. Alias #5867 was closed as superseded;
physical acceptance remains under #5855. All 25 prior aliases were fetched closed
after this successful scan. Private `run-resource-{ownership.json,assessment-progress.json,alias-verification.json,validation-result.log}`
and `run-resource-validation-manifest.json` record exact evidence. The refreshed
10:17:37 UTC snapshot has 248 findings, 209 owned, 39 unowned and 177 open scanner
issues. Follow-up normal job `58d58073-b120-4a26-9232-ec3860b860a0` began
at 10:17:59 UTC and reported 249 findings, zero creates/updates/reopens/closures,
40 deferred, zero assessed, all categories collected and an inference timeout
after 137,017 ms. All 26 aliases, including #5867, were fetched closed afterward.
This is failure-path alias stability, not another successful assessment. Private
`post-run-resource-alias-{validation-result.log,verification.json}` records both
outcomes. No further blind retry was queued.

## Constraint repair review and new Paid PR acceptance gap

Current immutable migrations in PRs #5617, #5618, #5619, #5620, #5621 and
PR #5622 validate six different foreign keys; PR #5624 validates the delegation
posture level check. Read-only catalog evidence at 10:15:47 UTC matches each
foreign key's exact child column and parent table and confirms all seven remain
NOT VALID. Bounded read-only orphan-existence probes found no current orphan for
any of the six foreign keys. No constraint validation or application write was
executed. These distinct constraints are not proven duplicate work; independent
migration tests, check-constraint row validation and operating migration acceptance
remain required. Private `constraint-repair-current-evidence.json` preserves
catalog definitions and probe results without row identifiers.

A grouping pass over current duplicate-index evidence found no remaining cases
where different PRs remove prefixes covered by the same retained index. This
narrow result does not prove every broader query repair is distinct.

New Paid PR #5868, head `fb5efcca55cc30b7aed31bd196e601426a5a73ca`, implements
source #5852's provider-key prefix removal and was read from a complete immutable
comparison. It retains the unique user/name coverer, but its permanent spec mocks
all DDL with no database; the reported catalog evidence is run-local and not
independently verified. Its POSTGRESQL-PERSISTENCE-014 also collides with existing
constraint PR #5617's different claim. Independent real-DDL/lookup/uniqueness
coverage and a distinct intent ID are concrete remaining review work. No duplicate
replacement PR was created and no untrusted PR code was executed. Private
`provider-key-pr-current-diff.json` records all five changed files and exact refs.

## Existing provider-key PR acceptance strengthened

PR #5868 is updated in place at `9eea85f0e495e998299c630f266639ed69cbc3e4`;
no replacement PR was opened. Source #5852 carries waiting, the draft PR carries
paid-automation and now includes Fixes #5852. A fresh guard found no active source
or PR run before publication. All five original changed files were reviewed;
the application/runtime matches the trusted base, and the mock-only spec was
replaced before test execution. The reviewed concurrent migration's operations
are unchanged. Its intent claim is now POSTGRESQL-PERSISTENCE-030, removing the
collision with constraint PR #5617.

New isolated `paid_test_pghero_provider_keys` was verified empty before loading
the trusted base schema. Actual upgrade/rollback/upgrade succeeded. Migration and
ProviderApiKey model validation passed 26 examples, zero failures. A temporary
negative control omitting index removal produced one expected failure; a finally
block restored the exact reviewed source, then all four migration examples passed.
Checks exercise PostgreSQL index definitions/validity, unchanged credential rows,
per-user name uniqueness, rollback/reapplication and ordered user-prefix/full
identity lookup usability. Lint/hooks and coherence completed, with existing
unrelated coherence warnings. Simplicity/prose review retained direct fixtures
and a specific provider-key contract instead of a generic prefix-removal rule.
Private `provider-key-validation-manifest.json` records hashes and actual results.

No operating physical migration, representative workload measurement or full
repository CI was run. Normal job `0dcbedde-302d-431c-ba9e-5212aa1d8c6e` was
enqueued at 10:28:53 UTC to verify import of the new explicit closing reference;
its terminal outcome remains pending. Canonical issue #5852 remains open.

Actual hourly cron `36ac432f-76f2-4a9d-8376-2d85350467d6` ran from 10:24:05
to 10:26:18 UTC on scanner code 907314f27: 248 findings, zero issue changes,
39 deferred, zero assessed, all categories collected and an inference timeout
after 126,650 ms. All 26 aliases were fetched closed after terminal completion.
This is scheduled failure-path stability, not successful assessment progress.
Private `scheduled-1023-{receipt.json,validation-result.log,alias-verification.json}`
preserves the evidence. The separate handoff job above has a changed publication
reference to verify; it is not a blind inference retry.

## Alternate coverers need repair-level review

The selected-coverer grouping pass above was narrow. Read-only catalog evidence
at 10:29:13 UTC confirms the full valid unique runner_credentials index on
(account_id, runner_key, name) supports both account_id and account_id/runner_key
prefixes. PgHero selected account_id/revoked_at as the coverer for the first
finding and the unique index for the second. Therefore different selected coverer
names do not establish separate repairs: both removals can be assessed as one
credential-index cleanup while retaining the revoked-at path and uniqueness.
Private `credential-coverer-evidence.json` records all six actual definitions.

This establishes a consolidation candidate, not implemented or workload-verified
coverage. Source #5871 has active Paid run 32272 and is untouched. Refresh that
run and its resulting PR before consolidation. Assess whether scanner evidence
should expose alternate covering indexes so bounded AI assessment can evaluate
shared repairs without relying on PgHero's chosen pair or table-name grouping.

## Alternate index evidence implemented and applied locally

Scanner revision `e463769ba9be134604ae21c1b7470737896fb7f4` supplies all indexes
from the already-collected same-schema/table catalog with complete definitions,
validity and uniqueness. Entries are sorted by name; partial and invalid entries
remain evidence, not approved coverers. PgHero's selected pair remains intact.
The assessment prompt asks AI to inspect alternatives and shared repair scope,
checking actual predicates, keys, validity and uniqueness. Collection makes no
semantic eligibility or repair-grouping decision. No additional catalog query,
provider wrapper or new abstraction was introduced. Input budgets, trust gates,
publication readiness and ownership/lifecycle validation remain unchanged.

The missing-evidence regression first failed (two examples, one failure). Final
focused scanner validation passed 109 examples in both publication and operating
workspaces using isolated `paid_test_pghero_repair_filing`; lint/hooks and coherence
completed, with existing unrelated coherence warnings. Tests cover same-schema/
table isolation, preservation of partial and invalid alternatives, unchanged
chosen-pair evidence and stable fingerprints under reordered catalog context,
plus full context reaching Llm::Request and acceptance of a shared proposal.
These mocked inference checks do not prove improved semantic grouping quality.
Original implementation commit is `d929d3b19d5ef691e3a772a346b8cb1ec266fcb8`;
checked patches were also applied to the operating workspace without overwriting
unrelated intent changes. No PgHero job was unfinished during rollout.

Two read-only operating collections at 10:36:12 UTC found 201 duplicate-index
observations, all with nonempty table-index context. Maximum context was 9,396
bytes and maximum finding detail 10,303 bytes; all duplicate fingerprints matched
across both collections. All collection categories were available. In-memory
rendering with current observations and historical issue prefixes produced a
maximum 22,410-byte managed body; no DB or GitHub writes occurred. This measures
actual payloads, not publication or successful AI consolidation. Private
`alternate-coverers-operating-probe.json` and `alternate-coverers-body-probe.json`
retain the measurements and credential example. A first filing run can refresh existing evidence bodies and fingerprints;
that alone is not unexpected new issue creation.

Normal external job `72b9c0cf-0266-4857-b578-880397fc4445`, enqueued at
10:37:27 UTC, ran from 10:48:00 to 10:50:15 UTC after worker recovery below.
On scanner code e463769ba it reported 248 findings, five assessed, one created,
29 evidence updates, zero reopens/closures, 38 deferred, no planning error and
all categories collected. The detailed scope contained five findings and two work
items in 28,006 bytes. It reassessed an older query and a 04:14:58 UTC index
deferral and advanced three never-assessed project queries. It published #5873
for the catalog-proven service-container metric prefix removal, whose target
is absent from the complete existing PR removal map. Four project queries were
reasonedly deferred; neither shared tables nor a possibly related dashboard issue
were treated as sufficient causal coverage. This is successful assessment, not
proof of general semantic grouping quality or completed physical acceptance.

All 201 active duplicate findings persisted their table-index context, and all
26 aliases were fetched closed after terminal completion. Private
`alternate-coverers-{assessment-progress.json,persisted-evidence.json,alias-verification.json,validation-result.log}`
records the exact outcomes. Source #5871's active Paid run remains untouched;
refresh its resulting work before credential consolidation. Repeat successful
changed-code publication stability still needs verification.

The preceding provider-key handoff job `0dcbedde-302d-431c-ba9e-5212aa1d8c6e`
finished at 10:32:58 UTC on the earlier scanner code: 250 findings, zero creates,
one update, zero reopens/closures, 41 deferred, zero assessed, all categories
collected and an inference timeout after 137,745 ms. This is not healthy
assessment evidence. Its independent import succeeded: repair 1154 / #5852 /
PR #5868 retains the original source instructions and rationale, with no active
source run. Private `provider-key-{ownership.json,validation-result.log}` records
both import and timeout evidence. No physical repair was applied to the operating
database, and full repository CI remains unverified.

## GoodJob recovery and refreshed complete PR accounting

At 10:44:51 UTC the dedicated GoodJob process 1837378 was alive but its database
heartbeat was stale since 10:35:49 UTC. There were 51 runnable jobs and no recorded
jobs executing; the scanner remained queued. An Overmind jobs-only restart request
did not stop that stale process. A direct TERM to the same worker allowed the
supervisor to replace it with 2309864. The two Temporal worker processes remained
1475092 and 1475093 throughout; no active Paid agent run was cancelled or restarted.
New worker heartbeats and execution counts advanced, runnable work drained and the
original queued scanner job executed once. The 10:55:34 UTC sample had a fresh
heartbeat, 98 maintenance executions and three runnable jobs across all queues.
No claim is made that the underlying reason for the old worker stall is repaired.
Private `goodjob-health-{observation,after-restart}.json` preserves both states.
The restart loaded the current operating workspace, including unrelated existing
runtime changes; scanner source hashes, not a clean full-workspace revision,
identify the tested patch.

The complete 10:44:51 UTC audit has 193 trusted open PRs, 161 containing explicit
index removals and 192 distinct removal targets. Every immutable comparison is
complete; there are no repeated targets or removals of observed covering indexes.
Private `pr-all-alternate/` records current refs and comparisons. The 10:43:51 UTC
snapshot has 248 findings, 209 owned, 39 unowned and 177 open scanner issues.
Its complete `post-alternate/finding-dispositions.json` records 193 findings with
an implemented index-removal target (including an unused-index observation), seven
constraint claims requiring causal implementation/acceptance review, nine catalog
redundancies requiring implementation, 22 queries needing causal evidence, 16
unused-index observations needing usage/dependency evidence and one cache finding
needing representative workload evidence. These remain unfinished dispositions,
not acceptance or completion. The later new issue #5873 is outside that snapshot.

Sources #5851 and #5863 are in waiting_recovery, not completed implementations;
no PR is recorded for either. Inspect their recovery state and any generated
artifacts before taking them over. Lack of an active agent alone does not prove
there is no recoverable work. Existing sources and acceptance requirements remain
open; no additional speculative consolidation was performed.

## Combined isolated migration acceptance and subsequent scan limits

Actual migration files from all 161 index-removal PR heads in the complete audit
passed combined up/down replay against trusted base
`3497e0f4bc5d929ea05123cb1d4860ca02cf78bc` at 11:25:51 UTC. Independent
PostgreSQL snapshots verified exactly 192 intended removals and restoration of
all original index definitions. Thirteen seeded application rows, all other index
properties, constraints, table security, policies, triggers and functions remained
unchanged. All 192 target/coverer catalog pairs matched operating definitions.
These PRs contained no runtime changes outside migration/schema files.

Seven constraint migrations from PRs #5617, #5618, #5619, #5620, #5621, #5622 and #5624
passed separate replay at 11:35:02 UTC. Up validated exactly the intended
seven constraints; down preserved validation. Data and other schema properties
remained unchanged. The verifier matched a regenerated FK by table and definition
and reviewed an equivalent enum check expression after schema roundtrip; generated
FK names and PostgreSQL expression rendering were not assumed stable.

Both runs used a private PostgreSQL 16 database with network disabled. The app
shared only its loopback network namespace, ran without root or capabilities and
had no host bind mounts, published ports or operating credentials. Untrusted PR
migration files executed only there; independent snapshots were taken outside
the migration process. Private `/tmp/paid-pghero-index-acceptance/` retains exact
manifests, refs, isolation evidence, snapshots, logs and passing `result.json` and
`constraint-result.json`. This establishes isolated schema/data acceptance, not
representative workload performance, full repository CI or operating migration
acceptance. No physical repair was applied to the operating database.

Repeat scanner job `444b8dfb-bc92-4444-b3b3-59d10b07fb52` ran from 10:58:39 to
11:00:31 UTC: 250 findings, zero creates, two updates, zero reopens/closures,
40 deferred and zero assessed, with `AgentHarness::TimeoutError`. A subsequent
small routing probe also timed out. Neither result proves successful assessment
or repeat publication stability. Scheduled job
`7939369b-fbf5-49c7-8950-fa1442269d21` ran at 11:25:08 UTC and failed with a
GitHub API rate limit error (reported reset 11:26:09 UTC). Refresh capacity and
unfinished jobs before another normal validation run.

A fresh native recovery read confirms source #5851 completed as PR #5874 with
commit `78b7ca7dd1101eaf587a6d1207d9527a86ef6314`. Source #5863 remains in
waiting_recovery with commit `67601f05584e3ff47622e2672127a27edb2c3658` and no
recorded PR. A GitHub search by its exact branch returned no PR. Its existing
commit still needs inspection and recovery rather than duplicate implementation.
These observations supersede the earlier recovery snapshot above.

## Credential prefixes consolidated after Paid completion

Sources #5871 and #5870 completed as PRs #5872 and #5877.
PR #5877 was closed as superseded after a fresh active-run guard found neither
source nor PR executing; its original description was preserved beneath the
canonical repair link. Their actual patches
removed different prefixes of the same retained full unique credential index.
PR #5872 now contains both removals at `abe10df2c`, with `Fixes` references to both
sources and paid-automation handoff. Both sources have the waiting label and
remain open. The account/revocation lookup index is retained alongside full
account/runner/name uniqueness. Ownership import and alias closure still require
normal scanner verification before closing either source.

The combined regression failed on the original migration (three examples, two
failures), then the migration and RunnerCredential suite passed all 24 examples
(seed 16686). Private schema fixtures verify both removals, exact rollback,
reapplication, record preservation and uniqueness. Schema regeneration used only
the private test database. Commit hooks passed; full Ruby lint passed all 4,983
files and JavaScript lint passed. Full Markdown lint followed the temporary
node_modules symlink into dependency READMEs and failed; the symlink was removed.
Coherence exited successfully with existing advisory gaps. Full CI, workload
performance and physical operating acceptance remain unverified.

For #5863, GitHub's exact branch resolves to the base revision and cannot serve
recorded commit `67601f05584e3ff47622e2672127a27edb2c3658`. No local workspace
volume remains. Stored agent logs confirm a commit was created before successful
container cleanup, but retained file-change records contain paths rather than
patch bodies and command output is truncated. Private recovery log evidence is
retained in `recovery-full-logs-32268.json`. Do not claim that implementation was
published or its full source recovered.

## Verified credential ownership and refreshed repair inventory

Normal job `d1a6414a-da50-46ea-96c4-b9191c054b8a` ran 11:52:46–11:54:20 UTC:
244 findings, two assessed, one create, three updates, zero reopens/closures,
33 deferred, nil planning error and all categories collected. Both credential
prefixes now belong to repair 1162 / canonical #5870 / PR #5872; original
instructions and rationales from both sources remain verbatim. A fresh active-run
guard found neither source executing. Alias #5871 was closed with canonical links
and its original body preserved. Canonical #5870 remains open for physical
acceptance. New #5878 covers the previously unowned service-container account
prefix; its target was absent from the complete prior implementation inventory.
Private `credential-handoff-{receipt,ownership}.json` records publication/import.
The preceding small routing probe timed out, demonstrating why a small probe alone
cannot establish the outcome of a normal scan.

The 11:55:27 UTC immutable audit (`pr-all-credential/`) covers 197 open trusted PRs,
165 index-removal PRs and 197 distinct targets, with no repeated removals or
removals of current observed coverers. The 11:52:13 UTC snapshot has 246 findings,
210 owned, 36 unowned and 178 open scanner issues; it predates the successful scan
and alias closure above. Its explicit ledger accounts for every finding, with
193 matching the exact immutable heads exercised by combined isolated acceptance.
Changed/new heads are not credited with that earlier replay. Three remaining
catalog sources have recorded commits but no PR: #5790 (timeout, ce44e362f), #5822 (timeout, 9163e9474), #5863 (waiting_recovery, 67601f055). Each lacks a live
container/handle and needs artifact recovery before replacement work.

Two deferred model-selection queries (`-5925980023722500190` and
`-5891326464486699645`) trace to `PartialCloseoutProjectionInputWatermark`:
`merge_signatures` separately executes count and maximum over the same joined
scope. No current audited PR changes that file. A SELECT-only tenant-scoped
operating EXPLAIN ANALYZE sample measured count 17.099 ms, maximum 12.173 ms,
and combined aggregation 12.137 ms. This identifies a shared repair candidate,
not representative improvement acceptance: sequential warm-cache bias, empty-group
semantics, tenant isolation and implementation remain to verify. Private
`watermark-query-evidence.json` and `watermark-shared-repair-disposition.json`
retain plans and the explicit remaining evidence.

Repeat normal job `1ff79061-1571-4f9a-abba-46818d5f8d00` started 11:55:08 UTC;
its assessment selected eight findings and one work item in 7,645 bytes. It finished
11:56:50 UTC with 246 findings, eight assessed, zero creates, one update, zero
reopens/closures, 35 deferred, nil planning error and all categories collected.
Alias #5871 was fetched closed after terminal completion. These consecutive
successful runs demonstrate scope progress and credential ownership stability;
they do not establish that every remaining repair scope is correct.

A subsequent exact-branch fetch recovered #5790 commit ce44e362f from GitHub.
It contains a real guarded concurrent migration and rollback, schema changes,
intent and tests. Publication and independent validation remain pending; the
recorded timeout did not mean its source was lost.

## Recovered unpublished catalog repairs

Exact remote branches retained #5790 commit
`ce44e362f2e8511f0f0be2f2b2620eff26c426db` and #5822 commit
`9163e9474e42e1b836c932aa294cace06556359b`. Exact-head GitHub searches found
no existing PRs. Fresh native execution guards found neither source active.
Both actual migrations passed isolated combined up/down replay at 11:58:00 UTC:
exactly two intended targets removed and restored, with all 13 fixture rows,
other indexes, constraints, RLS, policies, triggers and functions preserved.
Private `/tmp/paid-pghero-index-acceptance/recovery/` retains source hashes,
manifest, before/up/down snapshots and passing result. Its manifest `pr` values
are source issue numbers because validation preceded publication.

Draft #5879 publishes the existing project-MCP-server prefix repair for #5790;
draft #5880 publishes the existing trusted-measurement project-prefix repair for #5822.
Each has its `Fixes` reference and paid-automation label; sources have
waiting labels and remain open. No replacement implementation was created.
Bodies distinguish independently observed replay from unrun permanent suites,
full CI, workload and operating acceptance. Both inherited spec-ID collisions
need integration cleanup; #5880 has mock-only permanent specs, while #5879's
coverer guard needs invalid/partial-index review. These are explicit remaining
review requirements, not proof that each PR is ready to merge. Normal ownership
import remains to verify. No physical operating migration was run.

## Unused-index retention dependencies and recovery-import observation

Read-only catalog evidence at 12:01 UTC enriched all 17 current unused-index
observations. Four are observed coverers for five separate prefix findings:

| Retained unused index | Prefix findings it covers |
| --- | --- |
| `idx_knowledge_artifacts_on_project_type_scope_id_ctype_status` | `index_knowledge_artifacts_on_project_id` |
| `idx_knowledge_audit_events_on_project_created_at_id` | `index_knowledge_audit_events_on_project_id` |
| `idx_knowledge_chunks_project_status_artifact_sequence` | `index_knowledge_chunks_on_project_id`, `index_knowledge_chunks_on_project_id_and_status` |
| `index_service_container_metrics_on_container_and_recorded` | `index_service_container_metrics_on_service_container_id` |

The explicit ledger retains these indexes while prefix-removal repairs depend
on them. Removal would first require an alternative path and updates to all
related acceptance requirements, plus representative usage evidence. Neither
same-table grouping nor zero scans establishes a safe combined repair. Catalog
facts, definitions and constraint dependencies are in private
`unused-catalog-evidence.json`; per-finding requirements are in
`post-credential/finding-dispositions.json`.

At 12:00:33 UTC `track_counts` was enabled, 280 of 1,408 indexes had nonzero scans,
and aggregate scans were 429,465,690. The database `stats_reset` was null, so the
start of a representative observation window is unproven. These facts rule out
all statistics simply being disabled; they do not establish workload coverage or
justify any of the zero-scan removals. Private `unused-window-evidence.json`
retains the sample. No statistics were reset and no operating index was changed.

Normal recovery-import job `2d387806-4ac2-45fc-a143-bc3e8dc200c4` was enqueued
11:59:41 UTC. At 12:01 UTC it remained queued behind an executing
`PartialCloseoutAcceptanceAuditSweepJob` in the single-thread maintenance queue.
The worker had fresh heartbeats and advancing execution counters; no restart or
duplicate enqueue was attempted. Ownership reads before execution still had null
PR references for #5790 and #5822, so import remains unverified. PR #5605's body
now records the two earlier successful terminal scans instead of calling them
queued; broad semantic correctness and physical operating acceptance remain open.

## Shared watermark-query implementation and recovered ownership

Source #5881 and draft paid-automation PR #5882 implement one shared repair for
queries `-5925980023722500190` and `-5891326464486699645`: compute count and latest
update together for each durable watermark scope, including account-grouped
runners. The 197-PR immutable audit had no change to this file; fresh native reads
found both findings unowned, and a subsequent exact-symbol GitHub search found
no open issue. Both observation markers and `Fixes #5881` are on the PR. Source
has the waiting label; normal ownership import remains unverified.

Feature worktree `/tmp/paid-pghero-watermark-aggregation`, branch
`fix/pghero-watermark-aggregation`, commit `4466ec9a8` contains source, intent
(PARTIAL-CLOSEOUT-042) and permanent regressions. The original code failed one of
four new examples by issuing two aggregations. After implementation, 27 focused
watermark/reconciliation/invalidation/projection-security examples passed (seed
44622); the final test prose cleanup rerun passed four (39334). Changed-file
lint and commit hooks passed, and coherence completed with existing advisory
gaps. Simplicity review retained one small shared grouped-input helper and no
new service, dependency or index.

Read-only repeatable-read operating comparison at 12:05:28 UTC preserved every
old/new fingerprint and watermark for projects 19 (Paid), 14 and 15 under a
frozen local clock. Source loaded only into the diagnostic runner, not the
operating app. Private `watermark-operating-parity.json` retains exact snapshots.
The earlier EXPLAIN sample suggests reduced scan work but is not representative
performance acceptance. CI/review, operating process exercise and successful
collector disappearance without a replacement regression remain required.

Recovery-import job `2d387806-4ac2-45fc-a143-bc3e8dc200c4` ran from 12:01:57 to
12:03:57 UTC: 245 findings, zero creates/updates/reopens/closures, 34 deferred,
zero assessed, all categories collected and an inference timeout. This is failed
assessment, not deduplication success. Its ownership import nevertheless
succeeded: #5790 maps to repair 1117 / PR #5879 and #5822 to repair 1138 / PR #5880,
with neither source active. Private `recovery-publication-ownership.json` records
those separate facts. The worker was left running; no duplicate job was enqueued.

## Reconstructed remediation-prefix repair and watermark import

Draft paid-automation PR #5883 implements #5863 at `638731223` on branch
`fix/pghero-remediation-account-index`, worktree
`/tmp/paid-pghero-remediation-account-index`. It drops only the nonunique account
prefix, preserving the full budget coverer and all other indexes; rollback
restores the prefix. Catalog guards reject changed uniqueness/keys/predicates
or a missing, partial, invalid, differently keyed or non-btree coverer. Source
has the waiting label and remains open. The earlier result commit was unavailable
and its remote branch remained at base; a fresh PR search and active-run guard
found no competing implementation/execution before publication. Its old
waiting_recovery record was not cancelled or marked successful.

Rails generated the migration; a guarded private test preparation applied its
initial no-op before the failing-first suite (five examples, five failures).
Implementation and real missing/partial/invalid/wrong-key coverer regressions,
plus model tests, passed nine examples (seed 55339). The invalid-index fixture
uses a failed concurrent unique build, rather than mocking index validity.
Private full-schema up/down replay passed at 12:10:48 UTC: exactly one intended
removal and restoration; all 13 application fixture rows, other indexes,
constraints, RLS, policies, triggers and functions preserved. Source SHA-256 in
`/tmp/paid-pghero-index-acceptance/remediation/manifest.json` matches the published
commit; its published_pr field links #5883 to the pre-publication replay.
Schema regeneration used the private test database. Staged lint and hooks passed;
coherence completed with existing advisory gaps. POSTGRESQL-PERSISTENCE-042
captures the repair. Simplicity review retained direct migration guards without
a new runtime abstraction. CI, representative workload and physical operating
migration/disappearance remain unverified.

Normal watermark-import job `dee8e256-7686-4c50-b870-c59217d1da52` ran from
12:07:41 to 12:09:15 UTC: 246 findings, two assessed, zero creates/updates/reopens/
closures, 33 deferred, nil planning error and all categories collected. Both
watermark-query findings now share repair 1166 / #5881 / PR #5882. A native read
verified the shared ownership after terminal completion. This proves import and
successful assessment for the exercised scope, not operating performance
acceptance of the proposed watermark implementation. Private snapshot
`post-watermark/snapshot.json` predates that import and must not be presented as
a later terminal snapshot.

## Service-container prefix handoff

The 12:12:52 UTC snapshot (`post-remediation/snapshot.json`) has 248 findings,
213 owned, 35 unowned, 179 repairs and 179 open scanner issues; all categories
collected. It predates the following handoff and is not a closeout snapshot.
Source #5878 was the remaining catalog prefix without known implementation.
Its queued run 32304 was cancelled under lock only after checking no workflow,
start timestamp, container or runner handle; active Paid runs were untouched.
Source has waiting, and draft #5884 has `Fixes #5878` and paid-automation.

Feature branch `fix/pghero-service-container-account-index`, worktree
`/tmp/paid-pghero-service-container-account-index`, commit `e00b30594` removes only
the account prefix while retaining full account/name uniqueness. Guards reject
changed original uniqueness/keys/predicate and missing, partial, invalid,
differently keyed, nonunique or non-btree coverers. Rollback restores the prefix.
Rails generated the migration. Failing-first no-op replay had nine examples,
eight failures; implementation plus ServiceContainer models passed 33 examples
(seed 56451). The tests use real private-schema indexes, including a failed
concurrent build for invalidity, and verify records, rollback, reapplication and
per-account name uniqueness. Staged lint/hooks passed and coherence completed
with existing advisory gaps. POSTGRESQL-PERSISTENCE-043 links the contract;
simplicity review added no runtime abstraction.

Independent isolated full-schema up/down replay passed at 12:17:29 UTC: exactly
one target removed/restored, 13 seeded application rows and all other indexes,
constraints, RLS, policies, triggers and functions preserved. Private
`/tmp/paid-pghero-index-acceptance/service-container/manifest.json` matches the
published migration hash and links #5884. The first attempt failed before up
when a snapshot returned empty output; its failure receipt/log were retained.
A direct retry returned a full snapshot, no replay process remained, and the
subsequent replay passed. This is not a migration failure or permission to
restart a live unobserved replay.

Schema comparison caught the earlier remediation index removal still present
in the shared private test database. Its private rollback restored that index
before regenerating the service-container dump; no schema file was manually
edited. The final dump contains the intended removal and generated trigger
ordering only. No physical operating index changed. Normal ownership import,
full CI, representative workload and operating disappearance remain unverified;
Issue #5878 stays open for that acceptance.

## Complete current-head replay and durable disposition ledger

The 12:20:45 UTC immutable audit (`pr-all-current/`) covers 202 trusted open PRs,
169 index-removal PRs and 201 distinct targets. No target is removed twice and
no current observed covering index is removed. Actual migration sources from all
169 captured heads passed combined isolated up/down replay at 12:21:46 UTC:
exactly 201 removals and exact restoration, with 13 seeded application rows,
other indexes, constraints, RLS, policies, triggers and functions unchanged.
Private `/tmp/paid-pghero-index-acceptance/current/` retains complete source
hashes, manifest, external snapshots and passing result. This supersedes the
161-migration replay for those current heads; it does not establish workload,
CI or operating migration acceptance. The seven constraint PR heads also still
match their independently replayed sources and have no runtime changes outside
migration/schema files.

The [durable ledger](experiments/pghero-repair-ledger-2026-11-28.json) accounts for
all 248 observations in the 12:12:52 UTC snapshot against those later immutable
implementation refs: 202 observations have independently replayed index removals,
seven have replayed constraint validation, two share the implemented watermark
aggregation, 20 queries require causal repair evidence, 16 unused indexes require
usage/dependency evidence and one cache warning requires a demonstrated repair.
The ledger separates isolated validation from outstanding operating acceptance.
It is a dated snapshot, not a claim that the dynamically changing live backlog
is closed. Refresh findings, heads and active executions before action.

The longer natural-workload cache sample spans 08:40:03–12:19:57 UTC (13,194 s),
with unchanged postmaster and reset metadata and monotonic counters for all 245
compared tables. Table-buffer hit rate over that interval is 95.371%:
20,806,472 heap reads and 428,666,657 heap hits. Style-guide run exposures account
for 17,898,360 reads (about 86%); container metrics account for 1,498,643.
`QualityMetrics::Collect#update_style_guide_version_stats` repeats the exposed
version aggregate per exposure and matches query 2709477187845439382. This makes
batch aggregation a concrete investigation lead, not a verified shared cache
repair. Representative version bindings, before/after plans, result equality and
timing are still required. Shared-buffer misses may hit OS cache, I/O timing is
disabled, and investigation traffic is part of this uncontrolled development
interval. No memory setting was changed. Private
`cache-workload-{long-end,long-interval}.json` retains the measurements.

Normal catalog-import job `7b8d3832-aacf-4f2d-8d34-5a33836aff92` ran from
12:19:31 to 12:21:21 UTC: 244 findings, zero creates/updates/reopens/closures,
31 deferred, zero assessed, all categories collected and an inference timeout.
It does not extend successful assessment evidence. Import nevertheless succeeded:
repair 1160 / #5863 / PR #5883 and repair 1165 / #5878 / PR #5884 were verified
natively after terminal completion (`final-catalog-ownership.json`). Earlier
successful scans remain the evidence for assessment progress and alias stability.

## Style-guide statistics batching

Source #5885 and draft paid-automation PR #5886 implement query
2709477187845439382 at `f46b06e7d` on branch
`fix/pghero-style-guide-stat-batching`, worktree
`/tmp/paid-pghero-style-guide-stat-batching`. No audited open PR changed the owning
service, exact-query issue search found no open issue and a native read found
the observation unowned with no unfinished scanner job before publication.
Source has waiting and the PR declares `Fixes #5885` plus the single observation
marker. Normal ownership import remains unverified.

Read-only repeatable-read plans used seven actual exposed versions from run
32275. Account-scoped separate aggregates totalled 2,136.642 ms versus 331.828 ms
grouped, with identical nonempty results. Shared-buffer accesses fell from
1,528,085 to 228,789. System-access results also matched (1,852.882 versus
278.914 ms). The first account binding search had returned empty; the later
paired account query returned seven nonempty groups, so that first search is
not evidence of a tenant visibility defect. Private
`style-guide-{system-bindings,query-plans}.json` retains complete inputs and plans.
These are sequential paired samples with cache/order bias, not sustained
operating acceptance or proof that the whole cache warning is repaired.

The implementation captures exposed version IDs, computes one grouped aggregate
and retains batched exposure/version loading. Automated scored-metric and
scoreable-run filters, distinct counts, tenant enforcement and rounding remain;
empty exposed groups reset to zero/null and unexposed versions stay unchanged.
A failing-first two-example suite failed on two queries instead of one. Final
source plus quality collection tests passed 50 examples (seed 41031); final test
helper/path cleanup passed two (9788). Cases distinguish independent version
scores and exclude human metrics/auth-expired runs. Staged lint and hooks passed;
coherence completed with existing advisory gaps. QUALITY-LOOPS-010 links intent.
Simplicity review added no service, index or dependency and retained batch loading.

The durable ledger incrementally records this implementation against the same
dated observation snapshot; it does not pretend the later PR existed during the
12:20:45 full-ref audit. CI/review, normal import, operating process exercise,
repeated workload comparison and successful collector disappearance remain
required. Operating application source and database settings were not changed.
The cache-warning disposition remains independent and open.
