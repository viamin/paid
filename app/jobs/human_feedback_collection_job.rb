# frozen_string_literal: true

# Collects human feedback for a completed agent run based on its goal type.
# Only runs for successful (completed) agent runs to avoid skewing metrics.
#
# Goal-specific collection:
#   - create_pr: PR reactions, review outcomes, and review comment count
#   - create_issue: Emoji reactions on the created issue
#   - review: Emoji reactions on the code review comments
#   - enhance_issue: Emoji reactions and author replies on the enhancement comment
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
    when "enhance_issue"
      collect_enhance_issue_feedback(agent_run)
    end

    stamp_last_polled_at(agent_run)
    check_quality_pause(agent_run)
  end

  private

  def collect_pr_feedback(agent_run, comment_count_attempt: 0)
    return unless agent_run.pull_request_number

    QualityMetrics::CollectReactionFeedback.call(agent_run: agent_run)
    collect_pr_review_feedback(agent_run)

    # Fetch the PR once and share across collectors that need it, to avoid
    # duplicate GitHub API calls.
    pr_data = fetch_pull_request(agent_run)
    collect_review_comment_count(agent_run, pr_data: pr_data, attempt: comment_count_attempt)
    collect_pr_description_llm_feedback(agent_run, pr_data: pr_data)
  end

  def collect_pr_review_feedback(agent_run)
    github_client = github_client_for(agent_run.project)
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

  def fetch_pull_request(agent_run)
    github_client = github_client_for(agent_run.project)
    return nil unless github_client

    github_client.pull_request(agent_run.project.full_name, agent_run.pull_request_number)
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "human_feedback.pull_request_fetch_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
    nil
  end

  def collect_review_comment_count(agent_run, pr_data: nil, attempt: 0)
    pr = pr_data
    unless pr
      github_client = github_client_for(agent_run.project)
      return unless github_client

      repo = agent_run.project.full_name
      pr = github_client.pull_request(repo, agent_run.pull_request_number)
    end
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

    # Use find_or_create_by! to handle races with webhook-driven creation of
    # the same human metric (e.g., CollectCommentFeedback / CollectHumanFeedback).
    # If a concurrent thread inserts between find and create, rescue both
    # RecordNotUnique (DB constraint) and RecordInvalid (model uniqueness
    # validation) and reload the winner's record.
    begin
      metric = agent_run.quality_metrics.find_or_create_by!(metric_type: "human") do |m|
        m.scores = {}
        m.metadata = { "last_polled_at" => timestamp }
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      metric = agent_run.quality_metrics.find_by(metric_type: "human")
    end

    if metric
      metric.with_lock do
        existing = metric.metadata || {}
        metric.update!(
          metadata: existing.merge("last_polled_at" => timestamp)
        )
      end
    end
  end

  def collect_issue_feedback(agent_run)
    QualityMetrics::CollectIssueFeedback.call(agent_run: agent_run)
    collect_issue_title_llm_feedback(agent_run)
  end

  def collect_review_reaction_feedback(agent_run)
    QualityMetrics::CollectReviewReactionFeedback.call(agent_run: agent_run)
  end

  def collect_enhance_issue_feedback(agent_run)
    QualityMetrics::CollectEnhanceIssueFeedback.call(agent_run: agent_run)
  end

  def collect_pr_description_llm_feedback(agent_run, pr_data: nil)
    project = agent_run.project
    metric = LlmOutputMetric.find_by(
      project: project,
      output_type: "pr_description",
      source_type: "PullRequest",
      source_id: agent_run.pull_request_number
    )
    return unless metric

    github_client = github_client_for(project)
    return unless github_client

    repo = project.full_name
    pr = pr_data || github_client.pull_request(repo, agent_run.pull_request_number)
    reactions = github_client.pull_request_reactions(repo, agent_run.pull_request_number)

    current_body = pr[:body] || pr["body"]
    original_body = metric.metadata["original_text"]
    diff_size = (pr[:additions] || pr["additions"]).to_i + (pr[:deletions] || pr["deletions"]).to_i

    LlmOutputMetrics::CollectPrDescriptionFeedback.call(
      project: project,
      pull_request_number: agent_run.pull_request_number,
      current_description: current_body,
      original_description: original_body,
      diff_size: diff_size.zero? ? nil : diff_size,
      reactions: reactions
    )
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "llm_output_metrics.pr_description_feedback_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end

  def collect_issue_title_llm_feedback(agent_run)
    project = agent_run.project
    return unless agent_run.created_issue_number

    metric = LlmOutputMetric.find_by(
      project: project,
      output_type: "issue_title",
      source_type: "Issue",
      source_id: agent_run.created_issue_number
    )
    return unless metric

    github_client = github_client_for(project)
    return unless github_client

    repo = project.full_name
    issue = github_client.issue(repo, agent_run.created_issue_number)
    reactions = github_client.issue_reactions(repo, agent_run.created_issue_number)

    current_title = issue[:title] || issue["title"]
    original_title = metric.metadata["original_text"]

    LlmOutputMetrics::CollectIssueTitleFeedback.call(
      project: project,
      issue_number: agent_run.created_issue_number,
      current_title: current_title,
      original_title: original_title,
      reactions: reactions
    )
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "llm_output_metrics.issue_title_feedback_failed",
      agent_run_id: agent_run.id,
      error: e.message
    )
  end

  def check_quality_pause(agent_run)
    QualityPause::Check.call(agent_run: agent_run)
  end

  def github_client_for(project)
    return unless project.github_credential_present?

    project.client
  end
end
