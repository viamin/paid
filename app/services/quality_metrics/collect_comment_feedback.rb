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
  #     comment_id: 12345
  #   )
  class CollectCommentFeedback
    attr_reader :agent_run, :commenter, :comment_id

    def initialize(agent_run:, commenter:, comment_id: nil)
      @agent_run = agent_run
      @commenter = commenter
      @comment_id = comment_id
    end

    def self.call(...)
      new(...).call
    end

    MAX_RETRIES = 3

    # Keep only the most recent N comment IDs for deduplication.
    # Older IDs are evicted to prevent unbounded metadata growth — webhook
    # retries for those comments are unlikely after this many newer comments.
    MAX_PROCESSED_IDS = 500

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

          # Deduplicate by comment_id to handle GitHub webhook retries.
          # Without this, retried deliveries would inflate the comment count.
          if comment_id.present?
            processed_ids = Array(existing_metadata["processed_comment_ids"])
            if processed_ids.include?(comment_id)
              return metric.persisted? ? metric : nil
            end
            processed_ids = (processed_ids + [ comment_id ]).last(MAX_PROCESSED_IDS)
          end

          existing_sources = Array(existing_metadata["feedback_sources"])
          comment_count = (existing_metadata["webhook_comment_count"] || 0) + 1
          existing_commenters = Array(existing_metadata["commenters"]).reject(&:blank?)
          commenters = existing_commenters.dup
          commenters << commenter unless commenter.blank?
          commenters.uniq!

          # Comment activity is tracked purely in metadata — it is not a weighted
          # score key in SCORE_WEIGHTS/GOAL_WEIGHTS, so writing it to scores would
          # leave composite_score unaffected while adding a dangling key.
          updated_metadata = existing_metadata.merge(
            "feedback_sources" => (existing_sources + [ "comment" ]).uniq,
            "webhook_comment_count" => comment_count,
            "commenters" => commenters,
            "last_comment_at" => Time.current.iso8601
          )
          updated_metadata["processed_comment_ids"] = processed_ids if comment_id.present?
          metric.metadata = updated_metadata

          metric.composite_score = metric.calculate_composite_score
          metric.save!
          metric
        end
      rescue ActiveRecord::RecordNotUnique
        retries += 1
        raise if retries > MAX_RETRIES
        sleep(0.05 * retries)
        retry
      rescue ActiveRecord::RecordInvalid => e
        # A concurrent transaction may commit the human metric between our
        # `lock.first` and `save!`, causing the model-level uniqueness
        # validation to fire instead of the DB constraint.  Retry so we
        # pick up the now-existing row via `lock.first`.
        raise unless e.record.errors.of_kind?(:metric_type, :taken)
        retries += 1
        raise if retries > MAX_RETRIES
        sleep(0.05 * retries)
        retry
      end
    end
  end
end
