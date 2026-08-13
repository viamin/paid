# frozen_string_literal: true

# Verify the database runtime role guard configuration.
# Stays in after_initialize (not to_prepare) because this is a one-time
# startup safety check — no need to re-run on every code reload.
Rails.application.config.after_initialize do
  Database::RuntimeRoleGuard.verify! unless Rails.env.test?
end
