# frozen_string_literal: true

module AgentRuns
  # Cancels an active agent run, including its Temporal workflow and container.
  #
  # @example
  #   AgentRuns::Cancel.call(agent_run: agent_run)
  class Cancel
    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      cancel_temporal_workflow
      cleanup_container
      agent_run.cancel!
    end

    private

    def cancel_temporal_workflow
      return if agent_run.temporal_workflow_id.blank?

      handle = Paid.temporal_client.workflow_handle(agent_run.temporal_workflow_id)
      handle.cancel
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

      Rails.logger.info(
        message: "agent_execution.cancel_workflow_not_found",
        agent_run_id: agent_run.id,
        temporal_workflow_id: agent_run.temporal_workflow_id
      )
    end

    def cleanup_container
      return if agent_run.container_id.blank?

      agent_run.cleanup_container(force: true)
    rescue Containers::Provision::Error => e
      Rails.logger.info(
        message: "agent_execution.cancel_container_cleanup_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
    end
  end
end
