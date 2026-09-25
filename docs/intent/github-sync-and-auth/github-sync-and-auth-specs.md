# EARS Specs: GitHub Sync and Auth

> Testable claims for GitHub polling, caching, and credential resolution.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r GITHUB-SYNC-001`).

- [x] **GITHUB-SYNC-001** — When an active project is connected to GitHub, the
  system SHALL run a polling workflow that repeatedly fetches GitHub issues,
  reconciles them into Paid's local issue state, and advances an incremental
  sync watermark so future polls do not reprocess the entire repository.
  *Code:* `app/services/project_workflow_manager.rb`,
  `app/temporal/workflows/git_hub_poll_workflow.rb`,
  `app/temporal/activities/fetch_issues_activity.rb`.
  *Test:* `spec/services/project_workflow_manager_spec.rb`,
  `spec/temporal/activities/fetch_issues_activity_spec.rb`.

- [x] **GITHUB-SYNC-002** — When GitHub sends issue, PR, review, comment, or
  push webhooks for a known project, the system SHALL invalidate the matching
  cached GitHub objects so subsequent reads refresh the affected issue, pull
  request, or repository metadata without waiting for a full cache expiry.
  *Code:* `app/services/github/cache_invalidator.rb`.
  *Test:* `spec/services/github/cache_invalidator_spec.rb`.

- [x] **GITHUB-SYNC-003** — When a project resolves its GitHub credential, the
  system SHALL return an installation token for an active App-backed project,
  SHALL return the PAT for an active PAT-backed project, and SHALL return `nil`
  for inactive or missing credentials rather than falling back silently.
  *Code:* `app/models/project.rb`.
  *Test:* `spec/models/project_spec.rb`.

- [x] **GITHUB-SYNC-004** — When the GitHub App install callback arrives with a
  verified state token or an operator-owned self-hosted setup redirect, the
  system SHALL persist a `PendingInstallClaim` for the `(account,
  installation_id)` pair and SHALL enqueue `Github::Installations::SyncJob`;
  callbacks without a trusted signal SHALL not create a claim.
  *Code:* `app/controllers/github_app/installations_controller.rb`,
  `app/models/pending_install_claim.rb`.
  *Test:* `spec/requests/github_app/installations_spec.rb`.

- [x] **GITHUB-SYNC-005** — When `Github::Installations::SyncJob` processes an
  App callback, the system SHALL bind the installation only when a trusted
  server-side signal exists (active claim, existing installation row, or
  project-owner match) and SHALL otherwise refuse the bind so the signed
  webhook remains the authoritative recovery path.
  *Code:* `app/jobs/github/installations/sync_job.rb`.
  *Test:* `spec/jobs/github/installations/sync_job_spec.rb`.

- [x] **GITHUB-SYNC-006** — When a signed GitHub App installation webhook is
  received, the system SHALL verify the webhook secret, resolve the owning
  account conservatively, persist installation lifecycle and repository-grant
  changes, and consume any matching active `PendingInstallClaim` once the local
  `GithubInstallation` row is established.
  *Code:* `app/controllers/api/github_app/webhooks_controller.rb`,
  `app/services/github/installations/account_resolver.rb`,
  `app/services/github/installations/upserter.rb`.
  *Test:* `spec/requests/github_app/webhooks_spec.rb`.

- [x] **GITHUB-SYNC-007** — When an operator configures a self-hosted GitHub
  App through the manifest flow, the system SHALL generate an install manifest,
  exchange GitHub's one-time setup code for App credentials, and SHALL either
  persist those credentials or surface the one-time manual instructions instead
  of discarding them.
  *Code:* `app/controllers/admin/github_app/setup_controller.rb`.
  *Test:* `spec/requests/admin/github_app/setup_spec.rb`.

- [x] **GITHUB-SYNC-010** — When a browser-initiated GitHub App install or
  self-hosted manifest registration redirect is emitted, the system SHALL
  construct only `https://github.com` destinations for the expected GitHub App
  install or manifest paths, and SHALL fail closed instead of redirecting to
  any other host or path.
  *Code:* `app/controllers/github_app/installations_controller.rb`,
  `app/controllers/admin/github_app/setup_controller.rb`,
  `app/services/github/app_registry.rb`.
  *Test:* `spec/requests/github_app/installations_spec.rb`,
  `spec/requests/admin/github_app/setup_spec.rb`,
  `spec/services/github/app_registry_spec.rb`.

