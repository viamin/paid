# frozen_string_literal: true

module PrerequisiteExecutions
  # Executes a claimed pending validation attempt. Mirrors the
  # PreviewSessions::ProvisionJob shape: load under system access, execute
  # inside the project's tenant context.
  #
  # @spec PREREQ-EXEC-006
  class ValidationJob < ApplicationJob
    queue_as :low_priority
    self.perform_timeout = 30.minutes

    discard_on ActiveRecord::RecordNotFound

    def perform(validation_id)
      validation = TenantContext.with_system_access do
        PrerequisiteExecutionValidation.includes(:project, :issue, agent_run: :project).find(validation_id)
      end

      TenantContext.with(validation.project.account) do
        PrerequisiteExecutions::Runner.call(validation)
      end
    end
  end
end
