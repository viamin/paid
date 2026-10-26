# frozen_string_literal: true

module PartialCloseouts
  # Runs the narrowly-scoped live check required by a closeout prerequisite.
  # It deliberately uses the run's execution environment; this service never
  # falls back to the control-plane host when a compatible backend is absent.
  # @spec PARTIAL-CLOSEOUT-030 PARTIAL-CLOSEOUT-031 PARTIAL-CLOSEOUT-032
  class ValidateExecutionPrerequisite
    REQUIRED_CAPABILITY = :direct_exec
    OUTPUT_LIMIT = 10_000

    Result = Data.define(:status, :evidence, :next_action) do
      def successful? = status == "completed"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, native_command:, sidecar_command: nil)
      @agent_run = agent_run
      @native_command = native_command
      @sidecar_command = sidecar_command
    end

    def call
      capability = capability_evidence
      return persist("unavailable", capability, capability[:next_action]) unless capability[:compatible]

      return persist("unavailable", policy_evidence, policy_evidence[:next_action]) unless sidecar_permitted?

      provision_and_execute(capability)
    rescue Containers::Provision::Error, ExecutionRunners::Error => error
      persist("failed", error_evidence(error), "Correct the execution-environment failure, then start a new validation run.")
    ensure
      cleanup if defined?(@provisioned) && @provisioned
    end

    private

    attr_reader :agent_run, :native_command, :sidecar_command

    def capability_evidence
      backend = Containers.backend_for(agent_run.workspace_volume_host)
      available = ExecutionRunners.resolve(backend: backend).class.capabilities(backend: backend)
      missing = available.missing([ REQUIRED_CAPABILITY ])
      {
        compatible: missing.empty?,
        available_capabilities: available.to_a,
        missing_capabilities: missing,
        backend: backend.respond_to?(:identifier) ? backend.identifier : backend.class.name,
        next_action: "Select an execution host with direct exec capability; retrying this host unchanged cannot collect the artifact."
      }
    rescue Containers::Backends::Resolver::UnknownBackendError => error
      { compatible: false, available_capabilities: [], missing_capabilities: [ REQUIRED_CAPABILITY ], error: error.message,
        next_action: "Configure an authorized execution host with direct exec capability." }
    end

    def sidecar_permitted?
      sidecar_command.blank? || FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def policy_evidence
      { compatible: false, policy: "marketplace_tool_sidecars", enabled: false,
        next_action: "Request scoped pilot authorization for marketplace tool sidecars; Paid will not enable the flag automatically." }
    end

    def provision_and_execute(capability)
      agent_run.provision_execution_environment
      @provisioned = true
      native = execute(native_command)
      sidecar = sidecar_command.present? ? execute(sidecar_command) : nil
      status = [ native, sidecar ].compact.all? { |result| result[:exit_code].zero? } ? "completed" : "partial"
      persist(status, capability.merge(native: native, sidecar: sidecar, identity: execution_identity),
        status == "completed" ? nil : "Review the recorded exit status and output before changing the selected analyzer or endpoint.")
    end

    def execute(command)
      result = agent_run.execute_in_execution_environment(command, stream: false)
      { stdout: result[:stdout].to_s.byteslice(0, OUTPUT_LIMIT), stderr: result[:stderr].to_s.byteslice(0, OUTPUT_LIMIT),
        exit_code: result[:exit_code] || (result.success? ? 0 : 1) }
    rescue Containers::Provision::ExecutionError => error
      { stdout: error.stdout.to_s.byteslice(0, OUTPUT_LIMIT), stderr: error.stderr.to_s.byteslice(0, OUTPUT_LIMIT), exit_code: error.exit_code || 1 }
    end

    def execution_identity
      { image: agent_run.runner_handle&.dig("image") || agent_run.external_metadata["resolved_image"],
        checkout: agent_run.base_commit_sha, container_id: agent_run.container_id,
        tool_sidecar_endpoints: agent_run.tool_sidecar_endpoints }
    end

    def cleanup
      agent_run.cleanup_execution_environment
      @cleanup = { completed: true }
    rescue Containers::Provision::Error, ExecutionRunners::Error => error
      @cleanup = { completed: false, error: error.message }
    ensure
      merge_cleanup_evidence!
    end

    def persist(status, evidence, next_action)
      payload = { "status" => status, "recorded_at" => Time.current.iso8601, "evidence" => evidence.compact,
        "next_action" => next_action, "cleanup" => @cleanup || { completed: false, pending: true } }
      agent_run.update!(verification_result: agent_run.verification_result.merge("execution_prerequisite_validation" => payload))
      Result.new(status:, evidence: payload, next_action:)
    end

    def merge_cleanup_evidence!
      payload = agent_run.verification_result.fetch("execution_prerequisite_validation", nil)
      return unless payload

      agent_run.update!(verification_result: agent_run.verification_result.merge(
        "execution_prerequisite_validation" => payload.merge("cleanup" => @cleanup)
      ))
    end

    def error_evidence(error)
      { error_class: error.class.name, error: error.message, identity: execution_identity }
    end
  end
end
