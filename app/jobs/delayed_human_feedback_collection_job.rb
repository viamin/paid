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

    agent_runs.find_each do |agent_run|
      HumanFeedbackCollectionJob.perform_later(agent_run.id)
    end
  end
end
