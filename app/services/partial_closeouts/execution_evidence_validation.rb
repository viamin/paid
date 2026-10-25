# frozen_string_literal: true

module PartialCloseouts
  # Collects execution evidence without treating local worker Docker state as
  # a verdict about the selected execution backend.
  # @spec PARTIAL-CLOSEOUT-030
  class ExecutionEvidenceValidation
    Result = Data.define(:outcome, :artifact, :next_action) do
      def successful? = outcome == "executed"
    end

    REQUIRED_CAPABILITIES = %i[direct_exec persistent_workspace].freeze
    OUTPUT_LIMIT = 10_000

    def self.call(...) = new(...).call

    def initialize(agent_run:, command:, tool_sidecar: nil, backend: Containers.backend)
      @agent_run = agent_run
      @command = command
      @tool_sidecar = tool_sidecar
      @backend = backend
    end

    def call
      return record(unavailable_result) unless compatibility.compatible
      return record(tool_policy_result) if tool_policy_result

      execute_and_record
    rescue ExecutionRunners::Base::ProvisionError, Containers::Provision::Error => error
      record(failed_result(error))
    ensure
      cleanup! if @provisioned
    end

    private

    attr_reader :agent_run, :backend, :command, :tool_sidecar

    def compatibility
      @compatibility ||= runner_class.capability_compatibility_for(
        requirements: ExecutionRunners::CapabilityRequirements.new(capabilities: REQUIRED_CAPABILITIES),
        backend:, agent_run:
      )
    end

    def runner_class
      @runner_class ||= ExecutionRunners.resolve(backend:).class
    end

    def tool_policy_result
      return unless tool_sidecar
      return if FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)

      Result.new(
        outcome: "unavailable",
        artifact: base_artifact.merge("tool_sidecar" => tool_sidecar, "policy" => "marketplace_tool_sidecars_disabled"),
        next_action: "Enable marketplace_tool_sidecars for this authorized pilot before validating #{tool_sidecar.fetch('name')}."
      )
    end

    def unavailable_result
      Result.new(outcome: "unavailable", artifact: base_artifact.merge("compatibility_error" => compatibility.error_message),
        next_action: compatibility.error_message)
    end

    def execute_and_record
      agent_run.provision_execution_environment
      @provisioned = true
      result = agent_run.execute_in_execution_environment(command, stream: false)
      outcome = result.success? ? "executed" : "failed"
      record(Result.new(outcome:, artifact: base_artifact.merge(execution_artifact(result)), next_action: nil))
    end

    def failed_result(error)
      Result.new(outcome: "failed", artifact: base_artifact.merge("error" => error.message.to_s.truncate(OUTPUT_LIMIT)),
        next_action: "Review the execution backend failure before retrying.")
    end

    def execution_artifact(result)
      { "stdout" => result[:stdout].to_s.truncate(OUTPUT_LIMIT), "stderr" => result[:stderr].to_s.truncate(OUTPUT_LIMIT),
        "exit_code" => result[:exit_code], "tool_endpoints" => agent_run.tool_sidecar_endpoints }
    end

    def base_artifact
      { "runner_type" => runner_class.name, "runner_capabilities" => runner_class.capabilities(backend:).to_a.map(&:to_s),
        "runner_backend" => backend.respond_to?(:identifier) ? backend.identifier : backend.class.name,
        "image" => agent_run.runtime_image_selection, "checkout" => agent_run.base_commit_sha, "command" => command }
    end

    def cleanup!
      agent_run.cleanup_execution_environment(force: true)
      persist_cleanup("completed")
    rescue ExecutionRunners::Base::ProvisionError, Containers::Provision::Error => error
      persist_cleanup("failed", error.message)
    end

    def persist_cleanup(status, error = nil)
      validation = agent_run.reconciliation.fetch("execution_validation", {}).merge("cleanup" => status)
      validation["cleanup_error"] = error.to_s.truncate(OUTPUT_LIMIT) if error
      agent_run.update!(reconciliation: agent_run.reconciliation.merge("execution_validation" => validation))
    end

    def record(result)
      artifact = result.artifact.merge("outcome" => result.outcome, "next_action" => result.next_action).compact
      agent_run.update!(reconciliation: agent_run.reconciliation.merge("execution_validation" => artifact))
      Result.new(outcome: result.outcome, artifact:, next_action: result.next_action)
    end
  end
end
