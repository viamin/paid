---
parent: PAID
prefix: GITHUB-SYNC
---

# Low-Level Design: GitHub Sync and Auth

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the shipped GitHub polling, cache, and credential posture
> that grew out of RDR-012 and RDR-030.

## Purpose

Paid's GitHub integration now spans two responsibilities that must stay
coherent:

- repository polling and local issue/PR state refresh for automation
- repository credentials and bot identity for reads, writes, and webhooks

This segment records the current brownfield contract after the App rollout. The
original PAT-only assumptions in RDR-012 were superseded by RDR-030, but PAT
fallback remains a supported path for projects that cannot use the App.

## Shipped behavior

The current implementation is polling-first. Each active project runs a durable
GitHub poll workflow that repeatedly fetches issues, reconciles local state,
and drives downstream automation. Webhooks complement that loop by invalidating
cache entries and updating App-installation lifecycle state, but the product
does not depend on webhooks as the sole source of truth for issue discovery.

Issue and PR state is cached locally at multiple layers:

- issues are synchronized into Paid's `issues` table during polling
- poll progress advances by `last_issue_sync_at` watermarks for incremental sync
- request-time API objects such as issues, pull requests, and repo metadata use
  cache invalidation keyed by GitHub webhook event type

Code-scanning alerts are represented as synthetic issues, but their remediation
context is not reduced to a rule title. Sync selects instances matching the
project's target branch explicitly. It retains the alert identity, rule/tool,
message, location range, ref, analyzed commit, category, and analysis key. If
there are no target-branch instances or more than one configuration supplies a
candidate, that ambiguity is rendered as insufficient context rather than
silently using an arbitrary most-recent instance. Scanner timestamps are scan
identity when supplied by GitHub; alert update timestamps are never presented
as scan freshness. The rendered issue carries bounded, untrusted evidence and
prior run/PR outcomes into the final agent prompt. Agents must compare a
historical location to their checkout, investigate false-positive status, and
must not claim scanner resolution without supporting verification.

## Code-scanning coverage

Code-scanning discovery has a default 24-hour cadence (configurable per
project) and a 24-hour discovery-latency target after a healthy project is
activated. A completed response, including a valid empty alert list, is the
only event that advances the successful-scan watermark. Each fetch separately
records its attempt time, its durable failure kind/reason, and the earliest
retry time. This prevents a 404 or another unavailable response from looking
like a clean snapshot.

Failures use bounded, failure-specific retries: permission and unavailable
configuration failures retry in one hour; rate limits retry at GitHub's reset
time (or in five minutes if it is absent); transient API failures retry in five
minutes. Disabled activation and a project that has not enabled the
`code_scanning` alert type are coverage states, not empty findings. Operators
see those states, unavailable failures, and stale/never-completed coverage on
the project health surface.

Verification of an awaiting remediation does not wait for the general
discovery cadence: while an attempt awaits verification, the next successful
coverage check is eligible after one hour. Failure backoff always takes
precedence over that verification cadence.

When sync observes a non-PR issue transition from closed back to open, it
resets Paid's internal state to `new`. This makes GitHub's reopened state the
authoritative renewal signal and prevents a prior completion or recommendation
from masking work that is open again.

Signed `issues` webhooks are the authoritative attribution point for externally
initiated issue lifecycle mutations. When GitHub reports that an issue was
reopened or edited, Paid evaluates the webhook sender against the project's
explicit, case-insensitive human GitHub allowlist. The project's implicit Paid
App bot identity is deliberately excluded from human mutation authority, but a
sender matching that identity is recognized as an autonomous Paid write and
preserved. Chat issue edits require a credential authenticated as an allowlisted
human before they write, so a chat user cannot use the Paid App bot identity to
bypass the allowlist. A sender that is neither allowlisted nor the project's App
bot causes Paid to close the issue through the project credential, post a fixed
explanation with an appeal path, and record an audit event containing the
sender, trust result, Paid-origin flag, action, and decision. This keeps an
untrusted reopen or body edit from becoming an automation back door while
allowing authorized Paid writes to complete without re-closing themselves.

Needs-input is a human-answer gate represented by a GitHub label, persisted
clarification questions, and local `paid_state`. Polling reconciles every open
issue or pull request that still has both the label and questions if another
writer has changed its state, restoring `needs_input` unless a paused
clarification run still owns the wait. This also repairs rows that incremental
GitHub polling did not return. Removing the label remains the inverse human
signal that reopens the item for automation. A questionless needs-input item is
repaired by clearing its invalid labels and leaving the wait state, so it cannot
remain invisible in the Inbox and ineligible for automation.

