# frozen_string_literal: true

module IssueTrackers
  # Resolves the effective tracker configuration for a project by applying
  # the settings hierarchy: project > user > account. Falls back to
  # GitHub Issues (the default) when no explicit configuration exists.
  module ResolveConfiguration
    module_function

    # @param project [Project] the project to resolve configuration for
    # @param user [User, nil] optional user for user-level override
    # @return [TrackerConfiguration] the effective tracker configuration
    def call(project:, user: nil)
      resolve_from_project(project) ||
        resolve_from_user(user) ||
        resolve_from_account(project.account) ||
        default_configuration(project)
    end

    def resolve_from_project(project)
      project.tracker_configuration&.then { |tc| tc.enabled? ? tc : nil }
    end

    def resolve_from_user(user)
      return nil unless user

      user.tracker_configuration&.then { |tc| tc.enabled? ? tc : nil }
    end

    def resolve_from_account(account)
      account.tracker_configuration&.then { |tc| tc.enabled? ? tc : nil }
    end

    # Builds a virtual (non-persisted) default configuration for GitHub Issues.
    def default_configuration(project)
      TrackerConfiguration.new(
        configurable: project,
        tracker_type: "github_issues",
        enabled: true
      )
    end
  end
end
