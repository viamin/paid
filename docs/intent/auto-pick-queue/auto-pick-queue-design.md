---
parent: PAID
prefix: AUTO-PICK-QUEUE
---

# Low-Level Design: Auto-Pick Queue

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the queue-seeding lifecycle for project Auto-Pick.

## Purpose

Auto-Pick turns eligible project issues into queued automatic agent runs. The
project toggle is the operator control for that lifecycle: enabling it seeds
eligible work, and disabling it stops future automatic picks and drains queued
automatic picks.

The additive exception is tracked under
`docs/intent/automation-activation-labels/`: when the project toggle is off,
an issue-scoped activation label may still enable exactly one issue without
changing the background queue semantics for every other issue.

## Disable Semantics

Queued Auto-Pick runs are cancelled, not deleted, when Auto-Pick is disabled.
That preserves run history while removing the work from scheduler and dashboard
queue views. The drain applies to queued runs only (`status = "queued"`) so a
run that has already started executing is left to the normal cancellation and
execution controls.

Some Auto-Pick-adjacent enhancement rechecks are queued as automatic
`enhance_issue` runs by the GitHub sync path without the `auto_pick` flag set.
Those runs still belong to the Auto-Pick lifecycle for queue-drain purposes and
are cancelled when Auto-Pick is disabled. Manual `enhance_issue` runs remain
queued.

Enqueue paths may bypass broader project gates after a caller has already
established eligibility, but they must still respect the canonical
`auto_pick_enabled` switch at call time so stale sync or retry work cannot
recreate queued Auto-Pick runs after the operator turns the feature off.

## Issue-analysis cooldown gating

Auto-Pick eligibility also respects issue-level `analyze_issue` cooldowns
recorded after provider exhaustion. A failed issue that is otherwise eligible
must stay out of the candidate pool until its persisted next-attempt time,
unless the owner's issue-analysis runner configuration / runner-health context
has changed since that cooldown was recorded. Manual retries do not consult
this gate.

A needs-input label is an independent, always-on eligibility exclusion. It
applies regardless of `paid_state`, so a stale local state cannot schedule work
while a user clarification remains pending.

Category exclusion is label-based: the effective project, owner, or tenant
Auto-Pick skip-label configuration is authoritative. Titles, body headings,
and incidental issue references never create a scheduling hold. Readiness
dependencies come only from declared dependency records and authoritative
child relationships.

## Existing dependency cycles

Newly parsed dependencies are guarded against cycles, but a previously
persisted graph can still contain one after an older import, incomplete sync,
or a formerly unresolved cross-project reference becomes observable. Paid
reconciles account-scoped effective blocking edges after dependency changes and
through a bounded maintenance sweep. The effective graph includes resolved
cross-project references and follows the same open-state and child-to-parent
contextual-reference exclusions as readiness.

Each strongly connected group produces one deterministic Inbox request keyed by
its members. Its occurrence is derived from the persisted dependency rows, so a
group that becomes acyclic and later recurs is a fresh occurrence even when its
members are unchanged. It shows an exact cycle path, linked projects/issues,
the count of downstream open work held by the group, and the persisted GitHub
source for each declaration when synchronization can identify it. Legacy edges
without provenance remain visible and explicitly direct the operator to inspect
the dependent issue. The occurrence remains until a subsequent synchronization
observes an acyclic persisted graph (either because the cycle agent run below
repaired it, or because a human corrected the declaration on GitHub directly).
A failed reconciliation is logged as unavailable; it is not treated as proof
that no cycles exist.

An authorized operator may start a cycle agent run from that Inbox occurrence.
The run snapshots the occurrence and effective-graph revision, all members of
the strongly connected group, and every effective internal edge; it never
limits its evidence to the displayed witness path. Starting requires run
authority on every represented project and serializes starts per occurrence so
only one queued or running run exists. A failed run, or a graph revision
change, permits an explicit fresh retry.

