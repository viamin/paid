# EARS Specs: Upstream Pull Requests

- [x] **UPSTREAM-PR-001** — When a project selects `pr_target: upstream`, it
  SHALL require an upstream repository name.
  *Code:* `app/models/project.rb`.

- [x] **UPSTREAM-PR-002** — When Paid creates an upstream PR, it SHALL use the
  upstream repository, its cached default branch, and `fork_owner:branch` as
  the head, and SHALL create the PR as a draft.
  *Code:* `app/temporal/activities/create_pull_request_activity.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.

- [x] **UPSTREAM-PR-003** — When retrying an upstream PR creation, Paid SHALL
  look up an open PR in the upstream repository using the qualified head.
  *Code:* `app/temporal/activities/create_pull_request_activity.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.

- [x] **UPSTREAM-PR-004** — When access to the upstream repository is denied
  or unavailable, Paid SHALL use the configured fallback PAT when available
  and otherwise fail explicitly; it SHALL NOT silently create a fork PR.
  This includes creation, existing-PR lookup, default-branch lookup, and PR
  synchronization. Upstream PR records SHALL be excluded from local PR
  scanning.
  *Code:* `app/temporal/activities/create_pull_request_activity.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`.
  *Test:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.
