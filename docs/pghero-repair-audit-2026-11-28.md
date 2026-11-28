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
