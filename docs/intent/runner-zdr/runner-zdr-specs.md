# EARS Specs: Runner Zero Data Retention

> Testable claims for runner-level ZDR declaration and provenance. Each ID is
> a grep target across specs, tests, and code (`grep -r RUNNER-ZDR-001`).

- [x] **RUNNER-ZDR-001** — When an existing or newly created runner has no
  ZDR setting, the system SHALL persist and expose it as disabled.
- [x] **RUNNER-ZDR-002** — When an authorized user enables ZDR on a runner,
  the system SHALL persist the declaration independently of `model_policy` and
  allow it for non-OpenRouter providers.
- [x] **RUNNER-ZDR-003** — When a ZDR-enabled runner currently routes through
  OpenRouter, the system SHALL expose `openrouter_enforced` provenance and
  include ZDR in its OpenRouter request-routing metadata; restricted projects
  SHALL continue to require that metadata even without a runner declaration.
- [x] **RUNNER-ZDR-004** — When a ZDR-enabled runner currently routes through
  another provider, the system SHALL expose `user_declared` provenance and
  SHALL not claim provider-runtime verification or configuration by Paid.
- [x] **RUNNER-ZDR-005** — When a runner's provider or credential changes,
  the system SHALL derive its ZDR provenance from the current provider so no
  stale OpenRouter-enforcement claim remains.
- [x] **RUNNER-ZDR-006** — When runner configuration is displayed or audited,
  the system SHALL expose its ZDR configuration through the existing
  authorization and tenant boundaries and SHALL show the provider-agreement
  responsibility guidance.
