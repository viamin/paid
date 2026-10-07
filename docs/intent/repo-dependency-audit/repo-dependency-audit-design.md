---
parent: PAID
prefix: REPO-DEPENDENCY-AUDIT
---

# Low-Level Design: Repo Dependency Audit

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers JavaScript dependency auditing in Paid's own repository
> workflow, specifically the Yarn audit invocation that ships with
> `bin/audit` and runs in CI.

## Purpose

Paid's own repository must catch published npm advisories that are reachable
from the application's dependency tree. The repository already gates on
secret-content scans (`bin/secret-scan`), static Rails analysis
(`bin/brakeman`), and Bundler audit (`bin/bundler-audit`). The JavaScript
side of that gate was a `yarn audit || echo ...` invocation that swallowed
both vulnerability findings and scanner failures, so CI exited cleanly even
when Yarn audit reported dozens of advisories (run 37539231274 on
2026-10-06 is the cited evidence: 22 reported occurrences while CI was
"green").

This segment brings the JavaScript audit into the same shape as the rest of
`bin/audit`: real findings fail the run, scanner errors are reported as
distinct from findings, and the only way to keep a known finding green is a
specific, reviewed exception.

## Severity: `bin/audit` Failure Policy

`bin/audit` is the single mechanical suite for sensitive findings during local
runs and CI. It currently invokes:

- `bin/secret-scan --repo` — secret-content scanner (gitleaks)
- `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` — Rails
  static analysis
- `bin/bundler-audit` — Ruby gem advisory database
- `yarn audit` — npm advisory database (the focus of this segment)

Each of the first three returns a non-zero exit code when it finds an
unsuppressed issue, which fails `bin/audit` and the surrounding CI job.
Yarn audit previously did not: the legacy `yarn audit || echo ...` ignored
the exit code, so an empty advisory report and a registry outage both
resulted in "All security checks passed."

The policy is symmetric after this segment:

- **Scanner failure (registry, network, parse).** `yarn audit` did not
  complete its job. Report the failure separately from findings, do not
  count it as "passed," and fail the run. A scanner failure that we mask
  with a "passed" badge lets a real outage silently disable the audit.
- **Vulnerability findings without an exception.** Report each finding
  (advisory ID, severity, module, vulnerable path, recommendation), then
  exit non-zero. A green badge that hides open advisories is a misleading
  security control.
- **Findings covered by an exception.** Report the finding, list the
  exception that covers it, and exit zero. Exceptions are scoped to one
  advisory ID, require a rationale, owner, and expiry, and are checked for
  expiry and shape on every run.

## Exception Format

The repository ships a single allowlist file at
`config/security/yarn-audit-allowlist.yml`. The format is intentionally
narrow: each entry covers one advisory ID, one module name, and one
vulnerable version range, with rationale, owner, expiry, and review
metadata. Schema:

```yaml
# Yarn audit advisory exceptions.
#
# Each entry suppresses exactly one GitHub advisory that yarn audit
# continues to report after every other reasonable fix has been applied
# (overrides, dependency upgrade, patch release). The shape is required —
# an entry without rationale, owner, or expiry is rejected at run time and
# fails CI.
#
# Why allow some advisories at all? Some advisories are reported for
# transitive dependencies that we cannot reach through a pin, or for
# packages whose maintainer has not yet shipped a fix. The bar for adding
# an entry is "we have exhausted direct fixes and have accepted the risk
# for a bounded window." The bar for keeping one is "we re-checked during
# this window whether a fix exists."
#
# Format:
#   exceptions:
#     - id: GHSA-...                # GitHub advisory ID (required, unique)
#       module: <npm package name>  # affected module (required)
#       reason: <one-line rationale>  # required
#       owner: <GitHub team or @user>  # required, accountable for renewal
#       expires_on: YYYY-MM-DD        # required, ISO 8601
#       tracking_issue: <#1234>      # required, GitHub issue or PR
exceptions:
  - id: GHSA-vfj7-8cjw-p6xm
    module: braces
    reason: "No fix available upstream (patched_versions: '<0.0.0'); only reachable via @tailwindcss/cli>@parcel/watcher>micromatch>braces, a dev-only dependency. Reassess when @tailwindcss/cli ships a fix."
    owner: "@viamin/paid-frontend-platform"
    expires_on: 2026-12-31
    tracking_issue: "#4148"
```

The file is YAML so it can be parsed by anything that already loads
YAML in the repository, and so reviewers see structured entries rather
than opaque shell comments. The file path is fixed so `bin/audit` does
not have to discover a config.

## Run-Time Enforcement

The wrapper script `bin/audit` runs `yarn audit --json` and processes the
JSON stream itself rather than trusting the exit code alone. The script:

1. Captures the JSON output, ignoring progress noise, and reads every
   `auditAdvisory` event into an in-memory list of findings.
2. Validates the allowlist: each entry has `id`, `module`, `reason`,
   `owner`, `expires_on`, `tracking_issue`; each `expires_on` is a parseable
   ISO 8601 date and is not in the past; each `id` is unique; each `id`
   matches `^GHSA-[0-9a-z-]+$`. Any malformed or expired entry fails the
   run before findings are evaluated, so a stale exception cannot quietly
   keep a run green.
3. Classifies the run: error events and unparseable output fail the run
   as scanner failures, as does a non-zero exit that produced no advisory
   report. A non-zero exit with advisory events is a normal report, not a
   scanner failure — yarn exits 1 whenever it reports advisories.
   Advisory findings are accepted only when both their advisory ID and
   affected module match an unexpired allowlist entry; everything else fails
   the run.
4. Prints a structured summary (counts, accepted findings with expiry,
   blocking findings) so the CI log and the local run show the same
   surface area, and (when `YARN_AUDIT_ACCEPTED_REPORT` is set) writes
   the accepted rows as JSON for the CI step summary.

## CI Integration

`.github/workflows/security.yml` runs `bin/audit` on pull requests from
trusted authors, on pushes to `main`, and on the daily schedule. The job
fails on a non-zero exit from `bin/audit` exactly as it already fails on
a non-zero exit from `bin/brakeman` or `bin/bundler-audit`. The audit
step exports the accepted (allowlisted) advisories to a JSON report via
the `YARN_AUDIT_ACCEPTED_REPORT` environment variable, and the summary
step renders those rows — advisory ID, package, severity, expiry, owner,
tracking issue — as a table in `$GITHUB_STEP_SUMMARY` so accepted
findings are visible without digging through the job log
(REPO-DEPENDENCY-AUDIT-004). Full finding detail (titles, vulnerable
paths, recommendations) stays in the job log under `== Yarn audit ==`.

## What This Segment is Not

- **Not a wrapper for `bin/secret-scan`, `bin/brakeman`, or
  `bin/bundler-audit`.** Each of those has its own segment.
- **Not a general-purpose dependency audit policy.** The format and
  contract are written for `yarn audit`'s event stream. A future Ruby or
  Go audit can adopt the same shape, but is out of scope here.
- **Not a substitute for upstream fixes.** Every entry in the allowlist
  must reference a tracking issue and an expiry date. Adding an entry
  is a stop-gap while a real fix is being pursued, not a permanent
  suppression.
