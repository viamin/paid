# frozen_string_literal: true

module Labels
  # The sole policy authority for GitHub label mutations.
  # @spec LABEL-INTEGRATION-002
  class WritePolicy
    def self.allowed?(project:, logger: Rails.logger)
      new(project:, logger:).allowed?
    end

    def initialize(project:, logger:)
      @project = project
      @logger = logger
    end

    def allowed?
      return true unless project.respond_to?(:label_integration_mode)
      return true unless %w[read_only ignored].include?(project.label_integration_mode)

      logger.info(message: "github_labels.write_suppressed", project_id: project.id,
        label_integration_mode: project.label_integration_mode)
      false
    end

    private

    attr_reader :project, :logger
  end
end
