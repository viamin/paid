# frozen_string_literal: true

module AgentRuns
  class UserSettingsResolver
    class MissingUserError < StandardError; end

    def self.call(project:, strict: true, create: true)
      account = project.account

      user = project.created_by
      user ||= account&.account_memberships&.find_by(role: :owner)&.user
      user ||= account&.users&.first

      raise MissingUserError, "No user available for project #{project.id}" if user.nil? && strict

      create ? user&.settings : user&.user_setting
    end
  end
end
