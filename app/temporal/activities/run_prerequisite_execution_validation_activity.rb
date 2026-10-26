# frozen_string_literal: true

module Activities
  # Captures a small, non-repository workload through the same isolated
  # environment used by agent runs. No host shell or daemon socket is exposed.
  # @spec PREREQUISITE-EXECUTION-002
  class RunPrerequisiteExecutionValidationActivity < BaseActivity
    activity_name "RunPrerequisiteExecutionValidation"

    NATIVE_PROBE = [ "sh", "-lc", "ruby --version" ].freeze

    def execute(input)
      agent_run = AgentRun.find(input.fetch(:agent_run_id))
      track_phase(agent_run_id: agent_run.id, phase_key: "run_prerequisite_execution_validation",
        phase_group: "agent", agent_run: agent_run) do
        agent_run.start!
        return record_unavailable(agent_run) unless FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)

        execute_validation(agent_run)
      end
    rescue StandardError => e
      record_failure(agent_run, e) if agent_run
      raise
    ensure
      cleanup(agent_run) if agent_run
    end

    private

    def execute_validation(agent_run)
      agent_run.provision_execution_environment
      Containers::McpProvisioner.new.provision(agent_run,
        network: Containers::Provision.network_for(agent_run: agent_run))
      result = agent_run.execute_in_execution_environment(NATIVE_PROBE, timeout: 60, stream: false)
      record(agent_run, "succeeded", result: result)
      agent_run.complete!
      ProcessRunQueueJob.perform_later
      { agent_run_id: agent_run.id, execution_evidence_recorded: true }
    end

    def record_unavailable(agent_run)
      record(agent_run, "unavailable", required_action: "Enable marketplace_tool_sidecars for an authorized pilot tenant before requesting sidecar validation.")
      agent_run.complete!
      { agent_run_id: agent_run.id, execution_evidence_recorded: false, status: "unavailable" }
    end

    def record_failure(agent_run, error)
      record(agent_run, "failed", error: error.message)
      agent_run.fail!(error: error.message) unless agent_run.finished?
    end

    def record(agent_run, status, result: nil, required_action: nil, error: nil)
      evidence = {
        "status" => status,
        "image" => agent_run.container_id,
        "checkout" => agent_run.base_commit_sha,
        "tool_sidecars" => agent_run.tool_sidecar_snapshot,
        "endpoints" => agent_run.tool_sidecar_endpoints,
        "stdout" => result&.stdout,
        "stderr" => result&.stderr,
        "exit_code" => result&.exit_code,
        "required_action" => required_action,
        "error" => error,
        "recorded_at" => Time.current.iso8601
      }.compact
      agent_run.update!(reconciliation: agent_run.reconciliation.merge("prerequisite_execution_validation" => evidence))
    end

    def cleanup(agent_run)
      Containers::McpProvisioner.new.cleanup(agent_run)
      agent_run.cleanup_execution_environment(force: true)
      agent_run.reload.update!(reconciliation: agent_run.reconciliation.deep_merge(
        "prerequisite_execution_validation" => { "cleanup" => "completed" }
      ))
    rescue StandardError => e
      agent_run.reload.update!(reconciliation: agent_run.reconciliation.deep_merge(
        "prerequisite_execution_validation" => { "cleanup" => "failed", "cleanup_error" => e.message }
      ))
      Rails.logger.warn(message: "prerequisite_execution_validation.cleanup_failed", agent_run_id: agent_run.id, error_class: e.class.name)
    end
  end
end
