# frozen_string_literal: true

# Production-only startup configuration validation.
#
# Fails fast at boot when a required setting is absent or unsafe, and logs
# warnings for development-unsafe defaults. Development and test environments
# are unaffected (the hook short-circuits on `Rails.env.production?`).
#
# Build/asset tasks (e.g. the Docker image's `assets:precompile` step) also
# boot Rails in the production environment but intentionally lack runtime
# secrets, so they are skipped via `Config::ProductionValidator.build_command?`.
# Runtime processes -- the web server, `bin/jobs`, `bin/temporal_worker`, and
# deploy-time `db:prepare` / `db:migrate` -- carry the deployed secrets and are
# validated so a misconfigured deploy fails loudly instead of at first request.
#
# See Config::ProductionValidator for the policy and docs/PRODUCTION_CONFIG.md
# for the required variable list.
#
# @spec PROD-CONFIG-001
# @spec PROD-CONFIG-004
Rails.application.config.after_initialize do
  next unless Rails.env.production?
  next if Config::ProductionValidator.build_command?

  Config::ProductionValidator.from_environment.validate!
end
