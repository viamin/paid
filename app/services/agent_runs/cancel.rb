# frozen_string_literal: true

module AgentRuns
  class Cancel
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, skip_status_update: false)
      @agent_run = agent_run
      @skip_status_update = skip_status_update
    end

    def call
      cancel_temporal_workflow
      cleanup_container
      agent_run.cancel! unless skip_status_update
    end

    private

    attr_reader :agent_run, :skip_status_update

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
    end
  end
end
