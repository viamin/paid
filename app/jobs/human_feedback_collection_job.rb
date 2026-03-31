# frozen_string_literal: true

# Collects human feedback for a completed agent run based on its goal type.
# Only runs for successful (completed) agent runs to avoid skewing metrics.
#
# Goal-specific collection:
#   - create_pr: PR reactions, review outcomes, and review comment count
#   - create_issue: Emoji reactions on the created issue
#   - review: Emoji reactions on the code review comments
class HumanFeedbackCollectionJob < ApplicationJob
  queue_as :default

  # Maximum number of times the job will re-enqueue itself when the automated
  # metric is not yet available. Prevents infinite retry loops if the upstream
  # metric job never creates the record.
  MAX_COMMENT_COUNT_ATTEMPTS = 5

  def perform(agent_run_id, comment_count_attempt: 0)
    agent_run = AgentRun.find(agent_run_id)
    return unless agent_run.successful?

    case agent_run.goal
    when "create_pr"
      collect_pr_feedback(agent_run, comment_count_attempt: comment_count_attempt)
    when "create_issue"
      collect_issue_feedback(agent_run)
    when "review"
      collect_review_reaction_feedback(agent_run)
    end

    stamp_last_polled_at(agent_run)
  end

  private

  def collect_pr_feedback(agent_run, comment_count_attempt: 0)
    return unless agent_run.pull_request_number

    QualityMetrics::CollectReactionFeedback.call(agent_run: agent_run)
    collect_pr_review_feedback(agent_run)
    collect_review_comment_count(agent_run, attempt: comment_count_attempt)
  end

  def collect_pr_review_feedback(agent_run)
    github_client = agent_run.project.github_token&.client
    return unless github_client

    repo = agent_run.project.full_name
    reviews = github_client.pull_request_reviews(repo, agent_run.pull_request_number)
    return if reviews.empty?

    QualityMetrics::CollectReviewFeedback.call(
      agent_run: agent_run,
      reviews: reviews
    )
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "human_feedback.review_fetch_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end

  def collect_review_comment_count(agent_run, attempt: 0)
    github_client = agent_run.project.github_token&.client
    return unless github_client

    repo = agent_run.project.full_name
    pr = github_client.pull_request(repo, agent_run.pull_request_number)
    comment_count = pr[:review_comments] || pr["review_comments"] || 0

    metric = agent_run.quality_metrics.find_by(metric_type: "automated")
    unless metric
      if attempt < MAX_COMMENT_COUNT_ATTEMPTS
        Rails.logger.info(
          message: "human_feedback.automated_metric_missing",
          agent_run_id: agent_run.id,
          pull_request_number: agent_run.pull_request_number,
          attempt: attempt + 1,
          max_attempts: MAX_COMMENT_COUNT_ATTEMPTS
        )
        self.class.set(wait: 1.minute).perform_later(agent_run.id, comment_count_attempt: attempt + 1)
      else
        Rails.logger.warn(
          message: "human_feedback.automated_metric_missing_gave_up",
          agent_run_id: agent_run.id,
          pull_request_number: agent_run.pull_request_number,
          attempts: attempt
        )
      end
      return
    end

    existing_metadata = metric.metadata || {}
    existing_scores = metric.scores || {}

    metric.assign_attributes(
      metadata: existing_metadata.merge("review_comment_count" => comment_count),
      scores: existing_scores.merge("review_comment_count" => QualityMetric.review_comment_count_score(comment_count))
    )
    metric.composite_score = metric.calculate_composite_score
    metric.save!

    # Re-run quality metrics collection to ensure downstream aggregates
    # (e.g., experiment stats and prompt version stats) reflect the updated
    # composite score that now includes review_comment_count.
    QualityMetrics::Collect.call(agent_run: agent_run)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "human_feedback.review_comment_count_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end

  # Records when this polling job last ran for the given agent run.
  # DelayedHumanFeedbackCollectionJob uses this timestamp (not updated_at)
  # to decide whether a run needs re-polling, because webhook-driven updates
  # also bump updated_at and would cause the sweep to skip runs prematurely.
  def stamp_last_polled_at(agent_run)
    timestamp = Time.current.iso8601
    metric = agent_run.quality_metrics.find_by(metric_type: "human")

    if metric
      existing = metric.metadata || {}
      metric.update_columns(
        metadata: existing.merge("last_polled_at" => timestamp)
      )
    else
      agent_run.quality_metrics.create!(
        metric_type: "human",
        scores: {},
        metadata: { "last_polled_at" => timestamp }
      )
    end
  end

  def collect_issue_feedback(agent_run)
    QualityMetrics::CollectIssueFeedback.call(agent_run: agent_run)
  end

  def collect_review_reaction_feedback(agent_run)
    QualityMetrics::CollectReviewReactionFeedback.call(agent_run: agent_run)
  end
end
