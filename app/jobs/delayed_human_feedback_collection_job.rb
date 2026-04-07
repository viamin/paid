# frozen_string_literal: true

# Periodically collects human feedback for recently completed agent runs.
# Catches reactions and review outcomes that arrive after the initial
# HumanFeedbackCollectionJob (enqueued 5 minutes post-completion).
#
# Runs hourly via GoodJob cron. Only processes runs completed in
# the last 7 days to avoid unbounded growth while still capturing late
# feedback (reviewers may not react for hours or days).
class DelayedHumanFeedbackCollectionJob < ApplicationJob
  queue_as :low_priority

  # Only process runs completed within this window.
  LOOKBACK_WINDOW = 7.days

  # Skip runs whose human metric was polled within this interval,
  # avoiding redundant API/DB work on every hourly sweep.
  #
  # Uses metadata->'last_polled_at' (set only by HumanFeedbackCollectionJob)
  # rather than updated_at, because webhook-driven updates (comments, merges,
  # reviews) also bump updated_at and would cause the sweep to skip runs that
  # still need reaction/review polling.
  SWEEP_INTERVAL = 4.hours

  # Minimum remaining API requests before skipping feedback collection
  # for a given token. Feedback collection is best-effort and should
  # not exhaust rate limits needed for polling.
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
      .includes(project: :github_token)

    rate_limited_tokens = Set.new

    agent_runs.find_each do |agent_run|
      token = agent_run.project&.github_token
      next unless token

      unless rate_limited_tokens.include?(token.id)
        if token.client.rate_limit_low?(threshold: RATE_LIMIT_THRESHOLD)
          rate_limited_tokens.add(token.id)
          next
        end
      else
        next
      end

      HumanFeedbackCollectionJob.perform_later(agent_run.id)
    end
  end

  private

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
