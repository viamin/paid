# frozen_string_literal: true

# Periodically collects human feedback for recently completed agent runs.
# Catches reactions and review outcomes that arrive after the initial
# HumanFeedbackCollectionJob (enqueued 5 minutes post-completion).
#
# Runs hourly via GoodJob cron. Only processes runs completed in
# the last 3 days to avoid unbounded growth while still capturing late
# feedback (reactions rarely arrive more than 3 days post-completion).
class DelayedHumanFeedbackCollectionJob < ApplicationJob
  queue_as :low_priority

  # Only process runs completed within this window.
  LOOKBACK_WINDOW = 3.days

  # Skip runs whose human metric was polled within this interval,
  # avoiding redundant API/DB work on every hourly sweep.
  #
  # Uses metadata->'last_polled_at' (set only by HumanFeedbackCollectionJob)
  # rather than updated_at, because webhook-driven updates (comments, merges,
  # reviews) also bump updated_at and would cause the sweep to skip runs that
  # still need reaction/review polling.
  SWEEP_INTERVAL = 12.hours

  # Minimum remaining GitHub API requests required to proceed with a sweep.
  # Each enqueued job makes 3+ API calls, so we need a reasonable budget.
  RATE_LIMIT_THRESHOLD = 100

  def perform
    agent_runs = AgentRun
      .where(status: "completed")
      .where(
        AgentRun.arel_table[:completed_at].gteq(LOOKBACK_WINDOW.ago)
          .or(
            AgentRun.arel_table[:completed_at].eq(nil)
              .and(AgentRun.arel_table[:updated_at].gteq(LOOKBACK_WINDOW.ago))
          )
      )
      .where.not(
        id: recently_polled_agent_run_ids
      )

    agent_runs.find_each do |agent_run|
      if rate_limit_exceeded?(agent_run)
        Rails.logger.info(
          message: "delayed_human_feedback.skipped_rate_limited",
          agent_run_id: agent_run.id
        )
        next
      end

      HumanFeedbackCollectionJob.perform_later(agent_run.id)
    end
  end

  private

  # Returns true when the GitHub token for this run's project is near its
  # rate limit, signaling we should skip enqueuing to avoid burning through
  # the remaining budget.
  def rate_limit_exceeded?(agent_run)
    client = agent_run.project&.github_token&.client
    return false unless client

    client.rate_limit_low?(threshold: RATE_LIMIT_THRESHOLD)
  rescue GithubClient::Error
    false
  end

  # Only considers metadata->>'last_polled_at'; metrics without this field are
  # treated as never polled so they are included in the sweep.
  def recently_polled_agent_run_ids
    QualityMetric
      .where(metric_type: "human")
      .where(
        "CAST(NULLIF(quality_metrics.metadata->>'last_polled_at', '') AS TIMESTAMPTZ) >= ?",
        SWEEP_INTERVAL.ago
      )
      .select(:agent_run_id)
  end
end
