# EARS Specs: Production Configuration Validation

> Testable claims for the production startup configuration validator. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r PROD-CONFIG-001`).

- [x] **PROD-CONFIG-001** — When the application boots in the production
  environment, the configuration validator SHALL run from an `after_initialize`
  hook and raise a single error enumerating every absent or unsafe required
  setting (database credentials and Qdrant API key) before the process serves
  traffic.
  *Code:* `app/services/config/production_validator.rb`,
  `config/initializers/production_config.rb`.
  *Test:* `spec/services/config/production_validator_spec.rb`.

- [x] **PROD-CONFIG-002** — When a required setting is individually missing in
  production, the validator SHALL fail boot naming that setting (database when
  both `DATABASE_URL` and `PAID_DATABASE_PASSWORD` are absent; Qdrant API key
  when neither `QDRANT_API_KEY` nor the `qdrant.api_key` credential is present).
  *Code:* `app/services/config/production_validator.rb`.
  *Test:* `spec/services/config/production_validator_spec.rb`.

- [x] **PROD-CONFIG-003** — When a development-unsafe default is detected in
  production (a Temporal, Redis, or Qdrant address resolving to localhost,
  `CONTAINER_BACKEND=local` with no Docker socket, an unwritable workspace root,
  or unconfigured screenshots storage), the validator SHALL emit a structured
  warning and SHALL NOT stop boot.
  *Code:* `app/services/config/production_validator.rb`.
  *Test:* `spec/services/config/production_validator_spec.rb`.

- [x] **PROD-CONFIG-004** — In development and test environments, the validator
  SHALL NOT run; the `after_initialize` hook short-circuits before instantiating
  the validator so those environments are unaffected.
  *Code:* `config/initializers/production_config.rb`.

- [x] **PROD-CONFIG-005** — During image build / asset-compilation commands
  (e.g. `assets:precompile`, which boots Rails in the production environment
  without runtime secrets), the validator SHALL skip execution so the image
  build is not falsely blocked.
  *Code:* `Config::ProductionValidator.build_command?`,
  `config/initializers/production_config.rb`.
  *Test:* `spec/services/config/production_validator_spec.rb`.

- [x] **PROD-CONFIG-006** — In production, the startup validator SHALL fail
  boot when any required infrastructure-safety limit for aggregate requested
  resources, provisioning-rate windows, or per-execution resource maxima is
  unset or non-positive, so capacity admission fails closed rather than
  silently using development defaults.
  *Code:* `app/services/config/production_validator.rb`,
  `app/services/capacity/infrastructure_limits.rb`
  *Test:* `spec/services/config/production_validator_spec.rb`.
