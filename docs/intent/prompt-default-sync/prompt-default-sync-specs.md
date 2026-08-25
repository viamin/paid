# EARS Specs: Prompt Default Synchronization

> Testable claims for synchronizing application-owned global prompt defaults.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

## Synchronization semantics

- [x] **PROMPT-DEFAULT-SYNC-001** — When shipped prompt defaults are
  synchronized, the system SHALL create missing global prompts and SHALL create
  and promote a new immutable version for each global prompt whose normalized
  template or variables differ from its current version.
  *Code:* `Prompts::SyncDefaults`.
  *Test:* `spec/services/prompts/sync_defaults_spec.rb`.

- [x] **PROMPT-DEFAULT-SYNC-002** — When a shipped global prompt already has
  the normalized template and variables declared by the application, the
  system SHALL leave its version history and current version unchanged.
  *Code:* `Prompts::SyncDefaults`.
  *Test:* `spec/services/prompts/sync_defaults_spec.rb`.

- [x] **PROMPT-DEFAULT-SYNC-003** — When shipped prompt defaults are
  synchronized, the system SHALL limit writes to unscoped global prompts and
  SHALL NOT modify account- or project-scoped prompt records or versions.
  *Code:* `Prompts::SyncDefaults`.
  *Test:* `spec/services/prompts/sync_defaults_spec.rb`.

- [x] **PROMPT-DEFAULT-SYNC-004** — When multiple application processes
  synchronize shipped prompt defaults concurrently, the system SHALL serialize
  the comparison-and-create operation so each changed definition produces at
  most one new current version.
  *Code:* `Prompts::SyncDefaults`.
  *Test:* `spec/services/prompts/sync_defaults_spec.rb`.

## Operational entry points

- [x] **PROMPT-DEFAULT-SYNC-005** — When an operator runs
  `bin/rails prompts:sync_defaults`, the system SHALL synchronize only shipped
  prompt defaults and SHALL report counts for created prompts, created versions,
  and unchanged definitions.
  *Code:* `lib/tasks/prompts.rake`.
  *Test:* `spec/tasks/prompts_rake_spec.rb`.

- [x] **PROMPT-DEFAULT-SYNC-006** — When the general database seed task loads
  prompt defaults, it SHALL use the same shipped definitions and synchronization
  behavior as `bin/rails prompts:sync_defaults`.
  *Code:* `db/seeds/prompts.rb`, `Prompts::SyncDefaults`.
  *Test:* `spec/services/prompts/sync_defaults_spec.rb`.

## Automatic propagation

- [x] **PROMPT-DEFAULT-SYNC-007** — When `bin/dev-update` completes database
  preparation for either a lightweight or full development update, it SHALL run
  `bin/rails prompts:sync_defaults` before reporting success, and a failed sync
  SHALL fail the update.
  *Code:* `bin/dev-update`.
  *Test:* `spec/lib/dev_update_spec.rb`.

- [x] **PROMPT-DEFAULT-SYNC-008** — When the container entry point prepares the
  database for a Rails server process, it SHALL run
  `bin/rails prompts:sync_defaults` after `db:prepare` and before starting the
  server, and a failed sync SHALL prevent server startup.
  *Code:* `bin/docker-entrypoint`.
  *Test:* `spec/lib/docker_entrypoint_spec.rb`.
