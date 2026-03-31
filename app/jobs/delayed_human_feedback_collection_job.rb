# frozen_string_literal: true

# Periodically collects human feedback for recently completed agent runs.
# Catches reactions and review outcomes that arrive after the initial
# HumanFeedbackCollectionJob (enqueued 5 minutes post-completion).
#
# Runs every 4 hours via GoodJob cron. Only processes runs completed in
# the last 7 days to avoid unbounded growth while still capturing late
# feedback (reviewers may not react for hours or days).
class DelayedHumanFeedbackCollectionJob < ApplicationJob
  queue_as :low_priority

  # Only process runs completed within this window.
  LOOKBACK_WINDOW = 7.days

  # Skip runs whose human metric was polled within this interval,
  # avoiding redundant API/DB work on every 4-hour sweep.
  #
  # Uses metadata->'last_polled_at' (set only by HumanFeedbackCollectionJob)
  # rather than updated_at, because webhook-driven updates (comments, merges,
  # reviews) also bump updated_at and would cause the sweep to skip runs that
  # still need reaction/review polling.
  SWEEP_INTERVAL = 4.hours

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
      HumanFeedbackCollectionJob.perform_later(agent_run.id)
    end
  end

  private

  # Returns agent_run_ids whose human metric was polled within SWEEP_INTERVAL.
  # Falls back to updated_at for metrics that predate the last_polled_at field.
  def recently_polled_agent_run_ids
    polled_at_clause = Arel::Nodes::NamedFunction.new(
      "COALESCE",
      [
        Arel::Nodes::SqlLiteral.new(
          "CAST(quality_metrics.metadata->>'last_polled_at' AS TIMESTAMPTZ)"
        ),
        QualityMetric.arel_table[:updated_at]
      ]
    )

    QualityMetric
      .where(metric_type: "human")
      .where(polled_at_clause.gteq(SWEEP_INTERVAL.ago))
      .select(:agent_run_id)
  end
end
