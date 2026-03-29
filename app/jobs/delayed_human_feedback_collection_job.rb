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
    AgentRun
      .where(status: "completed")
      .where(updated_at: LOOKBACK_WINDOW.ago..)
      .find_each do |agent_run|
        HumanFeedbackCollectionJob.perform_later(agent_run.id)
      end
  end
end
