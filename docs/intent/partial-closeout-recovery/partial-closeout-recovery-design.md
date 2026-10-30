# LLD: Partial-Closeout Recovery

```yaml
parent: operator-inbox
prefix: PARTIAL-CLOSEOUT
```

## Problem

Auto-pick eligibility guards are deliberately `paid_state`-independent: once a
merged PR row is authoritatively linked back to a source issue
(`EAGER-QUEUE-011`) or an agent declares a no-code-required completion
(`AUTO-PICK-QUEUE-004`), the issue stays out of selection forever regardless of
internal state. That is the correct duplicate-work default, but an issue whose
merged PR intentionally did not close it (no closing reference) and whose
follow-up work could not be filed or completed disappears from every
actionable surface: it is in no Inbox lane, no lifecycle bucket, and re-setting
`paid_state` does not lift the guard. Operators currently need
database-level investigation to distinguish completed work from a stranded
partial closeout (#4120; examples #3860, #3861, #3871, #3930, #4013).

## Scope

Companion workstreams, not prerequisites: #4118 (automatic continuation after
merged partial PRs) and #4119 (gap ownership / follow-up filing). This segment
delivers visibility + authorized recovery on its own.

## Design

### Evidence: `Issues::CloseoutEvidence`

One value object computes the *closeout evidence* for an issue and a stable
*outcome-generation digest*:

- merged PR rows linked via `parent_issue_id` (`pr_review_phase = "merged"`),
- merged PR rows matched to an originating `create_pr` run's recorded
  `pull_request_number` (repo-qualified URL join, same discipline as
  `Issue.paid_generated_pull_request_source_issue_ids`),
- `issues.no_code_required_at` (terminal-run evidence).

