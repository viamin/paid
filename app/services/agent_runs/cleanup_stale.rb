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
      project.agent_runs.stale_running
    end

    def cleanup_run(agent_run)
      should_cleanup_resources = false

      agent_run.with_lock do
        agent_run.reload
        return false unless agent_run.running?
        return false unless agent_run.started_at && agent_run.started_at < AgentRun.stale_running_cutoff

        agent_run.timeout!(error: "Manual stale run cleanup: exceeded running timeout")
        agent_run.log!("system", "Run marked as timed out by manual stale run cleanup")
        should_cleanup_resources = true

        if (issue = agent_run.issue)
          target_state = agent_run.review_goal? ? "completed" : "failed"
          issue.update!(paid_state: target_state) unless issue.paid_state == target_state
        end
      end

      cleanup_resources(agent_run) if should_cleanup_resources
      true
    end

    def cleanup_resources(agent_run)
      agent_run.cleanup_container(force: true) if agent_run.container_id.present?
      Containers::ServiceProvisioner.new.cleanup(agent_run)
    rescue => e
      Rails.logger.warn(
        message: "agent_runs.cleanup_stale_resources_failed",
        agent_run_id: agent_run.id,
        project_id: project.id,
        error_class: e.class.name,
        error: e.message
      )
    end
  end
end
