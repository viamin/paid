# frozen_string_literal: true

module DependencyCycles
  # Creates an ordinary authorized agent run; the structured metadata binds it
  # to the Inbox occurrence without granting it any mutation authority.
  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-017
  class StartAnalysis
    class ActiveRunExists < StandardError; end

    def self.call(...) = new(...).call

    def initialize(cycle:, user:, runner_resolver: AgentRuns::RunnerResolver, context_builder: AnalysisContext)
      @cycle, @user, @runner_resolver, @context_builder = cycle, user, runner_resolver, context_builder
    end

    def call
      raise ActiveRunExists if active_run

      project = cycle.project
      runner_id, agent_type = runner_resolver.call(project:, goal: "analyze_issue")
      AgentRun.create!(project:, issue: cycle.issues.first, initiating_user: user, runner_id:, agent_type:,
        goal: "analyze_issue", trigger_type: "manual", status: "queued", review_depth_snapshot: project.effective_review_depth,
        custom_prompt: prompt, external_metadata: { "cycle_analysis" => context })
    end

    private

    attr_reader :context_builder, :cycle, :runner_resolver, :user

    def context = @context ||= context_builder.call(cycle:)
    def prompt = "# Cycle-break analysis\n\n#{JSON.pretty_generate(context)}"

    def active_run
      AgentRun.where("external_metadata -> 'cycle_analysis' ->> 'occurrence' = ?", cycle.occurrence)
        .where("external_metadata -> 'cycle_analysis' ->> 'graph_revision' = ?", cycle.graph_revision)
        .where(status: AgentRun::UNFINISHED_STATUSES).first
    end
  end
end
