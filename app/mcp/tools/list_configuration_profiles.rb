# frozen_string_literal: true

module Tools
  class ListConfigurationProfiles < BaseTool
    authorize :update?, ->(_args) { current_user.user_setting || UserSetting.new(user: current_user) }, policy_class: UserSettingPolicy

    def self.tool_name = "list_configuration_profiles"

    def self.description
      "List the available Paid configuration profiles and the settings levels each one changes."
    end

    def perform
      {
        profiles: ConfigurationProfiles::Registry.summaries
      }
    end
  end
end
