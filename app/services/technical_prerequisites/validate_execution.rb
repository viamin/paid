# frozen_string_literal: true

module TechnicalPrerequisites
  # Runs a fixed, operator-authorized prerequisite probe in Paid's normal
  # isolated execution environment. It intentionally has no host-command path.
  # @spec PARTIAL-CLOSEOUT-030
  # @spec PARTIAL-CLOSEOUT-031
  class ValidateExecution
    Result = Data.define(:status, :details) do
      def succeeded? = status == "succeeded"
      def unavailable? = status == "unavailable"
    end

    MAX_OUTPUT_BYTES = 64.kilobytes

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, command:, analyzer:, prerequisite_id:, tool_name: nil,
      scheduler: Containers::BackendScheduler, mcp_provisioner: Containers::McpProvisioner.new)
      @agent_run = agent_run
      @command = command
      @analyzer = analyzer
      @prerequisite_id = prerequisite_id
      @tool_name = tool_name
      @scheduler = scheduler
      @mcp_provisioner = mcp_provisioner
    end

    def call
      return unavailable("Pinned checkout is missing; prepare a fresh validation run.") if agent_run.base_commit_sha.blank?
      return unavailable(tool_rollout_action) if tool_required? && !tool_sidecars_enabled?

      backend = compatible_backend
      return unavailable("No compatible isolated execution backend is available. Configure a compatible Docker host and retry.") unless backend

      execute_on(backend)
    rescue Containers::McpProvisioner::Error => error
      unavailable("Tool sidecar is unavailable: #{error.message}. Allowlist the image or approve the scoped pilot.")
    rescue Containers::Provision::Error, ExecutionRunners::ProvisionError => error
      terminal("failed", error: error.message)
    ensure
      cleanup
    end

    private

    attr_reader :agent_run, :analyzer, :command, :mcp_provisioner, :prerequisite_id, :scheduler, :tool_name

    def compatible_backend
      result = scheduler.call(agent_run: agent_run)
      result.candidate_hosts.first
    end

    def execute_on(backend)
      agent_run.provision_execution_environment(container_host: backend)
      @environment_provisioned = true
      provision_tools if tool_required?
      response = agent_run.execute_in_execution_environment(command, stream: false)
      status = response.success? ? "succeeded" : "failed"
      terminal(status, response: response, backend: backend)
    end

    def provision_tools
      mcp_provisioner.provision(agent_run, network: NetworkPolicy::NETWORK_NAME)
      @tools_provisioned = true
    end

    def tool_required?
      tool_name.present?
    end

    def tool_sidecars_enabled?
      FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def tool_rollout_action
      "Enable marketplace_tool_sidecars for this project's scoped pilot before validating #{tool_name}."
    end

    def unavailable(message)
      terminal("unavailable", error: message)
    end

    def terminal(status, response: nil, backend: nil, error: nil)
      details = evidence(status, response:, backend:, error:)
      persist(details)
      Result.new(status:, details:)
    end

    def evidence(status, response:, backend:, error:)
      {
        "status" => status,
        "prerequisite_id" => prerequisite_id,
        "checkout_sha" => agent_run.base_commit_sha,
        "analyzer" => analyzer,
        "tool" => tool_name,
        "backend" => backend,
        "image" => agent_run.external_metadata.to_h["runtime_image"],
        "stdout" => bounded_output(response&.[](:stdout)),
        "stderr" => bounded_output(response&.[](:stderr) || error),
        "exit_status" => response&.[](:exit_code),
        "endpoints" => agent_run.tool_sidecar_endpoints,
        "recorded_at" => Time.current.iso8601
      }.compact
    end

    def persist(details)
      agent_run.with_lock do
        agent_run.update!(verification_result: agent_run.verification_result.to_h.merge(
          "technical_prerequisite_validation" => details
        ))
      end
      ExecutionAuditEvents::Lifecycle.record(
        event_name: "execution.technical_prerequisite_validated",
        actor_id: "technical_prerequisites.validate_execution",
        agent_run: agent_run,
        backend: details["backend"],
        image_reference: details["image"],
        metadata: details.except("stdout", "stderr")
      )
    end

    def cleanup
      mcp_provisioner.cleanup(agent_run) if @tools_provisioned
      agent_run.cleanup_execution_environment(force: true) if @environment_provisioned
      record_cleanup("completed") if @tools_provisioned || @environment_provisioned
    rescue StandardError => error
      record_cleanup_failure(error)
    end

    def record_cleanup(status)
      result = agent_run.verification_result.to_h
      validation = result.fetch("technical_prerequisite_validation", {}).merge("cleanup" => status)
      agent_run.update!(verification_result: result.merge("technical_prerequisite_validation" => validation))
    end

    def record_cleanup_failure(error)
      record_cleanup("failed")
    end

    def bounded_output(value)
      value.to_s.byteslice(0, MAX_OUTPUT_BYTES).presence
    end
  end
end
