# frozen_string_literal: true

module MaintenanceRuns
  # Runs a trusted prerequisite probe through the normal isolated AgentRun
  # lifecycle. Placement readiness, not the control-plane host, decides whether
  # Paid has an execution environment.
  # @spec TECHNICAL-PREREQUISITE-001
  class TechnicalPrerequisiteValidation
    Result = Data.define(:status, :agent_run, :message, :evidence) do
      def success? = status == "succeeded"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, command:, requires_tool_sidecar: false, endpoint_command: nil)
      @agent_run = agent_run
      @command = Array(command)
      @requires_tool_sidecar = requires_tool_sidecar
      @endpoint_command = endpoint_command && Array(endpoint_command)
    end

    def call
      return unavailable(:cancelled, "Validation was cancelled before execution.") if cancelled?
      return unavailable(:pinned_checkout_missing, "The validation run has no pinned checkout.") if agent_run.base_commit_sha.blank?
      return unavailable(:no_compatible_backend, "No compatible isolated execution backend is currently ready.") unless backend
      return unavailable(:tool_rollout_not_authorized, tool_setup_action) if requires_tool_sidecar && !tool_sidecars_enabled?
      return unavailable(:tool_not_attached, "Select an allowlisted tool attachment before starting validation.") if requires_tool_sidecar && agent_run.tool_sidecar_snapshot.blank?

      prepare_run!
      return unavailable(:cancelled, "Validation was cancelled during preparation.") if cancelled?

      provisioner.provision(agent_run) if requires_tool_sidecar
      native_result = agent_run.execute_in_execution_environment(command, stream: false)
      outcome = native_result.success? && endpoint_command.present? ? endpoint_probe : native_result
      complete(outcome)
    rescue Containers::Provision::Error => error
      failed(error)
    ensure
      cleanup
    end

    private

    attr_reader :agent_run, :command, :endpoint_command

    def backend
      @backend ||= DockerHost.placement_ready_for_restricted_agent_runs
        .where(account_id: agent_run.project.account_id).order(:id).first
    end

    def tool_sidecars_enabled? = FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)

    def prepare_run!
      agent_run.update!(container_host: backend.identifier) unless agent_run.container_host == backend.identifier
      agent_run.provision_execution_environment
      @execution_started = true
    end

    def provisioner = @provisioner ||= Containers::McpProvisioner.new

    def endpoint_probe
      agent_run.execute_in_execution_environment(
        endpoint_command,
        stream: false,
        env: { "PAID_TOOL_SIDECAR_ENDPOINTS" => agent_run.tool_sidecar_endpoints.to_json }
      )
    end

    def complete(result)
      status = result.success? ? "succeeded" : "failed"
      evidence = execution_evidence(status:, result:)
      persist(evidence)
      Result.new(status:, agent_run:, message: result.success? ? "Validation completed." : "Validation command failed.", evidence:)
    end

    def failed(error)
      evidence = execution_evidence(status: "failed", error:)
      persist(evidence)
      Result.new(status: "failed", agent_run:, message: error.message, evidence:)
    end

    def unavailable(code, message)
      evidence = execution_evidence(status: "unavailable", unavailable_reason: code, message:)
      persist(evidence)
      Result.new(status: "unavailable", agent_run:, message:, evidence:)
    end

    def cleanup
      return unless @execution_started

      provisioner.cleanup_tool_sidecars(agent_run) if requires_tool_sidecar
      agent_run.cleanup_execution_environment
      merge_cleanup_evidence("completed")
    rescue Containers::Provision::Error => error
      merge_cleanup_evidence("failed", error.message)
    end

    def execution_evidence(status:, result: nil, error: nil, unavailable_reason: nil, message: nil)
      {
        "technical_prerequisite_validation" => {
          "status" => status,
          "unavailable_reason" => unavailable_reason,
          "message" => message || error&.message,
          "checkout_sha" => agent_run.base_commit_sha,
          "backend" => backend&.identifier,
          "tool_identity" => agent_run.tool_sidecar_snapshot,
          "tool_endpoints" => agent_run.tool_sidecar_endpoints,
          "stdout" => result&.[](:stdout).to_s,
          "stderr" => result&.[](:stderr).to_s,
          "exit_code" => result&.[](:exit_code),
          "recorded_at" => Time.current.utc.iso8601
        }.compact
      }
    end

    def persist(evidence)
      agent_run.update!(verification_result: agent_run.verification_result.to_h.merge(evidence))
    end

    def merge_cleanup_evidence(status, error = nil)
      evidence = agent_run.verification_result.to_h.deep_merge(
        "technical_prerequisite_validation" => { "cleanup" => { "status" => status, "error" => error, "recorded_at" => Time.current.utc.iso8601 }.compact }
      )
      agent_run.update!(verification_result: evidence)
    end

    def requires_tool_sidecar = @requires_tool_sidecar

    def cancelled? = agent_run.status == "cancelled"

    def tool_setup_action
      "A project owner must authorize the marketplace_tool_sidecars pilot for this project before the selected tool can run."
    end
  end
end
