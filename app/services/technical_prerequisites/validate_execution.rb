# frozen_string_literal: true

module TechnicalPrerequisites
  # Runs a bounded prerequisite check in an AgentRun's isolated execution
  # environment. This is deliberately not a host diagnostic: placement is
  # checked through the scheduler, and every command executes only after the
  # normal runner/container provision path has established its isolation.
  #
  # The caller supplies commands from a reviewed analyzer recipe, never from an
  # Inbox free-text field. The marketplace tool is not a second recipe input:
  # a tool sidecar carries an image, a port, and its own environment, so the
  # attached tool is exercised by provisioning it and publishing its endpoint
  # to the analyzer. The run's verification_result is the durable,
  # revision-bound evidence record consumed by closeout assessment.
  # @spec PARTIAL-CLOSEOUT-030
  class ValidateExecution
    MAX_OUTPUT_BYTES = 20_000
    COMMAND_TIMEOUT = 5.minutes
    Result = Data.define(:status, :evidence, :setup_action) do
      def success? = status == "completed"
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, native_command:, execution_runner: nil)
      @agent_run = agent_run
      @native_command = validate_command!(native_command)
      @execution_runner = execution_runner
      @evidence = {}
    end

    def call
      inspection = CapabilityInspection.call(agent_run:)
      return persist_unavailable(inspection) unless inspection.runnable?

      execute_validation(inspection)
    rescue Containers::Provision::Error, Containers::GitOperations::Error,
      ExecutionRunners::Error, Containers::McpProvisioner::Error => error
      persist_terminal("failed", error: error.message)
    ensure
      cleanup
    end

    private

    attr_reader :agent_run, :evidence, :native_command

    def execute_validation(inspection)
      persist_planned_host(inspection.host)
      # Provisioning can create the named workspace volume before a container
      # identifier is persisted. Mark cleanup required first so its safety-net
      # volume removal runs even if provisioning raises partway through.
      @environment_provisioned = true
      agent_run.provision_execution_environment(container_host: inspection.host)
      evidence["checkout"] = prepare_checkout
      provision_sidecars
      record_tool_evidence
      native = capture(native_command, env: command_environment)
      persist_terminal(status_for(native), native:)
    end

    # The inspected host must also be the host the container is created on.
    # `workspace_volume_host` resolves the admitted host, so the planned host
    # is persisted before provisioning instead of being passed as a hint.
    def persist_planned_host(host)
      return if host.blank?

      agent_run.update!(external_metadata: agent_run.external_metadata.merge("planned_container_host" => host))
    end

    def prepare_checkout
      execution_environment = Containers::Provision.reconnect(
        agent_run:, container_id: agent_run.container_id, worktree_path: agent_run.worktree_path
      )
      git_operations = Containers::GitOperations.new(container_service: execution_environment, agent_run:)
      git_operations.clone_and_checkout_pinned_commit(
        branch_name: agent_run.branch_name, base_commit_sha: agent_run.base_commit_sha
      )
      git_operations.head_sha
    end

    def provision_sidecars
      execution_runner.provision_mcp_servers(
        agent_run:,
        network: Containers::Provision.network_for(agent_run:)
      )
    end

    def record_tool_evidence
      agent_run.reload
      evidence["tool_endpoints"] = agent_run.tool_sidecar_endpoints
      evidence["tool_sidecars"] = agent_run.tool_sidecar_container_ids
    end

    def command_environment
      endpoints = agent_run.tool_sidecar_endpoints
      return {} if endpoints.blank?

      { "PAID_TOOL_SIDECAR_ENDPOINTS" => endpoints.to_json }
    end

    def execution_runner
      @execution_runner ||= ExecutionRunners.resolve_for(agent_run)
    end

    def capture(command, env:)
      result = agent_run.execute_in_execution_environment(command, timeout: COMMAND_TIMEOUT, stream: false, env:)
      output(result[:stdout], result[:stderr], result[:exit_code])
    rescue Containers::Provision::ExecutionError => error
      output(error.stdout, error.stderr, error.exit_code)
    end

    def output(stdout, stderr, exit_code)
      {
        "stdout" => bounded(stdout),
        "stderr" => bounded(stderr),
        "exit_code" => exit_code
      }
    end

    # Bounds captured output by bytes and repairs the cut so a multi-byte
    # character split by the boundary cannot make the evidence unencodable.
    def bounded(text)
      text.to_s.byteslice(0, MAX_OUTPUT_BYTES).to_s.scrub
    end

    def status_for(native)
      native["exit_code"] == 0 ? "completed" : "failed"
    end

    def persist_unavailable(inspection)
      persist_terminal("unavailable", inspection: inspection.to_h, setup_action: inspection.setup_action,
        cleanup: { "attempted" => false, "reason" => "environment_not_provisioned" })
    end

    def persist_terminal(status, error: nil, **attributes)
      record = base_evidence.merge("status" => status)
        .merge(evidence.stringify_keys).merge(attributes.compact.stringify_keys)
      record["error"] = error.to_s if error
      agent_run.update!(verification_result: agent_run.verification_result.merge(EVIDENCE_KEY => record))
      Result.new(status:, evidence: record, setup_action: record["setup_action"])
    end

    def base_evidence
      {
        "recorded_at" => Time.current.iso8601,
        **runtime_image_evidence,
        "requested_checkout" => agent_run.base_commit_sha,
        "checkout" => nil,
        "tool_identity" => agent_run.tool_sidecar_snapshot.map { |tool| tool.slice("name", "image", "version") },
        "cleanup" => { "attempted" => true }
      }
    end

    def runtime_image_evidence
      recorded_selection = agent_run.reload.runtime_image_selection
      selection = if recorded_selection.is_a?(Hash)
        recorded_selection
      elsif recorded_selection.present?
        { "resolved_image" => recorded_selection }
      else
        {}
      end
      {
        "image" => selection["resolved_image"] || selection["requested_image"] || Containers::Provision::DEFAULTS[:image],
        "image_digest" => selection["digest"],
        "image_selection" => selection.presence
      }.compact
    end

    def cleanup
      return unless @environment_provisioned

      errors = cleanup_errors
      write_cleanup_evidence(completed: errors.empty?, errors:)
    end

    def cleanup_errors
      [
        -> { execution_runner.cleanup_mcp_servers(agent_run:) },
        -> { agent_run.cleanup_execution_environment(force: true) }
      ].filter_map do |cleanup_step|
        cleanup_step.call
        nil
      rescue Containers::Provision::Error, ExecutionRunners::Error, Containers::McpProvisioner::Error => error
        { "class" => error.class.name, "message" => error.message }
      end
    end

    def write_cleanup_evidence(completed:, errors: [])
      record = agent_run.verification_result.fetch(EVIDENCE_KEY, {})
      cleanup = { "attempted" => true, "completed" => completed }
      cleanup["errors"] = errors if errors.any?
      agent_run.update!(verification_result: agent_run.verification_result.merge(
        EVIDENCE_KEY => record.merge("cleanup" => cleanup)
      ))
    end

    def validate_command!(command)
      return command if command.is_a?(String) && command.present?
      return command if command.is_a?(Array) && command.any? && command.all? { |part| part.is_a?(String) && part.present? }

      raise ArgumentError, "validation commands must be non-empty strings or argument arrays"
    end
  end
end
