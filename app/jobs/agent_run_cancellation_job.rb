# frozen_string_literal: true

require "docker-api"
require "temporalio/error"

class AgentRunCancellationJob < ApplicationJob
  queue_as :default

  retry_on Temporalio::Error::RPCError, wait: :polynomially_longer, attempts: 5
  retry_on Docker::Error::DockerError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)

    cancel_temporal_workflow(agent_run)
    cleanup_container(agent_run)
  end

  private

  def cancel_temporal_workflow(agent_run)
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

  def cleanup_container(agent_run)
    return if agent_run.container_id.blank?

    agent_run.cleanup_container(force: true)
  end
end
