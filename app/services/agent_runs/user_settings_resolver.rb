# frozen_string_literal: true

module AgentRuns
  class UserSettingsResolver
    def self.call(project:, strict: true)
      account = project.account

      user = project.created_by
      user ||= account.account_memberships.find_by(role: :owner)&.user
      user ||= account.users.first

      if user.nil? && strict
        raise Temporalio::Error::ApplicationError.new(
          "No user available for agent run settings",
          type: "MissingUser"
        )
      end

      user&.settings
    end
  end
end
