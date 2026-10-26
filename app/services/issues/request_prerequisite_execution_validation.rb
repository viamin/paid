# frozen_string_literal: true

module Issues
  # Queues the existing isolated AgentRun lifecycle to gather missing technical
  # prerequisite evidence. The run is report-only: it may execute selected
  # tools only inside its execution environment and cannot implement or close
  # the originating issue.
  # @spec PREREQUISITE-EXECUTION-001 @spec PREREQUISITE-EXECUTION-004
  class RequestPrerequisiteExecutionValidation
    Result = Data.define(:agent_run, :code, :message) do
      def success? = code.nil?
    end

    ARTIFACT_CONTRACT = %w[
      stdout stderr exit_code image_identity checkout_identity endpoint_response cleanup
    ].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:)
      @issue = issue
      @actor = actor
    end

    def call
      issue.with_lock do
        return success(active_validation) if active_validation

        create_validation
      end
    rescue ActiveRecord::RecordNotUnique
      return success(active_validation) if active_validation

      raise
    end

    private

    attr_reader :actor, :issue

    def active_validation
      issue.agent_runs.where(goal: "analyze_issue", status: AgentRun::UNFINISHED_STATUSES)
        .where("external_metadata -> 'prerequisite_execution_validation' IS NOT NULL")
        .order(:id).first
    end

    def create_validation
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: "analyze_issue")
      run = AgentRun.create!(
        project: issue.project,
        issue: issue,
        initiating_user: actor,
        runner_id: runner_id,
        agent_type: agent_type,
        goal: "analyze_issue",
        trigger_type: "manual",
        review_depth_snapshot: issue.project.effective_review_depth,
        custom_prompt: prompt,
        external_metadata: { "prerequisite_execution_validation" => artifact_metadata },
        status: "queued"
      )
      MarketplaceEntries::AttachToRun.call(agent_run: run, auto_attach_enabled: true)
      Audit::RecordEvent.call(action: "issue.prerequisite_execution_validation_requested", actor:, subject: issue,
        metadata: { agent_run_id: run.id, artifact_contract: ARTIFACT_CONTRACT })
      ProcessRunQueueJob.perform_later
      success(run)
    end

    def artifact_metadata
      {
        "issue_number" => issue.github_number,
        "artifact_contract" => ARTIFACT_CONTRACT,
        "execution_boundary" => "isolated_agent_run",
        "scope" => "read_only_prerequisite_validation",
        "execution_capabilities" => execution_capabilities
      }
    end

    # Ask the runner/backend contract, rather than probing the control-plane
    # process for a Docker socket. A local investigation workspace is not an
    # authority on where this run can execute.
    def execution_capabilities
      backend = Containers.backend_for(issue.project.effective_preferred_docker_host_identifier)
      runner = ExecutionRunners.resolve(backend: backend)
      required = %i[direct_exec persistent_workspace streaming_logs]
      available = runner.class.capabilities(backend: backend).to_a
      {
        "backend" => backend.identifier,
        "available" => available.map(&:to_s),
        "required" => required.map(&:to_s),
        "missing" => (required - available).map(&:to_s),
        "tool_sidecar_rollout_authorized" => FeatureFlags.enabled?(:marketplace_tool_sidecars, project: issue.project)
      }
    end

    def prompt
      <<~PROMPT
        Collect technical prerequisite evidence only; do not modify source code, open a pull request, or close this issue.
        Use the run's pinned checkout and execute supported native analyzers through execute_in_execution_environment.
        If an authorized tool sidecar is attached, call only its documented endpoint with bounded payloads; never mount a host socket or expose host shell access.
        Record stdout, stderr, exit status, image and checkout identity, endpoint response where applicable, and cleanup outcome in the run evidence.
        If a capability, image allowlist, credential, or rollout authorization is absent, report that exact missing setup rather than retrying unchanged work.
      PROMPT
    end

    def success(agent_run) = Result.new(agent_run:, code: nil, message: nil)
  end
end
