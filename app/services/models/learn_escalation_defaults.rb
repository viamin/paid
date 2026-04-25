# frozen_string_literal: true

module Models
  # Analyzes escalation history per project+goal to learn which task profiles
  # consistently require higher tiers. When a goal has been escalated enough
  # times (ESCALATION_THRESHOLD), the learned min tier is persisted in
  # project.model_preferences["goal_min_tiers"] so future first-attempt
  # selections start at the higher tier automatically.
  class LearnEscalationDefaults
    ESCALATION_THRESHOLD = 3
    LOOKBACK_WINDOW = 30.days

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      updated = false

      AgentRun::GOALS.each do |goal|
        learned_tier = learn_tier_for_goal(goal)
        next unless learned_tier

        current = project.model_preferences&.dig("goal_min_tiers", goal)
        current_index = current ? LlmModel::TIERS.index(current) : -1
        learned_index = LlmModel::TIERS.index(learned_tier)
        next unless learned_index && learned_index > (current_index || -1)

        updated = true
        set_goal_min_tier(goal, learned_tier)
      end

      project.save! if updated
      updated
    end

    private

    attr_reader :project

    def learn_tier_for_goal(goal)
      escalations = ModelSelection.escalated
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id, goal: goal })
        .where(model_selections: { created_at: LOOKBACK_WINDOW.ago.. })
        .pluck(:tier)

      return nil if escalations.size < ESCALATION_THRESHOLD

      escalations.tally.max_by { |_tier, count| count }&.first
    end

    def set_goal_min_tier(goal, tier)
      preferences = project.model_preferences.deep_dup
      preferences["goal_min_tiers"] ||= {}
      preferences["goal_min_tiers"][goal] = tier
      project.model_preferences = preferences
    end
  end
end
