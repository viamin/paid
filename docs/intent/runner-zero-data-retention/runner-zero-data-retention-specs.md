# EARS Specs: Runner Zero Data Retention

- [x] **RUNNER-ZDR-001** — When a runner is created without an explicit ZDR
  selection, the system SHALL persist `zero_data_retention` as false.
- [x] **RUNNER-ZDR-002** — When an OpenRouter direct-outbound runner declares
  ZDR, the system SHALL add `zdr: true` to its OpenRouter provider routing in
  addition to the project classification requirements.
- [x] **RUNNER-ZDR-003** — When a runner declares ZDR, the system SHALL expose
  `openrouter_enforced` only for its current OpenRouter direct-outbound path;
  it SHALL expose `user_declared` for other paths and recompute the value when
  the provider changes.
- [x] **RUNNER-ZDR-004** — When an authorized user views or lists a runner,
  the system SHALL expose its ZDR setting and provenance without exposing
  credentials; unauthorized users SHALL remain unable to access the runner.
- [x] **RUNNER-ZDR-005** — When the runner form presents the ZDR setting, it
  SHALL state: “You are responsible for verifying this provider's zero data
  retention agreement and configuration.”
