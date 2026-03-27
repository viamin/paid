# frozen_string_literal: true

module QualityMetrics
  # Collects human feedback from GitHub issue reactions for issue creation goals.
  # Fetches emoji reactions on the created issue description and maps them to quality scores.
  #
  # Reaction scoring (same as CollectReactionFeedback):
  #   - +1 (thumbs up), heart, hooray, rocket -> positive (1.0)
  #   - -1 (thumbs down), confused -> negative (0.0)
  #   - laugh, eyes -> neutral (ignored)
  #
  # @example
  #   QualityMetrics::CollectIssueFeedback.call(agent_run: agent_run)
  class CollectIssueFeedback
    POSITIVE_REACTIONS = CollectReactionFeedback::POSITIVE_REACTIONS
    NEGATIVE_REACTIONS = CollectReactionFeedback::NEGATIVE_REACTIONS

    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      return nil unless agent_run.create_issue_goal?
      return nil unless agent_run.created_issue_number
      return nil unless github_client

      reactions = fetch_reactions
      return nil if reactions.empty?

      score = calculate_reaction_score(reactions)
      return nil if score.nil?

      record_feedback(score, reactions)
    end

    private

    def github_client
      agent_run.project.github_token&.client
    end

    def fetch_reactions
      repo = agent_run.project.full_name
      github_client.issue_reactions(repo, agent_run.created_issue_number)
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "quality_metrics.issue_reaction_fetch_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      []
    end

    def calculate_reaction_score(reactions)
      positive = reactions.count { |r| POSITIVE_REACTIONS.include?(r[:content]) }
      negative = reactions.count { |r| NEGATIVE_REACTIONS.include?(r[:content]) }
      total = positive + negative

      return nil if total.zero?

      (positive.to_f / total).round(4)
    end

    def record_feedback(score, reactions)
      metadata = {
        "reaction_counts" => tally_reactions(reactions),
        "collected_at" => Time.current.iso8601
      }

      ActiveRecord::Base.transaction do
        metric = agent_run.quality_metrics.where(metric_type: "human").lock.first
        metric ||= agent_run.quality_metrics.build(metric_type: "human")

        metric.prompt_version = agent_run.prompt_version
        metric.scores = (metric.scores || {}).merge("reaction_score" => score)

        metric.feedback_source ||= "issue_reaction"
        existing_metadata = metric.metadata || {}
        existing_sources = Array(existing_metadata["feedback_sources"])
        metadata["feedback_sources"] = (existing_sources + [ "issue_reaction" ]).uniq

        metric.metadata = existing_metadata.merge(metadata)
        metric.composite_score = metric.calculate_composite_score
        metric.save!
        metric
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def tally_reactions(reactions)
      reactions.each_with_object(Hash.new(0)) do |r, counts|
        counts[r[:content]] += 1
      end
    end
  end
end