Terminal timestamps use `agent_runs.completed_at` (falling back to the PR
row's `created_at`) — never `updated_at`, matching the immutability rationale
of `merged_pr_terminal_audit_at_by_issue_id` in the auto-pick candidate
source. The digest is a SHA-256 of the canonical evidence list (PR numbers +
terminal times + no-code timestamp), so any *new* terminal outcome is a new
generation.

### Source-closure publication

Closeout assessment uses the run's effective configured runner through
`Llm::Request` and `agent_harness`, with its tier model resolved through
the existing runner model policy and its credentials in the isolated execution
environment when present. Report-only host calls use the same runner's
explicit API credential or native subscription authentication; managed
subscription credentials require an isolated environment. It supplies the
JSON schema in the prompt and validates the
response locally. Unrelated host API keys never select a provider or change
billing mode. Missing or disabled runners and unavailable managed credentials fail
explicitly. Failed responses identify the runner and safe status metadata
without provider payloads or credentials. Harness authentication exceptions
retain their type. Assessment failures never become acceptance evidence.

The existing criterion-level partial-closeout assessment is the sole authority
for publishing a source issue's closing reference. Before a new source PR is
published, Paid obtains the assessment through `agent_harness`, snapshots the
evidence and intent revisions, and persists a `source_closure` disposition on
the run. Deterministic publication code accepts `close` only when the snapshot
is current, contains criterion assessments, every criterion is satisfied, and
no gaps remain. Every other result, including unavailable execution evidence,
partial or blocked work, malformed data, and stale revisions, is `track`.

PR templates, generated descriptions, fallback text, and later repair paths
are normalized against that disposition. Any GitHub closing-keyword variant
that references the source issue — by short or source-repository-qualified
reference — becomes `Tracks` unless the persisted disposition is `close`;
free-form PR prose never grants closing authority. Reconciliation and
acceptance-audit paths reuse the same disposition record, retaining the normal
owner/prerequisite workflow rather than creating a completion authority.

### Visibility: the `partial_closeout` Inbox lane

Derived lane (like `retry_limited`), not persisted state. An open, non-PR
issue is in the lane when it carries closeout evidence, is *not* admitted by
`eligible_scope` (i.e. the guards are what holds it — epic re-arm under
`AUTO-PICK-QUEUE-010` means it is not stalled), has no explicit operator hold
(issue `paused`, auto-pick skip labels, `needs_input` label,
`paid_state` in `needs_input`/`manual_review`, retry abandonment — those are
deliberate operator or lane states, not stalls), has no work in flight
(blocking run or open continuation request), and is not resolved-complete
against the current evidence generation. The detail pane shows the source
PR/run links, the recorded completion outcome, unresolved prerequisites
(blocking dependencies), and the exact reason automatic continuation cannot
proceed.

### Recovery: `IssueContinuationRequest` (scoped authorization)

A deliberate continuation is a persisted, auditable authorization — never a
paid_state edit and never a blanket guard lift:

- `requested_by_id` (actor), `reason` (required), evidence snapshot +
  `evidence_digest` (outcome-generation identity).
- One *open* request per issue (partial unique index `WHERE status='queued'`);
  the request and its queued run are created in one transaction, so
  double-clicks, replays, and concurrent requests queue at most one run (the
  `idx_agent_runs_unique_active_issue` index is the second guard).
- `agent_runs.continuation_request_id` links the run to its authorization; when
  the run reaches a terminal status the request is `consumed` and the guards
  re-arm — an issue is deliberately continued *once* per request.
- Admission validation reuses `DefaultCandidateSource.eligible_scope` with a
  new `continuation_authorized_issue_ids` parameter that lifts **only** the
  merged-PR and no-code guards for the authorized issue. Active-run
  uniqueness, tenant isolation, trust, feature release/design revision holds,
  analysis backoff, tier feasibility, budgets, skip labels, needs-input,
  manual review, paused flags, and unmet dependencies all still apply — with
  the unmet prerequisites explained to the user. A targeted blocker walk
  (`CloseoutStatus.admission_blockers`) returns structured, additive reasons
  from persisted admission-guard evidence, including scanner attempt, analysis,
  and alert links for synthetic findings. It also identifies open native children
  and active human-prerequisite notifications without requiring duplicate
  dependency edges, preserving the notification's policy and evidence until an
  operator explicitly satisfies or revises it; a residual preflight then settles admission with the
  exact scoped `eligible_for_dequeue?` decision the dequeue recheck enforces
  (evaluated from one shared set of project inputs per `StalledCloseouts`
  project batch), so a request the walk
  cannot determine is labelled unavailable with an investigation path rather
  than a guessed guard, and is refused up front instead of queueing a run dequeue would
  cancel and supersede — the walk explains the authority, it never
  substitutes for it.

Human prerequisites carry structured policy and evidence references with stable
keys and revisions. The prerequisite publisher derives a durable identity from
that structured record. When a later assessment changes the referenced identity
or guidance, it updates the existing unresolved notification, retains the prior
references as superseded history, and exposes the explicit replacement-policy
step when operator selection is required. Reconciliation never resolves the
prerequisite, discards valid human evidence, or substitutes solo review for a
team policy; free-text notification content is not used to infer policy changes.

External-work prerequisites are distinct persisted occurrences. Each names the
dependency owner/repository/issue number and is evaluated only against the
account-scoped, synced target state. Inbox renders the target reference, its
current state and owner when known, a safe target link, and an explicit wait or
recheck path. A target state change rechecks the dependent notification and
releases it only when every external occurrence is resolved and every human
occurrence has current sufficient evidence. Human decisions, evidence, and
cycle holds are never inferred from an external transition; dependency cycles
remain in their dedicated cycle Inbox occurrence.

### Submitted prerequisite evidence

Each human prerequisite occurrence has a stable identity beneath the aggregate
notification. An authorized operator can submit an HTTP(S) artifact and an
explanation against that exact identity. The durable submission records actor,
timestamp, identity, and a disposition (`pending_validation`, `sufficient`,
`insufficient`, `stale`, or `unavailable`). A submission begins pending: a
URL, comment, upload, green run, or dismissed alert is never acceptance proof.
A background validator retrieves the artifact through the public-address-only,
size-bounded research transport and delegates its semantic sufficiency judgment
to `agent_harness`; unavailable retrieval, execution, or structured output is
persisted as unavailable rather than leaving the submission pending forever.
A changed source revision makes the submission stale. Only a current,
explicitly sufficient assessment may release that occurrence; personal
dismissal remains a distinct scheduling action, never evidence satisfaction.
After recording a pending submission, a low-priority background validation job
passes the prerequisite criterion, durable references, artifact URL, and
explanation to the configured `agent_harness` runner. These fields are
untrusted claims and are fenced in the prompt as data, never treated as
instructions. The validator accepts only the exact `sufficient` or
`insufficient` dispositions and a bounded reason; transport, parsing, and
concurrency failures fail closed as `unavailable`, and a changed source
revision remains `stale`. The job applies its result only to the matching
current submission and never stores raw model output.
An identical retry preserves the recorded disposition and does not schedule a
second validation; an operator submits changed evidence to request a new
assessment.
Active notifications created before occurrence-level metadata are represented as
one compatible occurrence using their persisted aggregate identity, references,
and operator guidance. A valid submission atomically upgrades that occurrence
with the current source revision; rendering this compatibility view does not
mutate the blocker.

For Inbox lane construction, `StalledCloseouts` batch-loads the evidence and
persisted diagnostic inputs for each project's candidates before evaluating
individual `CloseoutStatus` values. The per-issue status still produces the
same additive blockers; batching changes only how its inputs are read.

### Prompt delivery

The authorization is useless to the executing agent if it never reaches the
prompt: `PromptAssembly::Sections::ContinuationContext` reads
`agent_run.continuation_request` and, when present, contributes a required
"Continuation Context" section carrying the operator's reason, the evidence
snapshot the request was authorized against, the evidence-generation digest,
and guidance (treat the reason as the remaining-work plan; do not re-verify
already-evidenced work; do not treat closed child issues as sufficient
evidence for an epic; leave the issue/epic open if the named scope is not
fully resolved). Both the Inbox action and the `request_issue_continuation`
MCP tool create the run through the same `Issues::RequestContinuation`
transaction, so this section covers both uniformly without branching on
request origin. The section is required (never suppressed by profile
customization) but contributes nothing for ordinary runs, and rebuilding the
prompt (Temporal activity replay) is idempotent — it does not duplicate the
section.

### Consistency at dequeue and run start

`AgentRuns::RecheckIssueEligibility` gains a continuation branch (continuation
runs are manual-trigger, so the auto-pick recheck never applied to them): a
queued continuation run is cancelled and its request `superseded` when the
request is no longer open, the evidence generation changed, the issue lost
admission under the scoped lift, or the project is explicitly paused.
`ProcessRunQueueJob` already rechecks every candidate before claim, keeps the
budget check (`CostBudgets::Check`) and feature-intent admission at run start.

### Resolve-complete (evidence-gated dismissal)

`Issues::ResolveCloseout` records the operator's attestation that the recorded
evidence completes the issue: stamps `closeout_resolved_at`,
`closeout_resolution_digest` (the generation it resolves), and the actor, sets
`paid_state = completed`, and leaves the GitHub issue open. The lane item is
suppressed while the digest matches; new terminal evidence is a new
generation and re-creates the item. Repeated sync cannot recreate a
dismissed/resolved item without new evidence because nothing is persisted by
sync for this lane — it is derived from evidence, and the dismissal is
digest-scoped. Resolution takes the issue lock shared by continuation creation,
supersedes any open authorization, and cancels its unclaimed queued run before
recording completion, so a continuation cannot dispatch after the attestation.

### Surfaces

- Inbox: `Inbox::Queue`/`Inbox::Count` lane + `partial_closeout` detail pane
  with authorized actions (request continuation, resolve complete, guidance
  for prerequisite work), a contextual chat action which retrieves current
  evidence and recovery state without mutating it, and `Inbox::Count` badge
  invalidation on the new transitions.
  The required continuation reason has a persistent
  label and a multi-line input that fills the available pane width. Its submit
  button sits on a separate row, so a narrow detail pane never clips either
  control.
- Controller: `request_continuation` and `resolve_closeout` collection routes
  on `projects/agent_runs` (authorize `:run_agent?`, audit events,
  stale-click resolvers) — same shape as `OPERATOR-INBOX-002C/002D/002E`.
- MCP: `request_issue_continuation` and `resolve_issue_closeout` tools calling
  the same services with the same policy and audit behavior. Prerequisite
  work reuses the existing `create_issue` tool (dependency wording is parsed
  by the existing sync parser).

### Legacy reconciliation: `PartialCloseouts::ReconcileLegacy`

### Assessment transport diagnostics

Closeout assessment is a fail-closed request through the run's effective
configured runner. It reuses the run's isolated environment when available;
report-only host calls use only the selected runner's explicit API credential or
native subscription materialization and clear conflicting API variables. The
request never silently changes provider, credential, model, or billing path.
Failed attempts persist only a bounded category, actual provider/model
provenance when available, request and attempt identities, and invalid-field
paths/types for structural failures. They retain no raw provider response
content or credential material, and an authentication failure names reconnecting
the configured runner credential as the recovery action.

The `partial-closeout-reconciliation-v1` Temporal patch only intercepts new
workflows. Pre-patch runs — including the 2026-09-17 / 2026-09-22 /
2026-10-01 closeouts against #3860, #3861, #3871, #3930, and #4013 — left
the parent umbrella with no `reconciliation` state, no focused follow-up
issues, and no operator prerequisites surfaced. Audit found empty
`reconciliation` records on the latest epic runs for those umbrellas.

`PartialCloseouts::ReconcileLegacy` is a bounded, restartable sweep that
finds those legacy runs and routes them through the same deterministic
machinery the workflow uses:

- **Selection.** Scoped to a single account (the sweep must read across
  tenant RLS to find candidates, but writes are scoped through the project
  associations). A run is a candidate only when it is its issue's *latest*
  PR-producing attempt (MAX(id) per `issue_id`, the same keying the
  auto-pick re-audit exception uses — a superseded earlier attempt's
  evidence must never be assessed), that attempt produced a PR that is now
  authoritatively linked back to the source issue
  (via `parent_issue_id` or the originating run's `pull_request_number`/URL
  join — the same discipline as `Issues::CloseoutEvidence`), and its
  `reconciliation` carries no terminal `status`. A run whose reconciliation
  is already terminal (`reconciled`, `awaiting_operator`, `retryable_failure`
  with a fresh `failed_at`) is skipped, so repeated sweeps do not duplicate
  work. Candidates are ordered by `id` and capped at `batch_size` (default
  200) per invocation, so one call cannot drive unbounded
  `Llm::AnalyzePartialCloseout` cost/runtime against an account's entire
  historical `create_pr` volume; `Result#next_cursor` reports the highest
  scanned `id`, and passing it as `after_id:` on the next call resumes
  strictly past that point regardless of each row's outcome. A non-positive
  `batch_size` is rejected up front (the service raises `ArgumentError`;
  the rake task aborts) because a zero or negative cap scans nothing while
  still printing a continuation whose cursor never advances.
- **Assessment.** `Llm::AnalyzePartialCloseout.call(agent_run:)` produces a
  fresh gap set grounded in current shipped code and current open issues — a
  stale gap whose child has since merged, closed, or been superseded is
  omitted. The assessment is persisted on the run, so retries reuse the
  same gap indices instead of re-invoking the LLM and getting a different
  gap set.
- **Application.** `PartialCloseouts::Reconcile.call(agent_run:,
  assessment:)` does the durable work — opens owners through the existing
  marker-based recovery path (idempotent across retries), records
  `IssueDependency` edges, rewrites the parent body to publish the
  dependency wording, and aggregates human prerequisites into one blocking
  Inbox notification under
  `PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE`. The legacy path
  reuses every replay-safety primitive the workflow uses; it does not
  introduce a parallel code path.
- **No mass-mutation.** ReconcileLegacy does not touch `paid_state`, does
  not infer completion from closed children, and does not auto-close the
  umbrella. The umbrella remains open for its final audit; legacy
  reconciliation only restores the focused follow-up issues and the
  operator prerequisite notifications that the partial-closeout workflow
  would have produced on a fresh run. The `partial_closeout` Inbox lane
  continues to derive from evidence (`Issues::CloseoutEvidence`); the
  legacy sweep only fills in the recorded gaps and notifications.
- **Visibility.** The sweep is restartable; an interrupted pass leaves the
  `creating` markers in place, and the next pass resumes via the existing
  `Reconcile#create_owner!` recovery. The Inbox already exposes the lane
  (`OPERATOR-INBOX-002H`), so a successful sweep immediately surfaces the
  focus work and the blocking prerequisite for the operator without any new
  UI surface. The sweep itself is invokable through an authorized rake task
  (`bin/rake issues:reconcile_legacy_partial_closeouts ACCOUNT_ID=<id>
  BATCH_SIZE=<n> AFTER_ID=<cursor>`) that the operator console / MCP surface
  can call with the account scope; the task prints `next_cursor` and prompts
  a follow-up invocation when the batch filled. A daily GoodJob sweep invokes
  the same service for each active account and persists its account/run cursors
  in chained GoodJob arguments, so it resumes the next bounded window without
  an operator-paced loop. Its concurrency control reserves two queued positions
  while permitting one performer, so an overlapping cron enqueue cannot consume
  the cursor-carrying continuation's slot. Structured completion logs expose scanned,
  reconciled, awaiting-operator, retryable-failure, skipped, lock, and cursor
  outcomes; each reconciled run continues to expose its assessment in the
  existing partial-closeout Inbox lane. An
  account-scoped advisory-lock contention returns a distinct result and the
  rake task and scheduled sweep preserve the cursor rather than presenting a
  zero-row sweep as a completed backlog.

### Automatic advancement after investigation (#4223)

After the shared reconciler persists a current assessment, `PartialCloseouts::Advance`
uses the existing scoped continuation authorization to schedule one fresh acceptance
audit when the assessment has no remaining gaps. This handles stale historical gap
reports whose implementation shipped after the previous audit without asking an
operator to bypass the merged-PR duplicate-work guard. Patched workflows invoke the
advance activity only after PR creation returns with the source run terminal;
`PartialCloseouts::Advance` also refuses a non-terminal source run. This preserves
the continuation admission guard against every other in-flight run on the issue.
Bounded legacy reconciliation already operates on terminal runs. The advancement path
records the normal continuation evidence and audit event, and is idempotent through
the existing open request and active-run constraints.

The source run can finish before its pull request merges. At that point the
merged-PR evidence required for continuation admission does not yet exist, so
an advance attempt may correctly report `not_stalled`. A bounded periodic
acceptance-audit sweep revisits open partial closeouts after merge. For active
auto-pick projects, it queues a report-only `analyze_issue` acceptance audit
when the current assessment is missing or stale and ordinary continuation
guards permit it. It records at most one automatic audit attempt per issue and
closeout-evidence digest, including terminal attempts, so a failed audit does
not loop. A later merged PR or no-code outcome creates a new evidence digest
and can earn one new audit. The existing auto-pick control governs this work;
the GitHub-sync repair places merged non-closing source PRs in this lane rather
than treating their premerge source-closure disposition as final acceptance.
there is no separate audit setting. Operator-requested audits use the same
durable request and count toward the one-attempt limit for that generation.

It only operates while `Issues::AutoPickProjectGate` is open and delegates all
remaining admission to `Issues::RequestContinuation` / `CloseoutStatus`; explicit
holds, trust, budgets, dependencies, scanner verification, and human prerequisites
therefore remain authoritative. Assessments with agent-owned gaps create or reuse
their focused owners and wait for those owners; human prerequisites remain Inbox
items with their exact requested evidence. No path here closes an issue, reopens a
closed owner, dismisses a scanner finding, or treats a merge as verification.

### Human closeout guidance (#4189)

The lane's recovery actions assume the operator already knows which action
fits. The pane therefore carries task-oriented decision guidance (five paths:
review the recorded criteria/evidence; continue agent-actionable work;
create/link prerequisite work; supply human evidence; attest completion only
when justified) and links to an in-app operator guide
(`InboxController#partial_closeout_guide`) that explains, separately, what
completes a run, what resolves an Inbox item internally, and what closes a
GitHub issue or epic through a final PR — including that internal resolution
leaves GitHub open and that new terminal evidence can resurface the item, and
that audit completion, gap transfer, and epic acceptance are distinct
outcomes (a follow-up owner is not completed acceptance evidence; an explicit
scope revision preserves ownership of the outstanding requirement).

The resolve-complete attestation is editable: the pane collects a specific
completion rationale referencing evidence instead of posting a hidden canned
reason, and `Issues::ResolveCloseout` refuses the legacy canned sentence
structurally (no semantic approval heuristic). Actor and evidence-generation
digest recording is unchanged.

The continuation offer explains its authorization semantics: one run, other
holds still apply, and the reason should describe remaining work plus the
expected evidence (with short examples for fresh acceptance audits,
implementation gaps, scanner verification, and human-only evaluation). Human
prerequisites identify the requested evidence, who must supply it, how to
submit or link it, and what resumes automatically versus what requires a
deliberate continuation; agents are never retried for unavailable human
evidence.

Prerequisite linking is available from the pane (`link_prerequisite` on
`projects/agent_runs`): it appends `Depends on #N` wording to the stalled
issue via the project GitHub client and reuses `Issues::ParseDependencies` to
refresh local records immediately, showing the successful linkage and when a
full sync is still required — the same services the agent `create_issue` /
`edit_issue` tools use.

### Capability-aware technical prerequisite validation

An Inbox prerequisite that needs execution-environment evidence may offer a
bounded validation against a fresh, pinned `AgentRun`. Before it starts, the
action asks `Containers::BackendScheduler` for compatible execution hosts and
uses the existing runner/provisioner capability contract. It never treats the
control-plane browser or investigation workspace's Docker socket as evidence
about those hosts. The inspected host is persisted as the run's planned host,
so the container, its workspace volume, and its sidecars are created on the
daemon the capability decision approved instead of the local default.

The analyzer command is the reviewed recipe input, not an operator-provided
shell command. The attached marketplace tool is not a second recipe input: a
tool sidecar carries an image, a port, and its own environment, so the tool is
exercised by provisioning it through `Containers::McpProvisioner` and
publishing its endpoint to the analyzer. The validation provisions the normal
isolated environment, restores the pinned commit into the shallow clone
(the clone only carries the default-branch tip, so a commit pinned by an
earlier run is fetched before it is checked out), invokes the analyzer through
`execute_in_execution_environment`, records bounded stdout/stderr/exit status
plus pinned checkout, image, tool identity, sidecar endpoint, and cleanup
outcome, and then tears down both resources. Commands do not receive host
shell access or a Docker socket; existing image allowlists, network policy,
hardening profiles, and resource budgets remain authoritative.

The validation run is report-only. It carries its own goal, so it never
inherits the implementation-admission gate of an implementation goal — a
stalled issue whose feature intent is not released can still collect evidence
— and it is a synthetic operational run, so the agent execution queue never
dispatches it. Its lifecycle is the job that owns it: queued, running, then a
terminal state that a cancelled or failed run never overwrites. The executor
reloads that lifecycle state around provisioning and before command execution,
so cancellation stops work at the next external-operation boundary; its ensure
path still removes any workspace, container, or sidecar already provisioned.

Missing prerequisites are terminal evidence, not a retry cue. No compatible
backend yields a backend setup action. A disabled `marketplace_tool_sidecars`
flag yields the exact scoped pilot-authorization action; it is never enabled
by the validation. Denied images and missing credentials similarly retain the
provisioner's explicit rejection. Results are `unavailable`, `failed`, or
`completed` and are stored on the synthetic run plus a bounded latest-record
projection on its originating run's reconciliation data. That projection is
included in the closeout assessment source revision and in the next bounded
assessment's evidence, so a terminal validation invalidates stale criteria
without treating the result itself as acceptance. A changed checkout, image,
tool snapshot, or scope requires a fresh validation.

When a validation record is present, the partial-closeout Inbox pane shows its
latest outcome and exact setup action alongside the reviewed-recipe retry
control. The operator can therefore resolve an unavailable backend or rollout
authorization before rerunning it, rather than inferring remediation from a
stale acceptance assessment.

Pending chat write-tool confirmations visibly distinguish proposed/awaiting
confirmation, queued, refused, and completed actions, link a completed action
to the run it created, and a conversational message sent while a confirmation
is pending persists a durable notice stating it is not an approval and
nothing has run yet — a conversational "yes" is never displayed or recorded
as an executed action.

### Acceptance assessment evidence (#4186)

Each semantic partial-closeout assessment persists criterion states and its
source-evidence and approved-intent revisions on the originating run. The Inbox
and authorized chat context read that record and compare its revisions with
current deterministic evidence; they never call an LLM during rendering. A
revision mismatch is visibly stale, and missing evidence remains unknown.
Current owner state is resolved from the project-scoped issue record, so a
closed child cannot silently satisfy an unmet criterion. The assessment also
records a classification (`awaiting_final_audit`, `blocked_implementation`,
`missing_measured_results`, or `coordination_epic`) and a supported next action
that explains when open ownership makes another run duplicate work. A fresh
semantic assessment remains a bounded explicit `agent_harness` operation.

### Report-only acceptance audits (#4595)

When an assessment is missing or stale, Inbox offers a distinct **Run
acceptance audit** action. It uses the existing scoped-continuation admission
transaction, but records `acceptance_audit` in the request evidence and queues
an `analyze_issue` run rather than a `create_pr` run. The workflow recognizes
that persisted mode and invokes a dedicated audit activity which refreshes the
criterion assessment on the run and passes that snapshot through the
deterministic partial-closeout reconciler before completing the audit. The
reconciler records any follow-up owner or operator prerequisite as durable
evidence; the audit still does not create a follow-up run, change the issue
state, create a pull request, or authorize implementation. The normal
request/run lifecycle remains the durable progress, cancellation, failure, and
retry surface, and the existing one-open-request and active-run constraints
deduplicate audit requests for an evidence generation. Deduplication only
reuses an open request whose persisted mode and run goal match the requested
operation: a request that would authorize a different operation is refused with
the open authorization named, so an implementation continuation is never
reported as an acceptance audit and vice versa. All ordinary
continuation guards remain authoritative.

### Held-delivery reconciliation (#4614)

A merged delivery record may coexist with `manual_review`, including a
reopened issue or an enhancement/parser/transport stop. That hold is a human
decision boundary and is never cleared, but it must not erase the bounded
technical recovery path. The legacy reconciler therefore assesses an otherwise
eligible merged-delivery run behind manual review once and reuses
`PartialCloseouts::Reconcile` to record focused existing/new owners or a
specific human prerequisite. It leaves `paid_state`, `manual_review_reason`,
labels, rollout settings, closure, and ordinary dequeue eligibility unchanged.
The resulting terminal reconciliation status prevents no-change reassessment;
the existing manual-review Inbox entry remains the operator's action surface.

This is bookkeeping under the reconciler's existing project-scoped authority,
not closure or product-decision delegation. `needs_input`, pauses, untrusted
issues, non-open issues, and pull requests remain excluded. The assessment
continues to bind its criterion evidence to the current closeout digest and
issue-intent revision; a later explicit acceptance audit is required when
those revisions change.

## Alternatives considered

- *Lift the merged-PR guard via paid_state*: explicitly rejected — the guard is
  deliberately state-independent (#3432/#3588 review follow-up).
- *Blanket "clear blocker" action*: rejected by the issue; recovery actions are
  scoped (one continuation per request against one evidence generation).
- *Persisted inbox items*: the lane derives from evidence columns like
  `retry_limited` does; only the scoped authorization and the resolution
  dismissal are persisted.