The run uses Paid's synthetic agent-run record and `agent_harness` route. It
supplies issue titles, labels, parent context, URLs, declaration provenance,
and only issue bodies and comments admitted by the project's existing trust
boundary. Its recommendation records candidate declaration changes, supporting
and conflicting evidence, resulting graphs, and an acyclicity determination
for each candidate. Paid derives each expected resulting graph from the
snapshot and the structured removals or endpoint corrections, rejecting
unaccounted edge changes before checking acyclicity. Missing provenance or
content is reported as unavailable coverage, never silently assumed.

### Bounded repair attempt (#4824)

Issue #4804 shipped this run as strictly read-only: a human always had to edit
the GitHub declaration by hand. That contract is revised here to a *bounded*
repair attempt — most cycles still end up presented for a human decision, but
an obvious, well-evidenced one is corrected automatically.

`CycleAnalyses::ObviousCorrection` applies an explicit, testable threshold to
the validated recommendation after it is produced: exactly one candidate
across the whole recommendation must be acyclic, carry no
`missing_or_conflicting_intent`, carry non-empty `evidence`, have every
`declaration_changes` edge either known to be sourced from an issue body (not
a comment — outside the existing write boundary) or carry no persisted local
provenance at all, and touch no issue whose trusted content was unavailable. A
missing *local* `declaration_source`/`declaration_url` is never by itself a
reason to call a candidate unqualified — plenty of pre-existing
`IssueDependency` rows predate provenance tracking even though the live
GitHub declaration they describe is perfectly current — so that case is
deferred to a live re-check at write time rather than rejected here. A
candidate's edge count and the model's own stated confidence are never
substituted for these checks — a lone edge removal that fails any one of them
is not obvious. More than one qualifying candidate is ambiguous, not obvious,
even if every individual candidate looks clean.

A qualifying candidate goes to `CycleAnalyses::ApplyRepair`, which re-derives
everything from scratch before writing anything: it re-checks run authority
for every represented project, re-reads the account's effective dependency
graph, and aborts without writing if the occurrence is gone, its
occurrence/graph-revision changed, an edge's re-fetched declaration source no
longer qualifies (now known to be a comment), or re-applying the candidate's
declared changes to the fresh edges would not be acyclic. Only then does it
write: it re-fetches each affected issue's live GitHub body and locates the
specific declaration line via `CycleAnalyses::DeclarationEdit` — whether or
not the edge had persisted local provenance, since locating the live
declaration by its endpoints is the same operation either way. That lookup
requires the target reference to resolve unambiguously to exactly one line
with no other reference sharing it; a reference found more than once (or
sharing its line with another reference) aborts rather than guesses. A
confirmed match is written via `GithubClient#update_issue` with the edited
body, never touching unrelated body content, comments, or labels. Absence is
handled differently depending on provenance: for an edge with known local
provenance, a target reference entirely absent from the fetched body is
treated as already applied and skipped rather than rewritten, so a retry
after a prior partial failure never repeats a completed edit; for an edge
with no local provenance, that same absence instead aborts the repair,
because there is no record that the declaration was ever live to have
already been edited — an unprovenanced miss cannot be told apart from a
declaration that never existed as stated.

After writing, the affected issue(s) are re-parsed locally from the same fetched
body (the same contract `Issues::ParseDependencies` always uses), and the
account's effective graph is read again to confirm the group is actually
acyclic before the repair is reported successful. Because the Inbox always
re-derives its dependency-cycle occurrences live from the persisted graph, a
confirmed repair makes the occurrence disappear on the next read — there is no
separate "clear" step. If that confirmation read itself fails (infrastructure,
not the edit), the repair is reported as confirmation-pending rather than
success or failure, and nothing is rewritten on a later retry since the edit
already landed. If the group is still cyclic after a verified write — a
concurrent edit raced the repair — the occurrence stays held and visible with
that status. Any outcome short of a confirmed repair (ambiguous, stale,
unauthorized, missing provenance, a declaration that could not be isolated, a
GitHub write failure, or still-cyclic) leaves every declaration untouched and
keeps the occurrence held with its evidence, proposed change, and status
visible — the same shape the strictly-read-only path already produced.

