# frozen_string_literal: true

module QualityMetrics
  # Collects human feedback from comments on agent-created PRs and issues.
  # Tracks comment count and commenter engagement as quality signals.
  #
  # A high comment count on an agent's PR may indicate issues requiring
  # discussion, while a low count may indicate a clean submission.
  # This service records comment metadata incrementally — each webhook
  # delivery adds to the existing data.
  #
  # @example
  #   QualityMetrics::CollectCommentFeedback.call(
  #     agent_run: agent_run,
  #     commenter: "octocat",
  #     comment_body: "Looks good, minor nit on line 42"
  #   )
  class CollectCommentFeedback
    attr_reader :agent_run, :commenter, :comment_body

    def initialize(agent_run:, commenter:, comment_body:)
      @agent_run = agent_run
      @commenter = commenter
      @comment_body = comment_body
    end

    def self.call(...)
      new(...).call
    end

    def call
      ActiveRecord::Base.transaction do
        metric = agent_run.quality_metrics.where(metric_type: "human").lock.first
        metric ||= agent_run.quality_metrics.build(metric_type: "human")

        metric.prompt_version = agent_run.prompt_version
        metric.feedback_source ||= "comment"

        existing_metadata = metric.metadata || {}
        existing_sources = Array(existing_metadata["feedback_sources"])
        comment_count = (existing_metadata["webhook_comment_count"] || 0) + 1
        commenters = (Array(existing_metadata["commenters"]) + [ commenter ]).uniq

        metric.metadata = existing_metadata.merge(
          "feedback_sources" => (existing_sources + [ "comment" ]).uniq,
          "webhook_comment_count" => comment_count,
          "commenters" => commenters,
          "last_comment_at" => Time.current.iso8601
        )

        metric.scores = (metric.scores || {}).merge(
          "review_comment_count" => QualityMetric.review_comment_count_score(comment_count)
        )
        metric.composite_score = metric.calculate_composite_score
        metric.save!
        metric
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end
  end
end
