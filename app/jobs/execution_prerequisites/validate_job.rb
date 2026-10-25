# frozen_string_literal: true

module ExecutionPrerequisites
  class ValidateJob < ApplicationJob
    queue_as :default

    def perform(agent_run_id)
      ExecutionPrerequisites::Validate.call(agent_run: AgentRun.find(agent_run_id))
    end

    private

    def tenant_account
      AgentRun.find_by(id: arguments.first)&.project&.account
    end
  end
end
