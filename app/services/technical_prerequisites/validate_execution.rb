# frozen_string_literal: true

module TechnicalPrerequisites
  # Runs a bounded prerequisite check in an AgentRun's isolated execution
  # environment. This is deliberately not a host diagnostic: placement is
  # checked through the scheduler, and every command executes only after the
  # normal runner/container provision path has established its isolation.
  #
  # The caller supplies commands from a reviewed analyzer/tool recipe, never
  # from an Inbox free-text field. The run's verification_result is the
  # durable, revision-bound evidence record consumed by closeout assessment.
  # @spec PARTIAL-CLOSEOUT-030
  class ValidateExecution
    MAX_OUTPUT_BYTES = 20_000
    Result = Data.define(:status, :evidence, :setup_action) do
      def success? = status == "completed"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, native_command:, sidecar_command: nil, provisioner: Containers::McpProvisioner.new)
      @agent_run = agent_run
      @native_command = validate_command!(native_command)
      @sidecar_command = sidecar_command && validate_command!(sidecar_command)
      @provisioner = provisioner
    end

    def call
      inspection = CapabilityInspection.call(agent_run:)
      return persist_unavailable(inspection) unless inspection.runnable?

      execute_validation(inspection)
    rescue Containers::Provision::Error, ExecutionRunners::Error, Containers::McpProvisioner::Error => error
      persist_terminal("failed", error: error.message)
    ensure
      cleanup
    end

    private

    attr_reader :agent_run, :native_command, :provisioner, :sidecar_command

    def execute_validation(inspection)
      agent_run.provision_execution_environment(container_host: inspection.host)
      @environment_provisioned = true
      provisioner.provision(agent_run)
      native = capture(native_command)
      sidecar = sidecar_command && capture(sidecar_command)
      status = [ native, sidecar ].compact.all? { |result| result["exit_code"] == 0 } ? "completed" : "failed"
      persist_terminal(status, native: native, sidecar: sidecar, inspection: inspection.to_h)
    end

    def capture(command)
      result = agent_run.execute_in_execution_environment(command, stream: false)
      output(result[:stdout], result[:stderr], result[:exit_code])
    rescue Containers::Provision::ExecutionError => error
      output(error.stdout, error.stderr, error.exit_code)
    end

    def output(stdout, stderr, exit_code)
      { "stdout" => stdout.to_s.byteslice(0, MAX_OUTPUT_BYTES), "stderr" => stderr.to_s.byteslice(0, MAX_OUTPUT_BYTES), "exit_code" => exit_code }
    end

    def persist_unavailable(inspection)
      persist_terminal("unavailable", inspection: inspection.to_h, setup_action: inspection.setup_action,
        cleanup: { "attempted" => false, "reason" => "environment_not_provisioned" })
    end

    def persist_terminal(status, error: nil, **attributes)
      evidence = {
        "status" => status,
        "recorded_at" => Time.current.iso8601,
        "image" => agent_run.external_metadata["runtime_image"],
        "checkout" => agent_run.base_commit_sha,
        "tool_identity" => agent_run.tool_sidecar_snapshot.map { |tool| tool.slice("name", "image", "version") },
        "cleanup" => { "attempted" => true }
      }.merge(attributes.compact.stringify_keys)
      evidence["error"] = error.to_s if error
      agent_run.update!(verification_result: agent_run.verification_result.merge("technical_prerequisite_validation" => evidence))
      Result.new(status:, evidence:, setup_action: evidence["setup_action"])
    end

    def cleanup
      return unless @environment_provisioned

      provisioner.cleanup(agent_run)
      agent_run.cleanup_execution_environment(force: true)
      update_cleanup(completed: true)
    rescue Containers::Provision::Error, ExecutionRunners::Error, Containers::McpProvisioner::Error => error
      agent_run.update!(verification_result: agent_run.verification_result.merge(
        "technical_prerequisite_validation" => agent_run.verification_result.fetch("technical_prerequisite_validation", {}).merge(
          "cleanup" => { "attempted" => true, "completed" => false, "error" => error.message }
        )
      ))
    end

    def update_cleanup(completed:)
      agent_run.update!(verification_result: agent_run.verification_result.merge(
        "technical_prerequisite_validation" => agent_run.verification_result.fetch("technical_prerequisite_validation", {}).merge(
          "cleanup" => { "attempted" => true, "completed" => completed }
        )
      ))
    end

    def validate_command!(command)
      raise ArgumentError, "validation commands must be non-empty argument arrays" unless command.is_a?(Array) && command.all? { |part| part.is_a?(String) } && command.any?(&:present?)

      command
    end
  end
end
