# frozen_string_literal: true

# Register one Notifications::Rule per health check at boot so
# Notifications::Rule.evaluate_all(account:) publishes for firing checks and
# auto-resolves notifications for projects that are now clean (RDR-049).
Rails.application.config.after_initialize do
  HealthChecks::Registry.all.each do |check_class|
    rule = HealthChecks::Notifications::RuleAdapter.for(check_class)
    Notifications::Rule.register(rule)
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
  # Database not ready yet (e.g. during asset precompilation in CI/build).
  # Health check rules are not needed at that stage; the next server boot
  # will register them.
end