The web Inbox and the authorized API/MCP surface present the identical repair
outcome and diagnostics. **view run** is shown only for an occurrence the
agent could not solve; a confirmed repair never needs it as a follow-up action
because the occurrence it would have pointed at is already gone from the
Inbox. The run itself remains reachable through ordinary run history either
way.

Each path node also carries its own title, current labels, and (when a parent
issue is linked and its project is within the viewer's authorized project set)
the linked umbrella issue's number and title — all read from already-synced
local issue data, so judging which declaration is wrong never requires opening
every linked issue on GitHub first. An unlinked or not-yet-authorized parent
simply omits umbrella context rather than failing the detail. The Mobile API
cycle payload (`Api::V1::InboxEntrySerializer`) exposes the identical path,
edge, and umbrella context so API and agent clients can inspect the same
cycle the web Inbox renders.

## Tier-infeasibility gating

Issues whose most recent model selection pins a tier no enabled runner can
satisfy stay out of the candidate pool (#4093). The latest selection predicts
the tier the next run would pin — selection inputs are deterministic per
issue — so without this gate Auto-Pick keeps creating runs that fail dispatch
with `NoTierCapableRunner`. Feasibility is re-derived from live runner
configuration via `Runners::TierCapability` on every pass, so the exclusion
clears itself once a capable runner is configured; the dispatch-time tier
filter remains the final gate (AUTO-PICK-QUEUE-011, RUNNER-FALLBACK-010).

Feasibility is resolved over the whole `LlmModel::TIERS` catalog rather than
over the tiers candidate issues happen to have pinned, which lets the pass skip
the `model_selections` lookup whenever every catalog tier is satisfiable
(#4556). Because feasibility depends only on the owner's runner configuration,
`Runners::TierFeasibility` resolves it once per owner for a pass and reuses it
across that owner's projects, so a dashboard with many Auto-Pick repos does not
re-read runner configuration per repo. The memo lives only as long as the pass:
nothing persists, and every new pass re-derives feasibility from live
configuration.

## GitHub-open authority and visibility

An issue that remains open on GitHub is never removed from Auto-Pick merely
because Paid has reached an internal workflow state. Candidate selection and
the project issue lifecycle use the same state-neutral scope, so
`recommend_close`, `manual_review`, `needs_input`, `completed`, `analyzed`, and stale
`in_progress` rows remain actionable when no other guard applies. Active runs,
open dependencies, explicit label controls, pauses, and the durable
no-code-required / merged-PR safeguards remain separate guards.
`analyzed` is deliberately absent from the non-blocking dependency and
subissue states: a closeout audit pending from a merged non-closing source PR
cannot satisfy downstream work solely because sync repaired its bookkeeping.

The project issue list displays each issue's Paid state beside its lifecycle
badge. The dashboard's eligibility breakdown continues to report the actual
guards that exclude open issues, so a workflow-state drift cannot become an
invisible block.

## Epic umbrella acceptance audits

The `epic` label identifies an umbrella issue; it is not an Auto-Pick hold by
itself. An open umbrella becomes runnable only when the existing authoritative
child and dependency relationships are resolved. GitHub sub-issue links and
explicitly declared child/dependency relationships are authoritative; Markdown
checkboxes, titles, and incidental issue references are not readiness signals.
A dependency edge from a child to its own parent is a contextual parent
reference rather than a prerequisite — the umbrella's sub-issue machinery
already governs that work in the other direction, so treating the edge as
blocking would deadlock the pair.

When it becomes runnable, the agent performs a final acceptance audit against
the approved RDR/HLD/LLD/EARS and the issue's acceptance criteria. Closed
children are evidence of completed work, not proof of conformance. The audit
may make bounded corrections and documentation updates, or create focused
blocking children for gaps and leave the umbrella open. A no-code-required
outcome remains visible on GitHub and follows the ordinary closure policy.

An umbrella that has already completed an audit is not repeatedly re-picked.
If that audit creates child or dependency work, however, its terminal
no-code-required or merged-PR guard is lifted after that newly linked work
resolves, permitting one subsequent audit. Ordinary implementation issues keep
their terminal safeguards. Project, effective-owner, and tenant skip-label
overrides remain authoritative: operators who deliberately configured `epic`
as a skip label must remove it from that effective override to enable audits.
Later metadata updates to work that predated the terminal audit do not count as
newly linked work and cannot re-arm the umbrella.

The re-arm comparison uses the *resolution* timestamp of the prerequisite —
the time the open -> closed transition actually happened — rather than the
link timestamp. Mid-run link races can stamp `parent_issue_linked_at` before
the audit's terminal stamp even when the audit itself filed the work; without
the resolution-timestamp comparison the umbrella stays stranded forever.
`issues.closed_at` is stamped on the open -> closed transition and stays
untouched by later label/comment syncs (unlike `updated_at` and
`github_updated_at`, both of which move on unrelated writes), so label edits
on long-closed prerequisites do not move the resolution timestamp either.
For legacy rows the comparison falls back to `parent_issue_linked_at` (for
children) or `issue_dependencies.created_at` (for dependencies), so the
audit-filed-mid-run case still re-arms after the linked work resolves.

## Partial merged implementations

A merged implementation PR is normally terminal evidence for duplicate-work
prevention, not evidence that its source issue is complete. When the completion
workflow's semantic assessment records an explicit partial outcome, Paid stores
the time the issue was parked for assessment, the merged PR number, and an operator-visible reason on
the source issue. The assessment uses `agent_harness`; scheduler code does not
infer semantics from a PR title, body, or closing-reference syntax.

The semantic assessment runs asynchronously in
`Issues::AssessPartialCompletionJob`. The GitHub poll activity only persists
the generic parking state (manual review with a dependency-blocked reason) and
queues the assessment job per issue with a merged source PR and its parking
time; the poll's
`start_to_close_timeout` budget is therefore not consumed by a synchronous
LLM round trip per blocked row, and a slow harness cannot fail the whole
sync. The job records partial columns only on an explicit `partial: true`
verdict and clears them only on an explicit `partial: false` verdict. A
transient nil assessment (harness error, timeout, malformed JSON) leaves
existing partial-completion evidence in place, so a stranded issue cannot
lose its re-arm data to transport noise. Queue admission consumes only the
durable verdict the job records.

The stored outcome permits the same bounded re-arm used by an epic audit: an
authoritative child or dependency must resolve strictly after the issue was
parked for assessment. Capturing that baseline before the asynchronous LLM
round trip ensures a prerequisite that resolves while the assessment runs can
re-arm the issue.
The scheduler consumes only the stable resolution timestamp and the persisted
outcome, so repeated webhooks, polling, concurrent schedulers, and unrelated
sync writes cannot continuously requeue the issue. Existing queue uniqueness
and dequeue admission remain the final exactly-once protection.

The partial-completion re-arm's eager path mirrors `child_times`'s PR
exclusion by skipping the `partial_completion_parents` branch when the
closing child is a pull request, so a closing tracking PR alone does not
re-arm the parent and waste an admission that queue admission would deny
anyway.

Authoritative prerequisite resolution covers every prerequisite graph the
scheduler already reads for readiness: local `IssueDependency` rows whose
target is a same-project issue, `parent_issue_id` children, and external
owner/repo#N dependencies whose target issue is observable in another
project of the same account. The external case joins via
`IssueDependency.external_resolved_for_account` (the same join
`Issue.ready_for_work` already uses for cross-project blocking), so the
partial-completion re-arm stays consistent with the model's blocking rule.
The matching target issue's `closed_at` is the stable resolution timestamp;
external targets whose target project is not synced into the account, whose
target issue is not yet synced, or whose target remains in an open blocking
paid_state contribute no resolution timestamp and therefore cannot re-arm the
source.
