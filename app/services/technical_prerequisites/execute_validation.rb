# frozen_string_literal: true

module TechnicalPrerequisites
  # Executes a bounded prerequisite probe in an already-provisioned AgentRun.
  # The run's runner owns placement, checkout, sidecars, and cleanup; this
  # service must never fall back to the control-plane host.
  # @spec TECHNICAL-PREREQUISITE-001
  class ExecuteValidation
    MAX_OUTPUT_BYTES = 64 * 1024
    Result = Data.define(:status, :evidence, :setup_action) do
      def success? = status == "succeeded"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, command:, analyzer:, tool: nil, timeout: nil)
      @agent_run = agent_run
      @command = command
      @analyzer = analyzer
      @tool = tool
      @timeout = timeout
    end

    def call
      return record_unavailable("Provisioned execution environment is required.") unless agent_run.container_id.present?
      return record_setup_required if sidecar_required? && !sidecars_enabled?

      record_execution(agent_run.execute_in_execution_environment(command, timeout:, stream: false))
    rescue Containers::Provision::ExecutionError => error
      record_execution_error(error)
    rescue Containers::Provision::Error => error
      record_unavailable(error.message)
    end

    private

    attr_reader :agent_run, :analyzer, :command, :timeout, :tool

    def sidecar_required? = tool.present?

    def sidecars_enabled?
      FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def record_execution(result)
      status = result.success? ? "succeeded" : "failed"
      record(status, stdout: result[:stdout], stderr: result[:stderr], exit_code: result[:exit_code])
    end

    def record_execution_error(error)
      record("failed", stdout: error.stdout, stderr: error.stderr || error.message, exit_code: error.exit_code)
    end

    def record_unavailable(message)
      record("unavailable", stderr: message, exit_code: nil)
    end

    def record_setup_required
      record("setup_required", stderr: "Tool sidecars require marketplace_tool_sidecars authorization.", exit_code: nil,
        setup_action: "Enable marketplace tool sidecars for this scoped pilot, then retry this validation.")
    end

    def record(status, stdout: nil, stderr: nil, exit_code: nil, setup_action: nil)
      evidence = {
        "status" => status,
        "analyzer" => analyzer,
        "tool" => tool,
        "command" => command,
        "exit_code" => exit_code,
        "stdout" => bounded(stdout),
        "stderr" => bounded(stderr),
        "image" => agent_run.external_metadata["image"],
        "checkout" => agent_run.base_commit_sha,
        "tool_endpoints" => agent_run.tool_sidecar_endpoints,
        "recorded_at" => Time.current.iso8601
      }
      agent_run.update!(verification_result: agent_run.verification_result.merge("technical_prerequisite_validation" => evidence))
      Result.new(status:, evidence:, setup_action:)
    end

    def bounded(value)
      value.to_s.byteslice(0, MAX_OUTPUT_BYTES)
    end
  end
end
