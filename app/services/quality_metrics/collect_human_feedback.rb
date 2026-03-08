# frozen_string_literal: true

module QualityMetrics
  # Collects human feedback quality metrics for an agent run.
  # Human signals include PR merge status, thumbs up/down reactions,
  # and PR review outcomes.
  #
  # @example
  #   QualityMetrics::CollectHumanFeedback.call(
  #     agent_run: agent_run,
  #     pr_merged: true,
  #     feedback_source: "pr_merge"
  #   )
  class CollectHumanFeedback
    attr_reader :agent_run, :pr_merged, :human_vote, :feedback_source

    def initialize(agent_run:, pr_merged: nil, human_vote: nil, feedback_source: "pr_merge")
      @agent_run = agent_run
      @pr_merged = pr_merged
      @human_vote = human_vote
      @feedback_source = feedback_source
    end

    def self.call(...)
      new(...).collect
    end

    # @return [QualityMetric] The created or updated quality metric
    def collect
      scores = {}
      scores["pr_merged"] = pr_merged ? 1.0 : 0.0 unless pr_merged.nil?

      metric = agent_run.quality_metrics.find_or_initialize_by(metric_type: "human")
      metric.prompt_version = agent_run.prompt_version
      metric.scores = metric.scores.merge(scores)
      metric.feedback_source = feedback_source
      metric.composite_score = metric.calculate_composite_score
      metric.save!
      metric
    end
  end
end
