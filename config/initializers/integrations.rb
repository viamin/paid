# frozen_string_literal: true

Rails.application.config.after_initialize do
  Integrations::Registry.register(Integrations::GithubProvider)
  Integrations::Registry.register(Integrations::LinearProvider)
end
