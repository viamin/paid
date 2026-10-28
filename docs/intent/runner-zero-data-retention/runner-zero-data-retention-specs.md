# EARS Specs: Runner Zero Data Retention Declaration

> Testable claims for runner-level inference retention declarations. Status
> markers: `[x]` implemented · `[ ]` active gap. Each ID is a grep target
> across specs, tests, and code (`grep -r RUNNER-ZDR-001`).

- [x] **RUNNER-ZDR-001** — When a runner is created without a ZDR value, or an
  existing runner is migrated, the system SHALL persist `zero_data_retention`
  as false.
- [x] **RUNNER-ZDR-002** — When an authorized user creates or updates a
  runner, the system SHALL permit an independent `zero_data_retention`
  declaration without changing its model policy, and SHALL present: "You are
  responsible for verifying this provider's zero data retention agreement and
  configuration."
- [x] **RUNNER-ZDR-003** — When a runner declares ZDR and currently resolves
  to OpenRouter, the system SHALL expose `openrouter_enforced` provenance and
  include `zdr: true` in its OpenRouter request routing while preserving all
  project-derived privacy routing requirements.
- [x] **RUNNER-ZDR-004** — When a runner declares ZDR and currently resolves
  to a non-OpenRouter or unknown provider, the system SHALL expose
  `user_declared` provenance and SHALL NOT represent the declaration as
  runtime-enforced by Paid.
- [x] **RUNNER-ZDR-005** — When a runner's provider or credential changes,
  the system SHALL derive subsequent ZDR provenance from the new current
  provider without retaining a stale `openrouter_enforced` label.
- [x] **RUNNER-ZDR-006** — Runner details, tenant-authorized runner
  serialization, runner audit events, and safe agent-run configuration
  evidence SHALL expose the ZDR declaration and derived provenance without
  exposing credentials.
