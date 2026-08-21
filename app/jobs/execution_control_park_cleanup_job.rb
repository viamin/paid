# frozen_string_literal: true

require "docker-api"
require "temporalio/error"

# @spec EXEC-DISABLE-006
# Tears down the Temporal workflow and Docker container for a run parked by a
# capacity ExecutionControl. ExecutionControls::RunImpact#park_run! nulls
# temporal_workflow_id/container_id on the row as part of the park mutation,
# so the ids the row held immediately beforehand are passed in explicitly
# rather than re-read from the (already-nulled) persisted record.
#
# Runs out-of-process so toggling a global/account/project capacity control —
# which can affect every active run system-wide — returns immediately instead
# of blocking on a serial pass of Temporal cancels and Docker teardowns, and
# so the network teardown gets GoodJob retry semantics (parity with the
# emergency path's AgentRunCancellationJob).
class ExecutionControlParkCleanupJob < ApplicationJob
  queue_as :default

  retry_on Temporalio::Error::RPCError, wait: :polynomially_longer, attempts: 5
  retry_on Docker::Error::DockerError, wait: :polynomially_longer, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(agent_run_id, workflow_id, container_id)
    agent_run = AgentRun.find(agent_run_id)

    cancel_temporal_workflow(agent_run_id, workflow_id) if workflow_id.present?
    cleanup_container(agent_run, container_id) if container_id.present?
  end

  private

  def cancel_temporal_workflow(agent_run_id, workflow_id)
    return if workflow_id == AgentRun::CLAIMED_SENTINEL

    handle = Paid.temporal_client.workflow_handle(workflow_id)
    handle.cancel
  rescue Temporalio::Error::RPCError => e
    raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

    Rails.logger.info(
      message: "execution_control.cancel_workflow_not_found",
      agent_run_id: agent_run_id,
      temporal_workflow_id: workflow_id
    )
  end

  def cleanup_container(agent_run, container_id)
    # If the run has since been re-dispatched to a new container, its
    # persisted container_id will differ from the stale id we're tearing
    # down here (clear_container_id_if_unchanged! only clears it when it
    # still matches). The container itself is still safe to tear down, but
    # the shared workspace volume must be preserved — the new container
    # reuses the same "paid-workspace-<agent_run.id>" volume name.
    redispatched = AgentRun.where(id: agent_run.id)
      .where.not(container_id: [ nil, container_id ]).exists?

    agent_run.container_id = container_id

    # Runner-backed environments need @current_handle reconstructed so
    # cleanup_container takes the runner cleanup path instead of falling
    # through to Docker. park_record! nulls container_id but preserves
    # runner_handle, so the persisted handle is still available.
    runner_handle = ExecutionRunners::RunnerHandle.from_record(agent_run)
    agent_run.instance_variable_set(:@current_handle, runner_handle) if runner_handle

    agent_run.cleanup_container(force: true, preserve_workspace_volume: redispatched)
  end
end
