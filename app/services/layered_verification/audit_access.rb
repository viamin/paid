# frozen_string_literal: true

module LayeredVerification
  class AuditAccess
    # @spec LAYERED-VERIFY-010
    # @spec LAYERED-VERIFY-012
    FeatureDisabledError = Class.new(StandardError)
    UnauthorizedError = Class.new(StandardError)

    def self.authorize!(...)
      new(...).authorize!
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
      FeatureFlags.enabled?(:layered_verification_add_on, project: project)
    end

    def policy
      ProjectPolicy.new(user, project)
    end
  end
end
