# frozen_string_literal: true

module PrerequisiteValidations
  # @spec PREREQUISITE-VALIDATION-001
  class Start
    Result = Data.define(:agent_run, :code, :message) do
      def success? = code.nil?
    end

    NATIVE_PROBE = "/usr/local/bin/paid-prerequisite-probe --version"

    def self.call(...) = new(...).call

    def initialize(issue:, actor:)
      @issue = issue
      @actor = actor
    end

    def call
      return failure(:tool_rollout_disabled, rollout_message) if tool_requested? && !tool_sidecars_enabled?

      run = create_run
      selection = Containers::BackendScheduler.call(agent_run: run)
      return record_unavailable(run, selection) if selection.candidate_hosts.empty?

      run.update!(container_host: selection.candidate_hosts.first)
      PrerequisiteValidationJob.perform_later(run.id)
      Result.new(agent_run: run, code: nil, message: nil)
    rescue ActiveRecord::RecordNotUnique
      existing = issue.agent_runs.where(goal: "prerequisite_validation").where(status: AgentRun::ACTIVE_STATUSES + [ "queued" ]).order(id: :desc).first
      return Result.new(agent_run: existing, code: nil, message: nil) if existing

      raise
    end

    private

    attr_reader :actor, :issue

    def create_run
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: "prerequisite_validation")
      AgentRun.create!(
        project: issue.project, issue: issue, initiating_user: actor, runner_id:, agent_type:,
        goal: "prerequisite_validation", trigger_type: "manual", review_depth_snapshot: issue.project.effective_review_depth,
        custom_prompt: "Collect bounded technical prerequisite evidence only.", tool_sidecar_snapshot: selected_tool ? [ selected_tool ] : [],
        external_metadata: { "prerequisite_validation" => contract }
      )
    end

    def contract
      { "state" => "prepared", "issue_id" => issue.id, "closeout_evidence_digest" => Issues::CloseoutEvidence.call(issue).digest,
        "native_analyzer" => { "identity" => "paid-prerequisite-probe", "command" => NATIVE_PROBE }, "tool" => selected_tool,
        "artifact_contract" => %w[stdout stderr exit_status image checkout tool_endpoint cleanup] }
    end

    def selected_tool
      issue.project.agent_runs.where.not(tool_sidecar_snapshot: []).order(created_at: :desc).pick(:tool_sidecar_snapshot)&.first
    end

    def tool_requested? = selected_tool.present?
    def tool_sidecars_enabled? = FeatureFlags.enabled?(:marketplace_tool_sidecars, project: issue.project)

    def rollout_message
      "Marketplace tool sidecars are disabled for this project. An authorized project administrator must enable marketplace_tool_sidecars for the scoped pilot before this prerequisite can run."
    end

    def record_unavailable(run, selection)
      persist(run, "unavailable", scheduler: scheduler_evidence(selection))
      run.fail!(error: "No compatible execution backend is available for this validation.")
      Result.new(agent_run: run, code: :no_compatible_backend, message: "No compatible execution backend is available.")
    end

    def scheduler_evidence(selection)
      { "requested_host" => selection.requested_host, "compatibility_failures" => selection.compatibility_failures,
        "health_failures" => selection.health_failures, "requirements_error" => selection.requirements_error }.compact
    end

    def persist(run, state, extra = {})
      payload = run.external_metadata.fetch("prerequisite_validation").merge("state" => state, "updated_at" => Time.current.iso8601, **extra)
      run.update!(external_metadata: run.external_metadata.merge("prerequisite_validation" => payload))
    end

    def failure(code, message) = Result.new(agent_run: nil, code:, message:)
  end
end
