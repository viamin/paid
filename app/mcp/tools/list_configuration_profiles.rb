# frozen_string_literal: true

module Tools
  class ListConfigurationProfiles < BaseTool
    authorize :index?, ->(_args) { Project.new(account: account) }, policy_class: ProjectPolicy

    def self.tool_name = "list_configuration_profiles"

    def self.description
      "List the available Paid operating-mode configuration profiles."
    end

    def perform
      {
        profiles: ConfigurationProfiles::Registry.all.map do |profile|
          {
            key: profile.key.to_s,
            name: profile.name,
            description: profile.description
          }
        end
      }
    end
  end
end
