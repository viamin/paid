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
