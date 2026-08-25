# frozen_string_literal: true

module Issues
  class IssueAnalysisBackoffResetContext
    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      return unless owner

      [
        owner.settings&.updated_at,
        owner.runners.maximum(:updated_at),
        owner.runner_states.maximum(:updated_at),
        owner.provider_api_keys.maximum(:updated_at),
        owner.account.integration_credentials.maximum(:updated_at)
      ].compact.max
    end

    private

    attr_reader :project

    def owner
      project.effective_owner
    end
  end
end
