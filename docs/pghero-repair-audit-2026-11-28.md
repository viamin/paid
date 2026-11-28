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
