---
parent: PAID
prefix: REPO-WORKFLOW-SCAN
---

# Low-Level Design: Repo Workflow Scan

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers GitHub Actions workflow security scanning in Paid's own
> repository CI.

## Purpose

Paid's own repository ships GitHub Actions workflows that check out PR
content, handle secrets, and run privileged jobs. A static analyzer for
workflow definitions catches classes of mistakes (credential persistence,
unpinned third-party actions, unsafe `pull_request_target` usage, template
injection into shell steps, unsafe `GITHUB_ENV` writes) before they reach
`main`, the same way Brakeman catches Rails-specific security mistakes.

## Scanner Contract

Workflow scanning uses a single pinned Zizmor CLI installation, installed the
same way as the repo's other pinned security tools (Gitleaks, ast-grep): a
`bin/install-<tool>` script that downloads a checksum-verified release binary
into the repo's ignored tooling area and prints its resolved path.

A thin wrapper (`bin/zizmor-scan`) resolves the binary and scans
`.github/workflows/`, relying on Zizmor's own exit code for pass/fail — the
same plain job-failure model the other `bin/audit` tools already use
(Brakeman, bundler-audit, yarn audit), rather than uploading SARIF to GitHub
code scanning.

## Findings Triage

Findings are triaged individually, not filtered wholesale:

- Genuine issues are fixed directly in the workflow (e.g. adding
  `persist-credentials: false`, pinning an action to a commit hash, avoiding
  unsafe `GITHUB_ENV` heredoc delimiters).
- Findings that are false positives for this repo's specific trust model
  (e.g. a `pull_request_target` trigger that never checks out untrusted PR
  head content, or a checkout step that intentionally persists credentials to
  push a commit) are suppressed narrowly in `.github/zizmor.yml`, scoped to
  the specific file and line, with a comment explaining why the finding does
  not apply.

## CI Integration

The `workflow-scan` job in `.github/workflows/security.yml` runs
`bin/zizmor-scan` on the same trigger/authorization gating as the rest of
`security.yml` (pull requests from trusted authors, pushes to `main`, and the
daily schedule).
