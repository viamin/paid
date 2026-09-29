# Design: Upstream Pull Requests

When a fork-backed Paid project chooses `pr_target: upstream`, Paid opens its
draft pull requests in the configured upstream repository. The branch remains
in the fork, so GitHub receives the head as `fork_owner:branch`.

The upstream default branch is fetched through the repositories API and cached
for one hour using the project version and upstream name as the cache key.
Changing either project setting changes that key and invalidates the cache.

An App installation limited to the fork often cannot use the upstream API.
For upstream PRs Paid therefore uses the existing, opt-in git-push fallback
PAT client when configured. If GitHub still returns 401/403, the run fails
non-retryably with an actionable configuration error; it never silently opens
a fork PR instead.

The upstream PR is synced as a local `Issue` with source
`upstream_pull_request`. PR scanning is limited to local-repository rows, so
upstream PRs are visible through their saved URL but are not enrolled in
follow-up automation.
