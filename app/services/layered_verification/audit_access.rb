# frozen_string_literal: true

module LayeredVerification
  # The single authorization boundary every layered-verification entry point
  # traverses: the add-on must be enabled for the project, and the user must
  # hold the audit bar (`ProjectPolicy#manage_issues?`).
  #
  # @spec LAYERED-VERIFY-010
  # @spec LAYERED-VERIFY-012
  class AuditAccess
    FeatureDisabledError = Class.new(StandardError)
    UnauthorizedError = Class.new(StandardError)

    def self.authorize!(...)
      new(...).authorize!
    end

    # Whether the add-on is enabled for the project. Every UI, chat, and MCP
    # entry point reads this before it accepts an audit request.
    def self.feature_enabled?(project)
      FeatureFlags.enabled?(:layered_verification_add_on, project: project)
    end

    def initialize(user:, project:)
      @user = user
      @project = project
    end

    def authorize!
      raise FeatureDisabledError, "layered verification is not enabled for this project" unless feature_enabled?
      raise UnauthorizedError, "not authorized to request a layered-verification audit" unless policy.manage_issues?

      true
    end

    private

    attr_reader :user, :project

    def feature_enabled?
      self.class.feature_enabled?(project)
    end

    def policy
      ProjectPolicy.new(user, project)
    end
  end
end