Paid-owned status labels are not operator commands. When a trusted operator
manually applies a needs-input label to an item without persisted clarifying
questions, sync removes the orphaned label, leaves local state intact, and
posts the supported paths: answer Inbox questions, re-trigger automation, or
use `paid-paused` to pause automation. The last label adder is verified through
GitHub label events so Paid writes and untrusted additions remain untouched.

Repository credentials resolve per project. App-backed projects mint
installation tokens and present the App bot identity; PAT-backed projects keep
using their active token. Callers consume an opaque GitHub credential so the
read/write path does not branch on auth mode.

The runtime `GithubClient` surface intentionally separates two kinds of
operations. Methods that add Paid-specific behavior stay explicit on the class
(pagination control, payload shaping, compare summaries, GraphQL helpers,
health-state recording). The plain Octokit pass-throughs stay on a delegated
wrapper that applies the same error translation contract, so callers keep a
small, stable API without duplicating rescue boilerplate throughout the class.

Project-scoped GitHub diagnostics are exposed as a sanitized read model for
customer users and chat agents. The diagnostics report derived facts only:
credential mode, installation/token health, whether the project webhook secret
is configured, whether PAT push fallback is configured and still active, recent
permission-rejection reason codes/messages, and the next recommended operator
or project-owner action for common blockers such as missing `workflows`
permission or a missing webhook secret. The surface intentionally excludes raw
tokens, webhook secrets, installation tokens, request payloads, stack traces,
and host-level logs.

GitHub App installation binding is intentionally conservative. The browser
callback proves user intent only after state verification or an operator-owned
self-hosted setup path. The actual install-to-account association is finalized
only when there is a server-trusted signal such as a `PendingInstallClaim`, an
existing installation row, or a confident account match. Signed installation
webhooks persist lifecycle changes and repository grants, then consume the
claim once the local `GithubInstallation` row becomes authoritative.

Self-hosted deployments configure their own App through the operator-only
manifest flow under `/admin/github_app/setup`. That flow exchanges GitHub's
one-time setup code, persists credentials when possible, and otherwise surfaces
the one-time secret material for manual completion.

Browser redirects in the App install/setup flows are hard-pinned to
`https://github.com` and the expected GitHub App paths. If an internal URL
builder ever produces any other destination, the controller fails closed rather
than emitting the redirect.

## Completed-open issue repair

`repair_completed_open_issues` guards against reading a `create_pr` run's
terminal `completed` status as proof the source issue's acceptance criteria
are met. Each sync re-checks open issues still carrying Paid's
`paid_state: "completed"` whose most recent `create_pr` run recorded a pull
request: if an open PR produced by that run carries a GitHub closing
reference to the issue, the completed state stands. Otherwise GitHub's own
signal says the implementation is partial, and the stale `completed` state is
repaired.

A partial implementation still blocked by an unresolved dependency — an open
local blocking issue, a deployment-pending dependency, or an unresolved
external dependency, the same blocking rule `Issue#ready_to_work?` already
applies to Auto-Pick eligibility — is never recommended for closure. A
completed agent run does not establish that remaining, intentionally
deferred work is done, and labeling the issue `paid-recommend-close` would
ask a human to park legitimate work based on PR bookkeeping rather than
evidence of completion. Instead the issue is parked in
`paid_state: "manual_review"` with a `manual_review_reason` naming the
unresolved dependency, reusing the same human-visible, non-looping parking
lane the rest of the system uses for other automation stops (see
`IssueEnhancements::StopForManualReview`). Dependency resolution already
unblocks the issue for Auto-Pick through the existing dependency-state
checks; nothing about this repair path re-polls on a timer.

A partial implementation with no outstanding dependency keeps the existing
behavior: it is recommended for closure (`paid_state: "recommend_close"`,
mirrored to GitHub's `paid-recommend-close` label) because there is no
further deterministic signal to wait on, so a human is asked to confirm. The
repair reuses the sync's already-resolved `GithubClient` rather than opening
a second credential for the cycle.

## Projects V2 abandonment

RDR-012 originally included a GitHub Projects V2 branch. As of the 2026-07-09
RDR revision, that branch is intentionally abandoned and superseded by Paid's
native issue graph:

- `Issue#parent_issue_id` / `sub_issues`
- `IssueDependency`
- `ChangeIntent`
- local workflow state fields and labels

This segment therefore does **not** carry a `[ ]` gap for Projects V2 field or
item synchronization. Reintroducing a second hierarchy source of truth would
conflict with the local issue graph that already shipped.

## What this is not

- **Not webhook-first issue detection.** Webhooks accelerate freshness and App
  lifecycle reconciliation, but polling remains the durable issue-discovery
  path.
- **Not App-only auth.** PAT remains a supported fallback when a deployment or
  repository cannot use the GitHub App.
- **Not GitHub Projects V2 sync.** That path is deliberately closed rather than
  deferred.
