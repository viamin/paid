# EARS Specs: Repo Dependency Audit

> Testable claims for Paid's own JavaScript dependency audit (Yarn audit
> inside `bin/audit`). Status markers: `[x]` implemented · `[ ]` active gap
> · `[D]` deferred. Each ID is a grep target across specs, tests, and
> code (`grep -r REPO-DEPENDENCY-AUDIT-001`).

## Failure Policy

- [x] **REPO-DEPENDENCY-AUDIT-001** — When `bin/audit` runs `yarn audit`
  and Yarn reports one or more vulnerability findings that are not covered
  by an unexpired entry in `config/security/yarn-audit-allowlist.yml`, the
  wrapper SHALL exit non-zero and SHALL print the unmatched findings
  (advisory ID, severity, module, vulnerable path, recommendation) so the
  run is not silently green.
  *Tests:* `spec/scripts/audit_spec.rb`, `spec/scripts/yarn_audit_check_spec.rb`.
  *Code:* `bin/audit`, `bin/yarn-audit-check`.

- [x] **REPO-DEPENDENCY-AUDIT-002** — When `bin/audit` runs `yarn audit`
  and Yarn itself fails to complete (registry error, network error,
  invalid response, or any other non-zero exit that is not a clean
  advisory report), the wrapper SHALL exit non-zero with a message that
  distinguishes the scanner failure from a vulnerability finding. A
  scanner failure SHALL NOT be reported as "All security checks passed."
  *Tests:* `spec/scripts/audit_spec.rb`, `spec/scripts/yarn_audit_check_spec.rb`.
  *Code:* `bin/audit`, `bin/yarn-audit-check`.

## Allowlist

- [x] **REPO-DEPENDENCY-AUDIT-003** — When `bin/audit` reads
  `config/security/yarn-audit-allowlist.yml`, the wrapper SHALL reject
  entries missing any of `id`, `module`, `reason`, `owner`,
  `expires_on`, or `tracking_issue`; SHALL reject entries whose
  `expires_on` is in the past at run time; SHALL reject entries whose
  `id` is duplicated; and SHALL reject entries whose `id` does not match
  the GitHub advisory ID format (`^GHSA-[0-9a-z-]+$`). A malformed or
  expired allowlist SHALL fail the run before findings are evaluated.
  *Tests:* `spec/scripts/yarn_audit_check_spec.rb`.
  *Code:* `bin/yarn-audit-check`.

- [x] **REPO-DEPENDENCY-AUDIT-004** — When a Yarn audit finding's GitHub
  advisory ID and affected module match an unexpired allowlist entry, the wrapper SHALL
  report the finding as accepted (advisory ID, severity, module, expiry
  date, owner, tracking issue) in the run output and SHALL NOT fail the
  run for that finding. Accepted findings SHALL be visible in the CI
  summary so they are not silently waived.
  *Tests:* `spec/scripts/yarn_audit_check_spec.rb`.
  *Code:* `bin/yarn-audit-check`.

- [x] **REPO-DEPENDENCY-AUDIT-005** — `config/security/yarn-audit-allowlist.yml`
  is the only file consulted for Yarn audit exceptions; no blanket
  suppression for transitive or development dependencies is permitted.
  Entries MUST each cover a single advisory ID and MUST each cite a
  tracking issue or PR.
  *Tests:* `spec/scripts/yarn_audit_check_spec.rb`.
  *Code:* `bin/yarn-audit-check`, `config/security/yarn-audit-allowlist.yml`.

## CI Integration

- [x] **REPO-DEPENDENCY-AUDIT-006** — When the Security workflow runs
  `bin/audit`, the workflow SHALL fail on a non-zero exit from
  `bin/audit` (including a Yarn audit failure or scanner error) exactly
  as it already fails on a non-zero exit from `bin/brakeman` or
  `bin/bundler-audit`.
  *Code:* `.github/workflows/security.yml`.

## Package Manager

- [x] **REPO-DEPENDENCY-AUDIT-007** — Paid SHALL continue to use Yarn
  (`yarn audit`) as its JavaScript package manager and audit tool; this
  segment does not migrate the audit to `npm audit` or any other tool.
  *Code:* `bin/audit`, `package.json`.
