# frozen_string_literal: true

require "tmpdir"

module PrerequisiteExecutions
  # Executes one bounded validation attempt inside its job, reusing the
  # shipped execution contract step for step: provision through
  # AgentRun#provision_execution_environment (a Paid-managed temporary
  # workspace bind-mounted into the isolated run container — never a host
  # shell or a Docker-socket mount), pin the checkout through
  # Containers::GitOperations, run the native analyzer and the tool-sidecar
  # endpoint call through AgentRun#execute_in_execution_environment, and
  # always clean up, recording the disposition as evidence.
  #
  # @spec PREREQ-EXEC-007 @spec PREREQ-EXEC-008 @spec PREREQ-EXEC-009
  # @spec PREREQ-EXEC-010 @spec PREREQ-EXEC-011 @spec PREREQ-EXEC-012
  # @spec PREREQ-EXEC-013
  class Runner
    DEFAULT_TIMEOUT_SECONDS = 600
    OUTPUT_BOUND_BYTES = 8192
    ENDPOINT_PROBE_TIMEOUT_SECONDS = 30

    def self.call(validation)
      new(validation).call
    end

    def initialize(validation, mcp_provisioner: Containers::McpProvisioner.new,
      git_operations: Containers::GitOperations, logger: Rails.logger)
      @validation = validation
      @mcp_provisioner = mcp_provisioner
      @git_operations = git_operations
      @logger = logger
      @steps = []
      @identity = {}
    end

    def call
      return unless claim!

      Dir.mktmpdir("paid-prereq-validation-#{validation.id}-") do |workspace_path|
        execute_contract(workspace_path)
      end
      finalize!
    end

    private

    attr_reader :validation, :mcp_provisioner, :git_operations, :logger, :identity

    def execute_contract(workspace_path)
      run = validation.agent_run
      run.update!(worktree_path: workspace_path)

      provision_environment!(run)
      return if cancelled?

      # The analyzer and sidecar steps both operate on the pinned checkout;
      # a failed checkout aborts the remaining steps rather than collecting
      # evidence against the wrong (or empty) workspace.
      return unless prepare_checkout!(run, workspace_path)
      return if cancelled?

      provision_tool_sidecar!(run)
      return if cancelled?

      run_native_analyzer!(run)
    rescue Containers::Provision::Error, ExecutionRunners::Error => e
      record_unavailable(e)
    rescue StandardError => e
      validation.update!(last_error: "#{e.class}: #{e.message}")
      logger.error(
        message: "prerequisite_executions.validation_aborted",
        prerequisite_execution_validation_id: validation.id,
        error_class: e.class.name,
        error_message: e.message
      )
    ensure
      Cleanup.call(validation, mcp_provisioner: mcp_provisioner)
    end

    # Claims the pending attempt; a cancelled-while-queued attempt owns no
    # resources, so there is nothing to run or clean up.
    def claim!
      validation.with_lock do
        validation.reload
        return false unless validation.pending?

        validation.update!(status: "preparing", started_at: Time.current)
      end
      true
    end

    # Provisioning failure is an environment-capability failure: nothing
    # executed, so the attempt reports unavailable rather than failed.
    # @spec PREREQ-EXEC-011
    def provision_environment!(run)
      run.provision_execution_environment
      run.reload
      identity["run"] = {
        "agent_run_id" => run.id,
        "container_id" => run.container_id,
        "container_host" => run.container_host,
        "image" => container_image_for(run)
      }
      persist_identity!
      validation.transition!("running")
    end

    # @spec PREREQ-EXEC-008
    def prepare_checkout!(run, workspace_path)
      step(PrerequisiteExecutionValidation::CHECKOUT_IDENTITY_STEP,
        command: "git clone + checkout #{validation.branch}") do
        service = Containers::Provision.reconnect(
          agent_run: run, container_id: run.container_id, worktree_path: workspace_path
        )
        git = git_operations.new(container_service: service, agent_run: run)
        git.clone_and_checkout_branch(branch_name: validation.branch, pull_request_number: nil, persist: false)
        commit = git.head_sha
        run.update!(branch_name: validation.branch, base_commit_sha: commit)
        identity["checkout"] = { "branch" => validation.branch, "commit" => commit }
        { "commit" => commit }
      end
    end

    # The full sidecar artifact: attach through the marketplace path,
    # provision through the flag- and allowlist-gated provisioner, then call
    # the provisioned endpoint from inside the run container.
    # @spec PREREQ-EXEC-010
    def provision_tool_sidecar!(run)
      tool = validation.tool_contract
      return unless tool

      step(PrerequisiteExecutionValidation::TOOL_SIDECAR_STEP,
        command: "tool sidecar lifecycle #{tool['name']}") do
        MarketplaceEntries::AttachToRun.call(agent_run: run, manual_entry_ids: [ tool["marketplace_entry_id"] ])
        mcp_provisioner.provision(run)
        run.reload
        endpoints = Array(run.tool_sidecar_endpoints)
        if endpoints.empty?
          raise Containers::McpProvisioner::Error,
            "tool sidecar #{tool['name']} did not report a healthy endpoint"
        end

        identity["tool"] = {
          "name" => tool["name"],
          "image" => tool["image"],
          "endpoints" => endpoints
        }
        persist_identity!
        { "endpoints" => endpoints }.merge(call_endpoint(run, endpoints.first))
      end
    end

    # @spec PREREQ-EXEC-009
    def run_native_analyzer!(run)
      command = validation.contract["native_command"]
      step(PrerequisiteExecutionValidation::NATIVE_ANALYZER_STEP, command: command) do
        execute_in_run(run, command, timeout: DEFAULT_TIMEOUT_SECONDS)
      end
    end

    # The documented endpoint called from the paired run through the same
    # execution contract, with the response recorded as evidence.
    def call_endpoint(run, endpoint)
      url = endpoint["url"].to_s
      result = execute_in_run(run,
        "curl -fsS --max-time #{ENDPOINT_PROBE_TIMEOUT_SECONDS} #{url}",
        timeout: ENDPOINT_PROBE_TIMEOUT_SECONDS + 10)
      result.merge("endpoint" => url)
    end

    def execute_in_run(run, command, timeout:)
      output = run.execute_in_execution_environment(command, timeout: timeout, stream: false)
      {
        "exit_code" => output[:exit_code],
        "stdout" => bound(output[:stdout]),
        "stderr" => bound(output[:stderr])
      }
    end

    def step(key, command)
      started_at = Time.current
      details = yield
      record_step(key: key, command: command,
        status: step_succeeded?(details) ? "succeeded" : "failed",
        details: details, started_at: started_at)
      details
    rescue StandardError => e
      record_step(key: key, command: command, status: "failed",
        details: { "error_class" => e.class.name, "error_message" => e.message },
        started_at: started_at)
      nil
    end

    def step_succeeded?(details)
      return false if details["error_class"].present?

      return details["exit_code"] == 0 if details.key?("exit_code")

      true
    end

    def record_step(key:, command:, status:, details:, started_at:)
      @steps << {
        "key" => key,
        "command" => command,
        "status" => status,
        "started_at" => started_at.iso8601,
        "finished_at" => Time.current.iso8601
      }.merge(details)
      validation.update!(steps: @steps)
    end

    def bound(output)
      output.to_s.dup.force_encoding("UTF-8").scrub[0, OUTPUT_BOUND_BYTES]
    end

    def container_image_for(run)
      return nil if run.container_id.blank?

      backend = run.container_host.present? ? Containers.backend_for(run.container_host) : Containers.backend
      backend.get_container(run.container_id).json.dig("Config", "Image")
    rescue StandardError
      nil
    end

    def cancelled?
      validation.reload.cancelled?
    end

    def persist_identity!
      validation.update!(evidence: validation.evidence.merge("identity" => identity))
    end

    def record_unavailable(error)
      validation.update!(
        status: "unavailable",
        last_error: "#{error.class}: #{error.message}",
        evidence: validation.evidence.merge("identity" => identity),
        finished_at: Time.current
      )
      finalize_agent_run!
      logger.warn(
        message: "prerequisite_executions.validation_environment_unavailable",
        prerequisite_execution_validation_id: validation.id,
        error_class: error.class.name,
        error_message: error.message
      )
    end

    # Outcome from the contracted artifact steps: all succeeded → succeeded,
    # none succeeded → failed, a mix → partial (some evidence collected).
    # @spec PREREQ-EXEC-011
    def finalize!
      validation.reload
      return if validation.unavailable?

      outcome = validation.cancelled? ? "cancelled" : computed_outcome
      validation.update!(
        status: outcome,
        evidence: validation.evidence.merge("identity" => identity),
        finished_at: Time.current
      )
      finalize_agent_run!
      logger.info(
        message: "prerequisite_executions.validation_finished",
        prerequisite_execution_validation_id: validation.id,
        outcome: outcome,
        step_count: validation.steps.size
      )
    end

    def computed_outcome
      planned = validation.planned_step_keys - [ PrerequisiteExecutionValidation::CHECKOUT_IDENTITY_STEP ]
      succeeded = planned.select { |key| validation.step_result(key)&.dig("status") == "succeeded" }
      if succeeded.empty?
        "failed"
      elsif succeeded.size == planned.size
        "succeeded"
      else
        "partial"
      end
    end

    def finalize_agent_run!
      run = validation.agent_run
      return if run.nil? || run.finished?

      run.update!(
        status: PrerequisiteExecutionValidation.agent_run_status_for(validation.status),
        completed_at: Time.current,
        duration_seconds: [ (Time.current.to_f - run.started_at.to_f).round, 0 ].max
      )
    end
  end
end
