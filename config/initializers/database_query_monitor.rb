# frozen_string_literal: true

Rails.application.config.after_initialize do
  Database::QueryMonitor.install!
end
