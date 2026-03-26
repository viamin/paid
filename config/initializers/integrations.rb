# frozen_string_literal: true

Rails.application.config.to_prepare do
  Integrations::Registry.reset!
  Integrations::Registry.register(Integrations::GithubProvider)
  Integrations::Registry.register(Integrations::LinearProvider)
end
