# frozen_string_literal: true

# Collects human feedback (reactions and reviews) for a completed agent run's PR.
# Only runs for successful (completed) agent runs to avoid skewing metrics.
#
# Fetches both PR reactions and review outcomes from GitHub and records them
# as human quality metrics.
class HumanFeedbackCollectionJob < ApplicationJob
  queue_as :default

  def perform(agent_run_id)
    agent_run = AgentRun.find(agent_run_id)
    return unless agent_run.successful?
    return unless agent_run.pull_request_number

    QualityMetrics::CollectReactionFeedback.call(agent_run: agent_run)
    collect_review_feedback(agent_run)
  end

  private

  def collect_review_feedback(agent_run)
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
end
