---
parent: PAID
prefix: REPO-SECRET-SCAN
---

# Low-Level Design: Repo Secret Scan

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers secret-content scanning in Paid's own repository workflow.

## Purpose

Paid's own repository workflow must block newly introduced credentials before
they reach history or merge. The repository already enforces artifact, lint,
and dependency-audit checks, but without a content scanner a developer can
still commit a token-shaped string into tracked files.

## Shared Scanner Contract

Repository secret scanning uses a single pinned Gitleaks CLI installation path
and a shared wrapper script. Local hooks and CI call that wrapper instead of
duplicating Gitleaks command lines in multiple places. This keeps the scanner
version, invocation flags, and failure messaging aligned across environments.

The wrapper exposes two mechanical scan modes:

- staged changes for the host pre-commit hook, so commits fail before the
  secret lands in local history
- repository contents for the security audit path, so every PR and `main`
  push re-runs the scan in CI

## Provisioning

The repository bootstrap path installs the pinned scanner version ahead of
time, but the shared wrapper remains self-sufficient and can install the
scanner when it is missing. The installation target stays under the repo's
ignored temp/tooling area so the binary never becomes a tracked artifact.
