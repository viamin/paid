# EARS Specs: Repo Workflow Scan

> Testable claims for Paid's own GitHub Actions workflow security scan.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r REPO-WORKFLOW-SCAN-001`).

## CI Scan Guard

- [x] **REPO-WORKFLOW-SCAN-001** — When the repository runs its workflow
  security scan locally or in CI, the shared wrapper SHALL run the pinned
  Zizmor CLI against `.github/workflows/` and SHALL exit successfully when
  Zizmor reports no unsuppressed findings.
  *Tests:* `spec/scripts/zizmor_scan_spec.rb`.
  *Code:* `bin/zizmor-scan`, `.github/workflows/security.yml`.

- [x] **REPO-WORKFLOW-SCAN-002** — When Zizmor reports a workflow security
  finding that is not suppressed in `.github/zizmor.yml`, the wrapper SHALL
  exit with a non-zero status and print guidance to fix the finding or add a
  narrow, justified suppression.
  *Tests:* `spec/scripts/zizmor_scan_spec.rb`.
  *Code:* `bin/zizmor-scan`.

## Bootstrap Provisioning

- [x] **REPO-WORKFLOW-SCAN-003** — When the pinned Zizmor binary is not
  already installed at its target version, `bin/install-zizmor` SHALL
  download the checksum-verified release binary for the current OS/arch into
  the repository's ignored tooling area and print its resolved path.
  *Code:* `bin/install-zizmor`.
