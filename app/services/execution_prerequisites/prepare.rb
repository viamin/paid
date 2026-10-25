# frozen_string_literal: true

module ExecutionPrerequisites
  # Creates one fresh, pinned, report-only AgentRun. Repeated clicks return the
  # existing active proof instead of re-running an unchanged failure.
  # @spec PARTIAL-CLOSEOUT-028
  class Prepare
    Result = Data.define(:agent_run, :created, :message) do
      def success? = agent_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:)
      @issue = issue
      @actor = actor
    end

    def call
      existing = issue.agent_runs.where("external_metadata ->> 'technical_prerequisite_execution' = ?", "v1")
        .where(status: %w[queued running]).order(created_at: :desc).first
      return Result.new(agent_run: existing, created: false, message: "Validation is already in progress.") if existing

      run = issue.agent_runs.create!(
        project: issue.project, initiating_user: actor, agent_type: RunnerSupport.intended_agent_type(
          preferred_agent_type: issue.project.model_preferences["preferred_agent_type"]
        ), goal: "analyze_issue", trigger_type: "manual", synthetic: true,
        external_metadata: { "technical_prerequisite_execution" => "v1", "source_issue_id" => issue.id }
      )
      ExecutionPrerequisites::ValidateJob.perform_later(run.id)
      Result.new(agent_run: run, created: true, message: "Technical prerequisite validation queued.")
    end

    private

    attr_reader :issue, :actor
  end
end
