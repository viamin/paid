# frozen_string_literal: true

module Models
  class RulesBasedSelector
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      complexity = estimate_complexity
      candidates = build_candidates(complexity)

      return nil if candidates.empty?

      selected = candidates.first

      {
        model: selected,
        selector_type: "rules",
        reasoning: "Rules-based selection: complexity=#{complexity.round(1)}, " \
                   "selected #{selected.display_name} (capability=#{selected.capability_score})",
        candidates: candidates.map { |m| { model_id: m.model_id, score: m.capability_score.to_f } },
        complexity_score: complexity
      }
    end

    private

    attr_reader :agent_run

    def estimate_complexity
      score = 5.0

      if agent_run.issue.present?
        body_length = agent_run.issue.body.to_s.length
        score += 1.0 if body_length > 1000
        score += 1.0 if body_length > 3000
        score -= 1.0 if body_length < 200
      end

      score += 1.0 if agent_run.existing_pr?
      score -= 1.0 if agent_run.create_issue_goal?

      score.clamp(1.0, 10.0)
    end

    def build_candidates(complexity)
      scope = LlmModel.active

      # Exclude models the project has excluded
      excluded = agent_run.project.model_preferences["excluded_model_ids"]
      scope = scope.where.not(model_id: excluded) if excluded.present?

      # For simple tasks, prefer cheaper models
      if complexity < 4.0
        scope = scope.where("capability_score >= 5 OR capability_score IS NULL")
      elsif complexity >= 7.0
        scope = scope.where("capability_score >= 8 OR capability_score IS NULL")
      end

      scope.order(Arel.sql("capability_score DESC NULLS LAST")).limit(5).to_a
    end
  end
end
