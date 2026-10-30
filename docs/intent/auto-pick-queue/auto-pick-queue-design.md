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
the dependent issue. Paid never selects an edge to remove: the operator reviews
the declarations on GitHub and removes or corrects the appropriate declaration.
The occurrence remains until a subsequent
synchronization observes an acyclic persisted graph. A failed reconciliation is
logged as unavailable; it is not treated as proof that no cycles exist.

The path presentation carries enough locally synced issue context to judge
which declaration is wrong without opening GitHub: every path issue shows its
synced title beside its linked repository reference, its synced labels, and —
when a parent issue exists — the linked umbrella reference and title. The full
title stays available on hover and keyboard focus while the visible text
truncates, and label lists wrap, so long metadata remains readable on narrow
screens. Declaration provenance stays adjacent to its dependent → prerequisite
edge. All of this context is projection over synced `Issue` rows (titles,
labels, same-project umbrella parents), never a live GitHub read, and the
authorized Inbox API cycle payload carries the same per-issue context so API
and agent clients can inspect the cycle without re-fetching each issue.
Because umbrella parents are validated to the path issue's own project, the
project visibility the queue already enforced covers the added context.

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
