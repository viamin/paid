# frozen_string_literal: true

module QualityMetrics
  # Collects human feedback from GitHub PR review outcomes.
  # Maps review states to quality scores.
  #
  # Review scoring:
  #   - approved → 1.0
  #   - changes_requested → 0.0
  #   - commented → 0.5 (neutral)
  #   - dismissed → ignored
  #
  # @example Via webhook
  #   QualityMetrics::CollectReviewFeedback.call(
  #     agent_run: agent_run,
  #     review_state: "approved",
  #     reviewer: "octocat",
  #     review_body: "LGTM!"
  #   )
  #
  # @example Via polling
  #   QualityMetrics::CollectReviewFeedback.call(
  #     agent_run: agent_run,
  #     reviews: [{ state: "APPROVED", user_login: "octocat", body: "LGTM!" }]
  #   )
  class CollectReviewFeedback
    REVIEW_SCORES = {
      "approved" => 1.0,
      "changes_requested" => 0.0,
      "commented" => 0.5
    }.freeze

    attr_reader :agent_run, :review_state, :reviewer, :review_body, :reviews

    def initialize(agent_run:, review_state: nil, reviewer: nil, review_body: nil, reviews: nil)
      @agent_run = agent_run
      @review_state = review_state
      @reviewer = reviewer
      @review_body = review_body
      @reviews = reviews
    end

    def self.call(...)
      new(...).call
    end

    def call
      if reviews.present?
        process_multiple_reviews
      elsif review_state.present?
        process_single_review
      end
    end

    private

    def process_single_review
      normalized_state = review_state.downcase
      score = REVIEW_SCORES[normalized_state]
      return nil unless score

      record_feedback(
        score,
        [ { state: normalized_state, reviewer: reviewer, body: review_body } ]
      )
    end

    def process_multiple_reviews
      scored_reviews = reviews.filter_map do |review|
        state = review[:state].to_s.downcase
        score = REVIEW_SCORES[state]
        next unless score

        { state: state, reviewer: review[:user_login], body: review[:body].to_s, score: score }
      end

      return nil if scored_reviews.empty?

      avg_score = (scored_reviews.sum { |r| r[:score] } / scored_reviews.size).round(4)
      record_feedback(avg_score, scored_reviews)
    end

    def record_feedback(score, review_details)
      metadata = {
        "reviews" => review_details.map { |r| r.except(:score).transform_keys(&:to_s) },
        "collected_at" => Time.current.iso8601
      }

      ActiveRecord::Base.transaction do
        metric = agent_run.quality_metrics.where(metric_type: "human").lock.first
        metric ||= agent_run.quality_metrics.build(metric_type: "human")

        metric.prompt_version = agent_run.prompt_version
        metric.scores = (metric.scores || {}).merge("review_score" => score)

        # Track feedback sources non-destructively via metadata array
        metric.feedback_source ||= "pr_review"
        existing_metadata = metric.metadata || {}
        existing_sources = Array(existing_metadata["feedback_sources"])
        metadata["feedback_sources"] = (existing_sources + [ "pr_review" ]).uniq

        metric.metadata = existing_metadata.merge(metadata)
        metric.composite_score = metric.calculate_composite_score
        metric.save!
        metric
      end
    end
  end
end
