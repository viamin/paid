# frozen_string_literal: true

module AgentRuns
  class CreateFollowup
    FOLLOWUP_GOALS = %w[create_pr enhance_issue].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, goal:)
      @agent_run = agent_run
      @goal = goal
    end

    def call
      validate!

      followup = create_followup_run
      ProcessRunQueueJob.perform_later
      followup
    rescue ActiveRecord::RecordNotUnique => e
      message = e.cause&.message || e.message
      raise unless message&.include?("idx_agent_runs_unique_active_issue")

      handle_duplicate
    end

    private

    attr_reader :agent_run, :goal

    def validate!
      raise ArgumentError, "Analysis run must have an associated issue" unless agent_run.issue
      raise ArgumentError, "Goal must be one of: #{FOLLOWUP_GOALS.join(", ")}" unless FOLLOWUP_GOALS.include?(goal)
    end

    def create_followup_run
      provider = resolve_provider

      AgentRun.create!(
        project: agent_run.project,
        issue: agent_run.issue,
        provider: provider,
        agent_type: provider ? Provider.agent_type_for(provider.provider_key) : "claude_code",
        status: "queued",
        trigger_type: "automatic",
        auto_pick: true,
        goal: goal
      )
    end

    def resolve_provider
      return agent_run.provider if agent_run.provider

      provider_id, = AgentRuns::ProviderResolver.call(project: agent_run.project, goal: goal)
      Provider.find_by(id: provider_id) if provider_id
    end

    def handle_duplicate
      existing_run = AgentRun.find_by(
        project: agent_run.project,
        issue: agent_run.issue,
        goal: goal,
        status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
      )

      if existing_run
        Rails.logger.info(
          message: "create_followup.duplicate_existing_run",
          project_id: agent_run.project_id,
          issue_id: agent_run.issue_id,
          agent_run_id: existing_run.id
        )
        existing_run
      else
        Rails.logger.info(
          message: "create_followup.duplicate_skipped",
          project_id: agent_run.project_id,
          issue_id: agent_run.issue_id
        )
        nil
      end
    end
  end
end
