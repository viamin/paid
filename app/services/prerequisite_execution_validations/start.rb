# frozen_string_literal: true

module PrerequisiteExecutionValidations
  # Creates one isolated, non-agent validation run for an Inbox prerequisite.
  # The worker owns provisioning and execution; this service never runs a
  # command in the control-plane process.
  class Start
    Result = Data.define(:agent_run, :reused, :unavailable_reason)

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, tool_name: nil)
      @issue = issue
      @actor = actor
      @tool_name = tool_name.presence
    end

    # @spec PARTIAL-CLOSEOUT-028
    def call
      return Result.new(agent_run: existing_run, reused: true) if existing_run

      run = build_run
      capability = Containers::BackendScheduler.call(agent_run: run)
      if capability.candidate_hosts.empty?
        return record_unavailable(run, capability)
      end

      run.update!(container_host: capability.candidate_hosts.first)
      PrerequisiteExecutionValidationJob.perform_later(run.id)
      Result.new(agent_run: run, reused: false)
    end

    private

    attr_reader :issue, :actor, :tool_name

    def existing_run
      issue.agent_runs.where(status: %w[queued running]).find do |run|
        run.external_metadata.dig("prerequisite_execution_validation", "kind") == "technical_prerequisite"
      end
    end

    def build_run
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: issue.project, goal: "review")
      AgentRun.create!(
        project: issue.project, issue: issue, initiating_user: actor, runner_id: runner_id,
        agent_type: agent_type, goal: "review", trigger_type: "manual", synthetic: true,
        review_depth_snapshot: issue.project.effective_review_depth, status: "queued",
        external_metadata: { "prerequisite_execution_validation" => {
          "kind" => "technical_prerequisite", "issue_id" => issue.id,
          "requested_tool_name" => tool_name, "requested_at" => Time.current.iso8601
        } }
      )
    end

    def record_unavailable(run, capability)
      reason = capability.requirements_error.presence || capability.compatibility_failures.values.first ||
        capability.health_failures.values.first || "No compatible execution backend is available."
      run.update!(status: "failed", completed_at: Time.current,
        verification_result: evidence(run, outcome: "unavailable", reason: reason, capability: capability))
      Result.new(agent_run: run, reused: false, unavailable_reason: reason)
    end

    def evidence(run, outcome:, reason:, capability:)
      { "prerequisite_execution_validation" => {
        "outcome" => outcome, "reason" => reason, "issue_id" => issue.id,
        "agent_run_id" => run.id, "candidate_hosts" => capability.candidate_hosts,
        "compatibility_failures" => capability.compatibility_failures,
        "health_failures" => capability.health_failures, "captured_at" => Time.current.iso8601
      } }
    end
  end
end
