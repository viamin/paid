# EARS Specs: Repo Secret Scan

> Testable claims for Paid's own repository secret-content scan. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r REPO-SECRET-SCAN-001`).

## Local Commit Guard

- [x] **REPO-SECRET-SCAN-001** — When a developer runs the host pre-commit
  hook with staged changes, the hook SHALL run the shared secret-scan wrapper
  in staged mode before linting and SHALL block the commit when the scan
  reports a finding.
  *Tests:* `spec/scripts/pre_commit_hook_spec.rb`,
  `spec/scripts/secret_scan_spec.rb`.
  *Code:* `.githooks/pre-commit`, `bin/secret-scan`.

## CI Audit Guard

- [x] **REPO-SECRET-SCAN-002** — When the repository runs its security audit
  path locally or in CI, the shared secret-scan wrapper SHALL scan repository
  contents with the pinned Gitleaks CLI so PR and branch audits evaluate the
  same rule set.
  *Tests:* `spec/scripts/secret_scan_spec.rb`.
  *Code:* `bin/secret-scan`, `bin/audit`.

## Bootstrap Provisioning

- [x] **REPO-SECRET-SCAN-003** — When a developer runs `bin/setup`, the setup
  script SHALL install the pinned Gitleaks CLI into the repository's ignored
  tooling area before the hook is likely to need it.
  *Tests:* `spec/lib/setup_script_spec.rb`.
  *Code:* `bin/setup`, `bin/install-gitleaks`.
