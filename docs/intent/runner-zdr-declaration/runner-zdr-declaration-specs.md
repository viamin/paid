# EARS Specs: Runner Zero Data Retention Declaration

> Testable claims for runner-level ZDR declaration and provenance. Each ID is
> a grep target across specs, tests, and code (`grep -r RUNNER-ZDR-001`).

- [x] **RUNNER-ZDR-001** — When a runner is created without a ZDR value, the
  system SHALL persist ZDR as disabled; an authorized user SHALL be able to
  create or update a runner with ZDR enabled independently of its model policy.
- [x] **RUNNER-ZDR-002** — When an enabled-ZDR runner's effective provider is
  OpenRouter, the system SHALL expose `openrouter` provenance and
  `not_verified` runtime enforcement; when its effective provider is not
  OpenRouter, it SHALL expose `user_declared` provenance and the same
  unverified enforcement state.
- [x] **RUNNER-ZDR-003** — When a runner's provider API key changes, the
  system SHALL derive subsequent ZDR provenance from the replacement key and
  SHALL NOT retain provenance for the former provider.
- [x] **RUNNER-ZDR-004** — When an authorized runner detail or runner-list
  interface exposes a ZDR declaration, it SHALL include the declaration,
  provenance, and runtime-enforcement state without exposing credentials.
- [x] **RUNNER-ZDR-005** — When the runner form offers ZDR, it SHALL state:
  “You are responsible for verifying this provider's zero data retention
  agreement and configuration.”
