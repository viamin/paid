# frozen_string_literal: true

require "digest"

module PrerequisiteExecutionEvidence
  # Runs the narrowly selected prerequisite validation inside an already
  # persisted AgentRun. Commands are supplied by trusted configuration, never
  # by Inbox prose or an operator-entered shell string.
  # @spec PREREQUISITE-EVIDENCE-001
  # @spec PREREQUISITE-EVIDENCE-002
  # @spec PREREQUISITE-EVIDENCE-003
  # @spec PREREQUISITE-EVIDENCE-004
  class Validate
    MAX_OUTPUT_BYTES = 64.kilobytes
    Result = Data.define(:status, :evidence, :message) do
      def successful? = status == "succeeded"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, native_command:, sidecar_command: nil, provisioner: Containers::McpProvisioner.new)
      @agent_run = agent_run
      @native_command = Array(native_command).freeze
      @sidecar_command = sidecar_command && Array(sidecar_command).freeze
      @provisioner = provisioner
    end

    def call
      return prior_success if successful_receipt?

      availability = availability_receipt
      return persist("unavailable", availability, availability.fetch("message")) unless availability.fetch("available")

      return sidecar_authorization_required if sidecar_required? && !sidecars_enabled?

      execute_validation
    rescue StandardError => error
      persist("failed", failure_receipt(error), error.message)
    end

    private

    attr_reader :agent_run, :native_command, :provisioner, :sidecar_command

    def availability_receipt
      backend = Containers.backend_for(agent_run.container_host)
      runner = ExecutionRunners.resolve(backend: backend)
      compatibility = runner.class.capability_compatibility_for(
        requirements: ExecutionRunners::CapabilityRequirements.new(capabilities: [ :direct_exec ]),
        backend: backend,
        agent_run: agent_run,
        log_mismatch: false
      )
      return unavailable("runner_capability", compatibility.error_message) unless compatibility.compatible

      readiness = Containers::HostReadiness.call(backends: [ backend ], force_refresh: true).fetch(backend)
      return unavailable("backend_readiness", readiness[:remediation_hint] || "Prepare a compatible execution backend.") unless readiness[:healthy]

      { "available" => true, "backend" => backend.identifier, "readiness" => readiness }
    rescue StandardError => error
      unavailable("backend_unavailable", error.message)
    end

    def unavailable(reason, message)
      { "available" => false, "reason" => reason, "message" => message }
    end

    def sidecar_authorization_required
      persist(
        "unavailable",
        identity_receipt.merge(
          "reason" => "marketplace_tool_sidecars_disabled",
          "required_action" => "Enable marketplace_tool_sidecars for this project's authorized pilot after approving the selected tool image.",
          "cleanup" => { "attempted" => false, "status" => "not_provisioned" }
        ),
        "Marketplace tool sidecars require scoped pilot authorization."
      )
    end

    def execute_validation
      status = nil
      evidence = nil
      begin
        agent_run.provision_execution_environment
        provisioner.provision(agent_run) if sidecar_required?
        native = execute(native_command, kind: "native_analyzer")
        sidecar = sidecar_required? ? execute(sidecar_command, kind: "tool_sidecar") : nil
        status = status_for(native, sidecar)
        evidence = identity_receipt.merge("commands" => [ native, sidecar ].compact)
      ensure
        evidence ||= identity_receipt
        @cleanup = cleanup_receipt
        evidence["cleanup"] = @cleanup
      end

      persist(status, evidence, status_message(status))
    end

    def execute(command, kind:)
      result = agent_run.execute_in_execution_environment(command, stream: false)
      receipt = {
        "kind" => kind,
        "stdout" => bounded_output(result[:stdout]),
        "stderr" => bounded_output(result[:stderr]),
        "exit_code" => result[:exit_code] || (result.success? ? 0 : 1),
        "success" => result.success?
      }
      agent_run.log!(result.success? ? "stdout" : "stderr", receipt.to_json, metadata: { "prerequisite_execution_evidence" => kind })
      receipt
    end

    def cleanup_receipt
      provisioner.cleanup(agent_run) if sidecar_required?
      agent_run.cleanup_execution_environment(force: true)
      { "attempted" => true, "status" => "completed" }
    rescue StandardError => error
      { "attempted" => true, "status" => "failed", "error" => error.message }
    end

    def status_for(native, sidecar)
      return "cancelled" if agent_run.status == "cancelled"
      return "succeeded" if [ native, sidecar ].compact.all? { |command| command.fetch("success") }

      [ native, sidecar ].compact.any? { |command| command.fetch("success") } ? "partial" : "failed"
    end

    def persist(status, evidence, message)
      receipt = identity_receipt.merge(evidence).merge("status" => status, "recorded_at" => Time.current.iso8601)
      agent_run.update!(verification_result: agent_run.verification_result.merge("prerequisite_execution_validation" => receipt))
      Result.new(status:, evidence: receipt, message:)
    end

    def prior_success
      receipt = agent_run.verification_result.fetch("prerequisite_execution_validation")
      Result.new(status: "succeeded", evidence: receipt, message: "Current prerequisite validation already succeeded.")
    end

    def successful_receipt?
      receipt = agent_run.verification_result["prerequisite_execution_validation"]
      receipt&.fetch("status", nil) == "succeeded" && receipt["scope_digest"] == scope_digest
    end

    def identity_receipt
      {
        "agent_run_id" => agent_run.id,
        "checkout" => agent_run.base_commit_sha,
        "image" => agent_run.external_metadata["image"],
        "runner_handle" => agent_run.runner_handle,
        "tool_snapshot" => agent_run.tool_sidecar_snapshot,
        "tool_endpoints" => agent_run.tool_sidecar_endpoints,
        "scope_digest" => scope_digest
      }
    end

    def failure_receipt(error)
      identity_receipt.merge("error_class" => error.class.name, "error" => error.message, "cleanup" => @cleanup).compact
    end

    def sidecar_required? = sidecar_command.present?
    def sidecars_enabled? = FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    def status_message(status) = status == "succeeded" ? "Prerequisite execution validation succeeded." : "Prerequisite execution validation #{status}."

    def scope_digest
      @scope_digest ||= Digest::SHA256.hexdigest(
        [ agent_run.base_commit_sha, agent_run.external_metadata["image"], native_command, sidecar_command, agent_run.tool_sidecar_snapshot ].to_json
      )
    end

    def bounded_output(output)
      output.to_s.byteslice(0, MAX_OUTPUT_BYTES)
    end
  end
end