- [x] **GITHUB-SYNC-008** — When the hourly issue reconciliation runs, the
  system SHALL re-fetch and re-upsert every locally-open issue whose
  `github_updated_at` predates the watermark and has not been reconciled since
  its last GitHub update, so that missed label changes (e.g., a skip label
  removed on GitHub) are corrected without waiting for the issue to be updated
  on GitHub. Each issue SHALL be reconciled at most once per change; the
  system tracks a per-issue `reconciled_at` timestamp so that issues already
  verified are not re-fetched on subsequent cycles. Per-issue API failures
  SHALL be logged and SHALL NOT abort the full sync.
  *Code:* `app/temporal/activities/fetch_issues_activity.rb`.
  *Test:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.

- [x] **GITHUB-SYNC-009** — When a project is read through the chat-accessible
  project-details surface, the system SHALL expose sanitized GitHub
  credential/webhook diagnostics for that project, including credential mode,
  installation or PAT health, webhook-secret presence, PAT push-fallback
  status, recent permission-related failure reason codes/messages, and a next
  recommended action for common blockers, while excluding raw tokens, webhook
  secrets, installation tokens, request bodies, stack traces, and cross-tenant
  data.
  *Code:* `app/services/projects/github_diagnostics.rb`,
  `app/mcp/tools/get_project.rb`.
  *Test:* `spec/services/projects/github_diagnostics_spec.rb`,
  `spec/mcp/tools/get_project_spec.rb`.

- [x] **GITHUB-SYNC-011** — When callers use the plain repository/issue/git
  operations exposed by `GithubClient`, the system SHALL provide those
  pass-throughs through one delegated wrapper that preserves `GithubClient`'s
  error translation contract, so the class does not duplicate per-method
  Octokit rescue boilerplate while callers still receive `GithubClient::*`
  errors rather than raw Octokit exceptions.
  *Code:* `app/services/github_client.rb`.
  *Test:* `spec/services/github_client_spec.rb`.

- [x] **GITHUB-SYNC-012** — During GitHub sync, the system SHALL reconcile
  every open, non-PR issue with a configured needs-input label and persisted
  clarification questions whose `paid_state` has drifted away from
  `needs_input`, restoring `needs_input` and logging the repair unless a
  paused `create_feature` run with a recorded clarification round still owns
  that wait. This makes the existing inbox answer flow authoritative for
  orphaned clarification gates, including rows absent from an incremental
  response (#3992). When a trusted user applies a needs-input label to an item
  without persisted clarifying questions, the sync SHALL instead remove that
  orphaned label, leave the item's Paid state unchanged, post an explanation of
  the supported flows, and log the cleanup. Labels last applied by Paid or an
  untrusted user SHALL remain untouched (#3988). Historical reconciliation
  SHALL use bounded batches and persist a completed evaluation so normal polls
  do not repeatedly fetch unchanged issues' label-event histories.
  *Code:* `app/temporal/activities/fetch_issues_activity.rb`.
  *Test:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.

- [x] **GITHUB-SYNC-013** — When a signed GitHub `issues` webhook reports an
  `edited` or `reopened` action, the system SHALL evaluate the webhook sender
  against the project's explicit case-insensitive human GitHub allowlist. The
  implicit Paid App bot identity SHALL NOT grant human mutation trust. A
  webhook sender that matches the project's own App bot identity SHALL instead
  be recognized as an autonomous Paid-originated mutation and preserved. Before
  a chat `edit_issue` tool call writes, the system SHALL require its GitHub
  credential to authenticate as an allowlisted human, and SHALL reject an App
  bot or unknown credential. For an allowlisted webhook sender, the system
  SHALL preserve the GitHub issue state; for any other sender, it SHALL close
  the issue through the project credential, post an explanatory comment naming
  the allowlist and appeal path, and record an audit event and structured log
  with the sender, trust result, Paid-origin flag, action, and allow/close
  decision.
  *Code:* `app/controllers/api/github_webhooks_controller.rb`,
  `app/services/issues/enforce_mutation_trust.rb`,
  `app/mcp/tools/edit_issue.rb`.
  *Test:* `spec/services/issues/enforce_mutation_trust_spec.rb`,
  `spec/requests/api/github_webhooks_spec.rb`,
  `spec/mcp/tools/edit_issue_spec.rb`.

- [x] **GITHUB-SYNC-014** — When GitHub sync changes a non-PR issue from
  closed to open, the system SHALL park it in `manual_review` with an explicit
  reopen-review reason so renewed work is visible without bypassing validation
  of the prior closure and current intent.
  *Test:* `spec/services/issues/upsert_from_github_spec.rb`.
  *Code:* `app/services/issues/upsert_from_github.rb`, `app/models/issue.rb`.
