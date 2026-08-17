# frozen_string_literal: true

module ExecutionControls
  class RunImpact
    # @spec EXEC-DISABLE-005
    # @spec EXEC-DISABLE-006
    # @spec EXEC-DISABLE-007
    def initialize(control:, actor: nil)
      @control = control
      @actor = actor
    end

    def enable!
      record_control_event!("execution_control.enabled")
      log_control_event("execution_control.enabled")
      affect_active_runs!
    end

    def disable!
      record_control_event!("execution_control.disabled")
      log_control_event("execution_control.disabled")
      resume_parked_runs! if control.capacity?
    end

    def park_run!(agent_run)
      changed = false

      agent_run.with_lock do
        next if agent_run.finished?
        next if parked_by_control?(agent_run)

        if agent_run.status == "queued" && agent_run.temporal_workflow_id.blank?
          changed = park_record!(agent_run)
          next
        end

        AgentRuns::Cancel.call(agent_run: agent_run, skip_status_update: true)
        changed = park_record!(agent_run)
      end

      return unless changed

      record_run_event!("agent_run.execution_parked", agent_run, result: "execution_control_capacity")
      log_run_event("execution_control.run_parked", agent_run)
    end

    private

    attr_reader :control, :actor

    def affect_active_runs!
      affected_runs.find_each do |agent_run|
        control.emergency? ? cancel_run!(agent_run) : park_run!(agent_run)
      end
    end

    def cancel_run!(agent_run)
      changed = false

      agent_run.with_lock do
        next unless agent_run.cancellable?

        changed = agent_run.cancel!(error: control_reason)
      end

      return unless changed

      AgentRunCancellationJob.perform_later(agent_run.id)
      record_run_event!("agent_run.cancelled", agent_run, result: "execution_control_emergency")
      log_run_event("execution_control.run_cancelled", agent_run)
    end

    def park_record!(agent_run)
      metadata = agent_run.external_metadata.deep_dup
      metadata[ExecutionControl::PARK_MARKER_KEY] = {
        "control_id" => control.id,
        "scope" => control.scope,
        "mode" => control.mode,
        "parked_at" => Time.current.iso8601
      }

      agent_run.update!(
        status: "paused",
        paused_at: Time.current,
        started_at: nil,
        completed_at: nil,
        duration_seconds: nil,
        temporal_workflow_id: nil,
        temporal_run_id: nil,
        external_metadata: metadata,
        error_message: control_reason
      )
    end

    def resume_parked_runs!
      parked_runs.find_each do |agent_run|
        next unless parked_by_control?(agent_run)

        agent_run.with_lock do
          next unless agent_run.paused?
          next unless parked_by_control?(agent_run)

          metadata = agent_run.external_metadata.deep_dup
          metadata.delete(ExecutionControl::PARK_MARKER_KEY)
          agent_run.update!(
            status: "queued",
            paused_at: nil,
            external_metadata: metadata,
            error_message: nil
          )
        end

        record_run_event!("agent_run.resumed", agent_run, result: "execution_control_cleared")
        log_run_event("execution_control.run_resumed", agent_run)
      end
    end

    def affected_runs
      scope = case control.scope
      when "global"
        AgentRun.where(status: AgentRun::UNFINISHED_STATUSES)
      when "account"
        AgentRun.joins(:project).where(projects: { account_id: control.account_id }, status: AgentRun::UNFINISHED_STATUSES)
      when "project"
        AgentRun.where(project_id: control.project_id, status: AgentRun::UNFINISHED_STATUSES)
      when "runner"
        AgentRun.where(runner_id: control.runner_id, status: AgentRun::UNFINISHED_STATUSES)
      when "backend"
        host = control.docker_host&.identifier.to_s
        AgentRun.where(status: AgentRun::UNFINISHED_STATUSES)
          .where(
            "COALESCE(NULLIF(container_host, ''), COALESCE(external_metadata->>'planned_container_host', '')) = ?",
            host
          )
      else
        AgentRun.none
      end
      scope.includes(project: :account)
    end

    def parked_runs
      affected_runs.where(status: "paused")
    end

    def parked_by_control?(agent_run)
      agent_run.external_metadata.to_h.dig(ExecutionControl::PARK_MARKER_KEY, "control_id") == control.id
    end

    def control_reason
      control.reason.presence || "Execution disabled (#{control.scope}, #{control.mode})"
    end

    def record_control_event!(action)
      return if control.scope == "global"

      Audit::RecordEvent.call(
        action: action,
        actor: actor,
        subject: control.target,
        metadata: {
          execution_control_id: control.id,
          execution_control_scope: control.scope,
          execution_control_mode: control.mode,
          reason: control.reason
        }
      )
    end

    def record_run_event!(action, agent_run, result:)
      Audit::RecordEvent.call(
        action: action,
        actor: actor,
        subject: agent_run,
        metadata: {
          agent_run_id: agent_run.id,
          project_name: agent_run.project&.name,
          execution_control_id: control.id,
          execution_control_scope: control.scope,
          execution_control_mode: control.mode,
          result: result
        }
      )
    rescue StandardError => error
      Rails.logger.error(
        message: "execution_control.audit_failed",
        action: action,
        execution_control_id: control.id,
        agent_run_id: agent_run.id,
        error_class: error.class.name,
        error_message: error.message
      )
    end

    def log_control_event(message)
      Rails.logger.info(
        message: message,
        execution_control_id: control.id,
        scope: control.scope,
        mode: control.mode,
        enabled: control.enabled,
        reason: control.reason
      )
    end

    def log_run_event(message, agent_run)
      Rails.logger.info(
        message: message,
        execution_control_id: control.id,
        scope: control.scope,
        mode: control.mode,
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id
      )
    end
  end
end
