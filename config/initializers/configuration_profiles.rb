# frozen_string_literal: true

Rails.application.config.to_prepare do
  ConfigurationProfiles::Registry.reset!
  ConfigurationProfiles::Registry.register(ConfigurationProfiles::SoloFullyAutomatedProfile)
  ConfigurationProfiles::Registry.register(ConfigurationProfiles::TeamCollaborativeProfile)
end
