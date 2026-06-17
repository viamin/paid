# GitHub App Installation Tokens — Migration & Rollout Plan

> Relates to issue #2408 (follow-up to the #2404 rate-limit audit) and
> [RDR-030](rdrs/RDR-030-github-app-bot-account.md).

## Why migrate

Paid historically authenticates every GitHub API call with a single
per-account **Personal Access Token** (`GithubToken`). All projects in an
account share that one token's **5,000 requests/hour** budget, so an
account tips into rate-limit territory around two projects with active
PRs.

GitHub App installations are rate-limited **per installation** at
**15,000 requests/hour** (roughly 3× the headroom), and each installation
is isolated — one account's polling never consumes another account's
budget. Migrating polling/scan traffic onto installation tokens removes
the cross-project and cross-account quota collision.

## What already exists

The codebase already supports both auth paths end to end:

- **`Github::AppInstallation.token_for`** — mints and caches (50 min TTL)
  a `paid-agents` App installation token scoped to a single repo.
- **`GithubInstallation`** model — per-account record of an App install
  (`account_login`, `repository_selection`, `accessible_repositories`,
  `suspended_at`/`revoked_at`).
- **`Project#client` / `Project#github_credential`** — resolves to an
  installation token when `github_installation_id` is set, otherwise the
  PAT. Callers are auth-path agnostic.
- **`Github::MigrationService`** — moves a project (or all projects on a
  token) from PAT to an installation, with access checks and an audit
  trail (`Github::MigrationService.migrate_project` /
  `migrate_from_token`).
- **Routing** — `FetchIssuesActivity`, `ScanPaidPrsActivity`,
  `ScanSecurityAlertsActivity`, and `CheckRateLimitActivity` all go
  through `project.client`, so they already run on installation tokens
  for app-backed projects and fall back to the PAT otherwise.

Issue #2408 built on top of this foundation. It did **not** introduce a
separate `paid-poller` App: the existing `paid-agents` App already carries
the read scopes (`issues`, `pull_requests`, `contents`, `metadata`,
`checks`, `code_scanning`/`security_events`) needed for polling and
scanning, and routing both reads and writes through one installation keeps
a single quota and identity per repo. The separate `paid-code-reviewer`
App is retained only for review-posting, as documented in RDR-030.

## What #2408 added

- **Per-credential rate-limit observability.** `GithubHealthState` now
  records the last-observed `remaining` / `limit` / `reset_at` for each
  credential endpoint (per installation and per token). `CheckRateLimitActivity`
  samples these once per poll cycle; rate-limit errors capture them too.
- **Dashboard widget.** A new **GitHub Credential Health** panel
  (`GET /dashboard/github_health`) lists every App installation and PAT for
  the account with its auth source, status (available / rate-limited /
  circuit-open / recovering), quota used %, and remaining budget — so
  per-installation usage is observable at a glance.

## Operator migration runbook

### 1. Configure the `paid-agents` App

Set the App credentials (SaaS uses the canonical app; self-hosters use the
manifest flow described in RDR-030):

- `PAID_AGENT_APP_ID` (or the `paid_agent_app_id` Rails credential)
- `PAID_AGENT_APP_PRIVATE_KEY` (PEM, PKCS#1 or PKCS#8 — not OpenSSH)

Confirm with `Github::AppRegistry.configured?` in a console. The App must
grant the repository read permissions listed in RDR-030 (Contents, Pull
requests, Issues, Metadata, Checks, Commit statuses) plus
`code_scanning`/`security_events` read for security-alert scanning.

### 2. Record the installation

When a customer installs the App, persist a `GithubInstallation` for the
account (installation id, `account_login`, `target_type`,
`repository_selection`, `accessible_repositories`). `covers_repository?`
is used by the migration service to verify access before flipping a
project.

### 3. Migrate projects (PAT → installation)

Single project:

```ruby
Github::MigrationService.migrate_project(
  project: project,
  github_installation: installation,
  actor: current_user
)
```

All projects on a token at once:

```ruby
result = Github::MigrationService.migrate_from_token(
  github_token: token,
  github_installation: installation,
  actor: current_user
)
result.each_failed { |r| warn "#{r.project.full_name}: #{r.error}" }
```

Pre-flight access check (no mutation):

```ruby
Github::MigrationService.check_accessibility(
  github_token: token,
  github_installation: installation
)
```

Migration flips `github_installation_id` on, `github_token_id` off,
invalidates the repo cache, and records account activity. Polling resumes
on the next cycle using the installation token automatically.

### 4. Verify on the dashboard

Open the dashboard. The **GitHub Credential Health** panel should show the
installation as `App` / `Available`, and after one poll cycle its
**Quota Used** / **Remaining** columns populate against the 15,000/hr
budget. The old PAT row remains only for projects not yet migrated.

## PAT retirement over time

PAT is **not** hard-deprecated — it stays as the documented fallback for
GitHub Enterprise Server without App reachability, locked-down orgs that
can't install third-party apps, and break-glass when an App is suspended.
Retirement is staged:

1. **Phase A — App supported, PAT default (current steady state).** Both
   paths work; existing projects untouched. Operators opt projects in via
   the migration service. Use the dashboard to confirm quotas no longer
   collide after migration.
2. **Phase B — App recommended.** New projects default to App auth when
   `Github::AppRegistry.configured?`. Surface an in-product nudge on
   PAT-backed projects; migrate account-by-account using
   `migrate_from_token`. Track remaining PAT count on the dashboard.
3. **Phase C — PAT retained as fallback only.** No forced cutover. Tokens
   with no remaining projects can be revoked (`GithubToken#revoke!`).
   Per-token health rows become inert once no project references them.

Because rate-limit health is keyed per credential endpoint, retiring a PAT
never affects installation-backed projects, and vice versa.

## Verification checklist

- [ ] `Github::AppRegistry.configured?` is true in the target environment.
- [ ] Migrated project's PRs are authored by `paid-agents[bot]`.
- [ ] Dashboard **GitHub Credential Health** shows the installation with
      non-zero `15,000/hr` budget after a poll cycle.
- [ ] A rate-limit event on one installation does not pause an
      unrelated installation or PAT (per-endpoint isolation).
- [ ] Existing PAT-backed projects continue polling unchanged.

## References

- [RDR-030](rdrs/RDR-030-github-app-bot-account.md) — App architecture and
  permissions.
- [`app/services/github/migration_service.rb`](../app/services/github/migration_service.rb)
- [`app/services/github/app_installation.rb`](../app/services/github/app_installation.rb)
- [`app/models/github_health_state.rb`](../app/models/github_health_state.rb)
- [`app/services/dashboard/github_health.rb`](../app/services/dashboard/github_health.rb)
