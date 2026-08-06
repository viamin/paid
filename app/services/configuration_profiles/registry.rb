# frozen_string_literal: true

module ConfigurationProfiles
  # Compatibility facade over the chat-integrated profile registry. Keeping the
  # legacy API backed by Configuration::Profiles avoids a second maintained
  # posture catalog while older callers migrate.
  module Registry
    module_function

    PROJECT_LEVEL_KEYS = Configuration::Profiles::Settings.target_descriptors
      .select { |d| d.level == :project }
      .map(&:key)
      .freeze

    def all
      @all ||= Configuration::Profiles::Registry.all.map do |profile|
        Profile.new(
          key: profile.name.to_sym,
          name: profile.display_name,
          description: profile.description,
          values: profile.targets.slice(*PROJECT_LEVEL_KEYS)
        )
      end.freeze
    end

    def keys = all.map(&:key).freeze

    def find(key)
      all.find { |profile| profile.key == key.to_sym }
    end

    def find!(key)
      find(key) || raise(ArgumentError, "Unknown configuration profile: #{key.inspect}")
    end
  end
end
