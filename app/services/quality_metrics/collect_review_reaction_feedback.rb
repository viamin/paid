# frozen_string_literal: true

module QualityMetrics
  # Collects human feedback from GitHub reactions on code review comments.
  # For review goals, fetches emoji reactions on the review itself to gauge quality.
  #
  # Reaction scoring (same as CollectReactionFeedback):
  #   - +1 (thumbs up), heart, hooray, rocket -> positive (1.0)
  #   - -1 (thumbs down), confused -> negative (0.0)
  #   - laugh, eyes -> neutral (ignored)
  #
  # @example
  #   QualityMetrics::CollectReviewReactionFeedback.call(agent_run: agent_run)
  class CollectReviewReactionFeedback
    POSITIVE_REACTIONS = CollectReactionFeedback::POSITIVE_REACTIONS
    NEGATIVE_REACTIONS = CollectReactionFeedback::NEGATIVE_REACTIONS

    # Maximum number of review comments to fetch reactions for, to avoid
    # excessive N+1 API calls on PRs with many comments.
    MAX_REVIEW_COMMENTS = 50

    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).call
    end

    def call
      return nil unless agent_run.review_goal?
      return nil unless agent_run.source_pull_request_number
      return nil unless github_client

      reactions = fetch_review_reactions
      return nil if reactions.empty?

      score = calculate_reaction_score(reactions)
      return nil if score.nil?

      record_feedback(score, reactions)
    end

    private

    def github_client
      agent_run.project.github_token&.client
    end

    # Fetches reactions on individual review comments only (not PR-level
    # reactions, which reflect sentiment about the PR rather than the review).
    def fetch_review_reactions
      repo = agent_run.project.full_name
      pr_number = agent_run.source_pull_request_number

      fetch_review_comment_reactions(repo, pr_number)
    end

    def fetch_review_comment_reactions(repo, pr_number)
      comments = github_client.pull_request_review_comments(repo, pr_number)

      if comments.size > MAX_REVIEW_COMMENTS
        Rails.logger.info(
          message: "quality_metrics.review_comments_capped",
          agent_run_id: agent_run.id,
          total_comments: comments.size,
          cap: MAX_REVIEW_COMMENTS
        )
        comments = comments.last(MAX_REVIEW_COMMENTS)
      end

      comments.flat_map do |comment|
        github_client.pull_request_review_comment_reactions(repo, comment[:id])
      rescue GithubClient::Error => e
        Rails.logger.warn(
          message: "quality_metrics.review_comment_reaction_fetch_failed",
          agent_run_id: agent_run.id,
          comment_id: comment[:id],
          error: e.message
        )
        []
      end
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "quality_metrics.review_comments_fetch_failed",
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

        metric.feedback_source ||= "review_reaction"
        existing_metadata = metric.metadata || {}
        existing_sources = Array(existing_metadata["feedback_sources"])
        metadata["feedback_sources"] = (existing_sources + [ "review_reaction" ]).uniq

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
