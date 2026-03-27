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

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless agent_run.successful?

    case agent_run.goal
    when "create_pr"
      collect_pr_feedback(agent_run)
    when "create_issue"
      collect_issue_feedback(agent_run)
    when "review"
      collect_review_reaction_feedback(agent_run)
    end
  end

  private

  def collect_pr_feedback(agent_run)
    return unless agent_run.pull_request_number

    QualityMetrics::CollectReactionFeedback.call(agent_run: agent_run)
    collect_pr_review_feedback(agent_run)
    collect_review_comment_count(agent_run)
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

  def collect_review_comment_count(agent_run)
    github_client = agent_run.project.github_token&.client
    return unless github_client

    repo = agent_run.project.full_name
    pr = github_client.pull_request(repo, agent_run.pull_request_number)
    comment_count = pr[:review_comments] || pr["review_comments"] || 0

    metric = agent_run.quality_metrics.find_by(metric_type: "automated")
    unless metric
      Rails.logger.info(
        message: "human_feedback.automated_metric_missing",
        agent_run_id: agent_run.id,
        pull_request_number: agent_run.pull_request_number
      )
      self.class.set(wait: 1.minute).perform_later(agent_run.id)
      return
    end

    existing_metadata = metric.metadata || {}
    existing_scores = metric.scores || {}

    metric.assign_attributes(
      metadata: existing_metadata.merge("review_comment_count" => comment_count),
      scores: existing_scores.merge("review_comment_count" => [ 1.0 - (comment_count * 0.1), 0.0 ].max)
    )
    metric.composite_score = metric.calculate_composite_score
    metric.save!
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "human_feedback.review_comment_count_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end

  def collect_issue_feedback(agent_run)
    QualityMetrics::CollectIssueFeedback.call(agent_run: agent_run)
  end

  def collect_review_reaction_feedback(agent_run)
    QualityMetrics::CollectReviewReactionFeedback.call(agent_run: agent_run)
  end
end
