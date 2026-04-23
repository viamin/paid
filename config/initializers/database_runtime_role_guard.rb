# frozen_string_literal: true

Rails.application.config.after_initialize do
  Database::RuntimeRoleGuard.verify! unless Rails.env.test?
end
