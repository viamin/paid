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
  #     commenter: "octocat"
  #   )
  class CollectCommentFeedback
    attr_reader :agent_run, :commenter

    def initialize(agent_run:, commenter:)
      @agent_run = agent_run
      @commenter = commenter
    end

    def self.call(...)
      new(...).call
    end

    MAX_RETRIES = 3

    def call
      return nil if commenter.blank?

      retries = 0

      begin
        ActiveRecord::Base.transaction do
          metric = agent_run.quality_metrics.where(metric_type: "human").lock.first
          metric ||= agent_run.quality_metrics.build(metric_type: "human")

          metric.prompt_version = agent_run.prompt_version
          metric.feedback_source ||= "comment"

          existing_metadata = metric.metadata || {}
          existing_sources = Array(existing_metadata["feedback_sources"])
          comment_count = (existing_metadata["webhook_comment_count"] || 0) + 1
          existing_commenters = Array(existing_metadata["commenters"]).reject(&:blank?)
          commenters = existing_commenters.dup
          commenters << commenter unless commenter.blank?
          commenters.uniq!

          metric.metadata = existing_metadata.merge(
            "feedback_sources" => (existing_sources + [ "comment" ]).uniq,
            "webhook_comment_count" => comment_count,
            "commenters" => commenters,
            "last_comment_at" => Time.current.iso8601
          )

          metric.scores = (metric.scores || {}).merge(
            "webhook_comment_count_score" => QualityMetric.review_comment_count_score(comment_count)
          )
          metric.composite_score = metric.calculate_composite_score
          metric.save!
          metric
        end
      rescue ActiveRecord::RecordNotUnique
        retries += 1
        raise if retries > MAX_RETRIES
        sleep(0.05 * retries)
        retry
      end
    end
  end
end
