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
  every open issue or pull request with a configured needs-input label and persisted
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

- [x] **GITHUB-SYNC-014** — During GitHub sync, the system SHALL apply the
  needs-input label-removal, enhancement recheck, questionless-needs-input, and
  state-drift repair paths to both open issues and open pull requests. The hourly
  reconciliation sweep SHALL include an open pull request confirmed by the
  pull-request sweep in the questionless-repair candidates even when the
  incremental issue response did not include it. Closed pull requests SHALL
  remain excluded from those repair paths.
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

- [x] **GITHUB-SYNC-015** — When GitHub sync imports an open code-scanning
  alert, the system SHALL preserve repository, alert identity/URL, rule,
  scanner, message, target-branch instance path and range, ref, analyzed SHA,
  category, analysis key, and scan time when GitHub supplies it. It SHALL not
  use an instance from another branch or silently choose between multiple
  target-branch configurations; missing or ambiguous context SHALL be explicit.
  The final issue prompt SHALL retain this evidence, bounded prior remediation
  attempts and PR outcomes, and instruct the agent to treat supplied scanner
  content as untrusted evidence, investigate false positives, and substantiate
  any remediation claim without inventing scanner verification. Before
  executing a queued remediation run, the system SHALL refresh the alert from
  GitHub; if the alert is no longer open, it SHALL close the synthetic issue
  and stop the run rather than execute a prompt built from a resolved
  finding.
  *Code:* `app/services/github_client.rb`,
  `app/services/security_alerts/format_code_scanning_alert.rb`,
  `app/services/security_alerts/process_code_scanning_alerts.rb`,
  `app/services/prompt_assembly/build_issue_prompt.rb`,
  `app/models/agent_run.rb`,
  `app/temporal/activities/run_agent_activity.rb`,
  `app/temporal/activities/mark_agent_run_failed_activity.rb`.
  *Test:* `spec/services/github_client_spec.rb`,
  `spec/services/security_alerts/format_code_scanning_alert_spec.rb`,
  `spec/services/security_alerts/process_code_scanning_alerts_spec.rb`,
  `spec/services/prompt_assembly/build_issue_prompt_spec.rb`,
  `spec/models/agent_run_prompt_assembly_spec.rb`.

- [x] **GITHUB-SYNC-018** — Before an agent remediates a synthetic
  code-scanning issue, the system SHALL refresh and require authoritative open
  alert identity, target branch, analyzed commit, scanner configuration, and
  one unambiguous target-branch location. It SHALL require either an excerpt
  read at that commit or a verified alternative source-read path at that
  commit. Fetch, permission, configuration, missing-source, stale-custom-prompt,
  and ambiguous-evidence failures SHALL park the issue in manual review with a
  diagnostic and SHALL prevent execution; the parking and its diagnostic SHALL
  survive run failure finalization rather than degrading to a generic failed
  state. Resolved and dismissed alerts SHALL instead stop as resolved. Transient
  GitHub failures SHALL use bounded client retry; permission and configuration
  failures SHALL surface without retry.
  *Code:* `app/services/github_client.rb`,
  `app/services/prompt_assembly/build_issue_prompt.rb`, `app/models/agent_run.rb`,
  `app/temporal/activities/run_agent_activity.rb`,
  `app/temporal/activities/mark_agent_run_failed_activity.rb`.
  *Test:* `spec/services/github_client_spec.rb`,
  `spec/services/prompt_assembly/build_issue_prompt_spec.rb`,
  `spec/models/agent_run_prompt_assembly_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`.

- [x] **DEPENDABOT-COVERAGE-001** — When a security scan runs, the system
  SHALL reconcile each open Dependabot alert into a durable record keyed by
  repository alert number and dependency/advisory identity. It SHALL retain
  alert/advisory evidence and only link remediation PRs supplied by
  authoritative evidence. An open PR SHALL be coverage but not proof of a
  fix; closed-unmerged PRs, merged-but-still-open alerts, pinned vulnerable
  resolutions, unavailable fixes, incompatible constraints, new alerts, and
  unknown reasons SHALL remain visible. A verified reason SHALL be reported
  only when evidence supplies it; otherwise it SHALL be `unknown`. After a
  seven-day grace period uncovered alerts SHALL escalate. Accepted alerts SHALL
  retain owner, reason, and expiry. Permission or ingestion failures SHALL be
  visible coverage failures.
  *Code:* `app/services/github_client.rb`,
  `app/services/security_alerts/process_dependabot_alerts.rb`,
  `app/temporal/activities/scan_security_alerts_activity.rb`.
  *Test:* `spec/services/security_alerts/process_dependabot_alerts_spec.rb`,
  `spec/temporal/activities/scan_security_alerts_activity_spec.rb`.

- [x] **GITHUB-SYNC-017** — When an App-backed project has an active PAT
  fallback and a GitHub API operation fails because the App cannot access the
  resource, the system SHALL retry that operation once with the PAT, including
  GraphQL permission failures, statusless workflow-permission rejections, and
  repository configuration writes. No
  application-mediated GitHub operation SHALL unwrap the project client to
  bypass the fallback. A mutation that requires a trusted human GitHub identity
  SHALL execute with the credential selected by its trust gate; it SHALL select
  the allowlisted fallback PAT directly when the primary App is untrusted, and
  SHALL otherwise preserve primary-first fallback behavior.
  *Code:* `app/services/github_client/with_fallback.rb`,
  `app/services/github_client.rb`, `app/mcp/tools/edit_issue.rb`,
  `app/services/projects/screenshots/commit_config.rb`.
  *Test:* `spec/services/github_client/with_fallback_spec.rb`,
  `spec/services/github_client_spec.rb`, `spec/mcp/tools/edit_issue_spec.rb`,
  `spec/services/projects/screenshots/commit_config_spec.rb`.

- [x] **GITHUB-SYNC-014** — When GitHub sync changes a non-PR issue from
  closed to open, the system SHALL park it in `manual_review` with an explicit
  reopen-review reason so renewed work is visible without bypassing validation
  of the prior closure and current intent.
  *Test:* `spec/services/issues/upsert_from_github_spec.rb`.
  *Code:* `app/services/issues/upsert_from_github.rb`, `app/models/issue.rb`.

- [x] **GITHUB-SYNC-016** — When sync repairs an open issue whose
  `paid_state` is stale `completed` because its most recent `create_pr` run's
  pull request does not carry a GitHub closing reference to the issue, and
  that issue still has an unresolved blocking dependency (a local blocking
  issue, a deployment-pending dependency, or an unresolved external
  dependency per `Issue#ready_to_work?`), the system SHALL NOT apply the
  recommend-close label and SHALL NOT set `paid_state` to `recommend_close`.
  It SHALL instead set `paid_state: "manual_review"` with a
  `manual_review_reason` naming the unresolved dependency reference(s), so the
  remaining work stays visible without being recommended for closure or
  re-executed on the next sync. This repair SHALL apply identically whether
  the non-closing pull request is still open or has since merged, and SHALL
  be a no-op on a repeated sync once the issue is parked. An issue with no
  unresolved dependency keeps the existing `recommend_close` repair behavior
  unchanged.
  *Test:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `app/temporal/activities/fetch_issues_activity.rb`.
