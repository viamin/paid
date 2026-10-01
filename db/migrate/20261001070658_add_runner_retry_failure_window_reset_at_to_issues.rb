# frozen_string_literal: true

class AddRunnerRetryFailureWindowResetAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :runner_retry_failure_window_reset_at, :datetime,
      comment: "Lower bound for per-provider failure-count windowing (IssueRunnerFailureHistory). " \
               "Set to the current time whenever clear_runner_retry_abandonment! runs, so agent runs " \
               "created before the most recent clear are excluded from the retry-cap failure counts and " \
               "the issue-aware runner ordering. Without this, lifting the retry cap (including an " \
               "operator's explicit clear) would be immediately undone by stale failures re-tripping " \
               "the cap on the next dispatch."
  end
end
