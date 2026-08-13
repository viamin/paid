# frozen_string_literal: true

# Register the query monitor's ActiveSupport subscriber.
# Stays in after_initialize (not to_prepare) because Database::QueryMonitor
# is pinned by require_relative in config/application.rb — it never reloads,
# so the subscription only needs to run once.
Rails.application.config.after_initialize do
  Database::QueryMonitor.install!
end
