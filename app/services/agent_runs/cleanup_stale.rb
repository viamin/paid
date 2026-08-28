# frozen_string_literal: true

module AgentRuns
  class CleanupStale
    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      resolved = 0

      stale_runs.find_each do |agent_run|
        resolved += 1 if cleanup_run(agent_run)
      rescue => e
        Rails.logger.error(
          message: "agent_runs.cleanup_stale_failed",
          agent_run_id: agent_run.id,
          project_id: project.id,
          error: e.message
        )
      end

      ProcessRunQueueJob.perform_later if resolved.positive?
      resolved
    end

    private

    attr_reader :project

    def stale_runs
      project.agent_runs.stale_for_cleanup
    end

    def cleanup_run(agent_run)
      old_resources = {}
      should_cleanup_resources = false

      agent_run.with_lock do
        agent_run.reload
        return false unless stale?(agent_run)

        old_resources = captured_resources(agent_run)
        should_cleanup_resources = resolve_stale_run(agent_run)
      end

      cleanup_resources(agent_run, old_resources) if should_cleanup_resources
      should_cleanup_resources
    end

    def captured_resources(agent_run)
      {
        container_id: agent_run.container_id,
        container_host: agent_run.workspace_volume_host,
        service_container_ids: agent_run.service_container_ids.dup,
        service_environment: agent_run.service_environment&.dup,
        stale_requeue_count: agent_run.stale_requeue_count
      }
    end

    def stale?(agent_run)
      stale_running?(agent_run) || stale_claimed?(agent_run)
    end

    def stale_running?(agent_run)
      AgentRun.stale_running?(agent_run)
    end

    def stale_claimed?(agent_run)
      AgentRun.stale_claimed?(agent_run)
    end

    def resolve_stale_run(agent_run)
      return resolve_stale_running(agent_run) if stale_running?(agent_run)

      resolve_stale_claimed(agent_run)
    end

    def resolve_stale_running(agent_run)
      return false unless agent_run.timeout!(error: "Manual stale run cleanup: exceeded running timeout")

      agent_run.log!("system", "Run marked as timed out by manual stale run cleanup")
      update_issue_state(agent_run)
      true
    end

    def resolve_stale_claimed(agent_run)
      if agent_run.stale_requeue_count >= AgentRun::MAX_STALE_REQUEUES
        return false unless agent_run.timeout!(error: "Manual stale run cleanup: exceeded claimed requeue limit")

        agent_run.log!("system", "Stale claimed queued run marked as timed out by manual stale run cleanup")
        update_issue_state(agent_run)
        should_cleanup_resources = true
      else
        return false unless cancel_temporal_workflow(agent_run)

        agent_run.update!(
          status: "queued",
          queue_entered_at: Time.current,
          stale_requeue_count: agent_run.stale_requeue_count + 1,
          started_at: nil,
          completed_at: nil,
          duration_seconds: nil,
          temporal_workflow_id: nil,
          temporal_run_id: nil,
          service_environment: nil,
          container_id: nil,
          service_container_ids: []
        )
        agent_run.log!(
          "system",
          "Stale claimed queued run unclaimed by manual stale run cleanup (attempt #{agent_run.stale_requeue_count}/#{AgentRun::MAX_STALE_REQUEUES})"
        )
        should_cleanup_resources = true
      end

      should_cleanup_resources
    end

    def update_issue_state(agent_run)
      return unless (issue = agent_run.issue)

      target_state = agent_run.review_goal? ? "completed" : "failed"
      issue.update!(paid_state: target_state) unless issue.paid_state == target_state
    end

    def cancel_temporal_workflow(agent_run)
      workflow_id = agent_run.temporal_workflow_id
      return true if workflow_id.blank?
      return true if workflow_id == AgentRun::CLAIMED_SENTINEL

      handle = Paid.temporal_client.workflow_handle(workflow_id)
      handle.cancel
      true
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

      true
    rescue => e
      Rails.logger.warn(
        message: "agent_runs.cleanup_stale_cancel_workflow_failed",
        agent_run_id: agent_run.id,
        project_id: project.id,
        temporal_workflow_id: workflow_id,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def cleanup_resources(agent_run, old_resources)
      cleanup_container(agent_run, old_resources)
      cleanup_service_containers(agent_run, old_resources)
    end

    def cleanup_container(agent_run, old_resources) # @spec EXEC-USAGE-009
      old_container_id = old_resources[:container_id]
      cleanup_confirmed = false
      if old_container_id.present?
        AgentRun.where(id: agent_run.id, container_id: old_container_id).update_all(container_id: nil)

        service = Containers::Provision.reconnect(
          agent_run: agent_run,
          container_id: old_container_id,
          worktree_path: agent_run.worktree_path
        )
        service.cleanup(force: true)
        cleanup_confirmed = true
      else
        cleanup_confirmed = true
      end
      # Record whenever a container_host is present — a stale run that
      # reached provisioning (provisioning_started_at and
      # planned_container_host set) but never persisted a container_id
      # has no cleanup branch to enter above yet still needs its terminal
      # usage row created. record_execution_usage! early-returns when
      # container_host is blank, so this is safe for runs that never
      # reached provisioning at all.
    rescue Docker::Error::NotFoundError
      cleanup_confirmed = true
    rescue => e
      Rails.logger.warn(
        message: "agent_runs.cleanup_stale_container_failed",
        agent_run_id: agent_run.id,
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
    ensure
      record_execution_usage(agent_run, old_resources) if cleanup_confirmed
    end

    def record_execution_usage(agent_run, old_resources)
      agent_run.record_execution_usage_after_cleanup!(
        container_id: old_resources[:container_id],
        container_host: old_resources[:container_host]
      )
    end

    def cleanup_service_containers(agent_run, old_resources)
      service_container_ids = old_resources[:service_container_ids]
      service_environment = old_resources[:service_environment]

      agent_run.service_container_ids = service_container_ids if service_container_ids.present?
      agent_run.service_environment = service_environment if service_environment.present?
      Containers::ServiceProvisioner.new.cleanup(agent_run,
        stale_requeue_count: old_resources[:stale_requeue_count])
    rescue => e
      Rails.logger.warn(
        message: "agent_runs.cleanup_stale_service_cleanup_failed",
        agent_run_id: agent_run.id,
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end
end
