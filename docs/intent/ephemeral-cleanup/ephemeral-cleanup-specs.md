# EARS Specs: Ephemeral Cleanup

> Testable claims for cleanup pull requests. Each ID is a grep target across
> specs, tests, and implementation (`grep -r EPHEMERAL-CLEANUP-001`).

- [x] **EPHEMERAL-CLEANUP-001** — When the Ephemeral Cleanup workflow finds
  stray ephemeral-test files and creates its cleanup pull request, it SHALL
  create that pull request with both `paid-automation` and `paid-generated`
  labels using a token with issue-label write permission, and SHALL fail before
  requesting auto-merge if applying either label fails. When it finds no stray
  files, it SHALL continue to create no pull request.
  *Code:* `.github/workflows/ephemeral-cleanup.yml`.
  *Test:* `spec/config/ephemeral_cleanup_workflow_file_spec.rb`.
