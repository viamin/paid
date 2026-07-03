# frozen_string_literal: true

class AddReviewProxyDiagnosticsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :review_proxy_diagnostics, :jsonb, default: {}, null: false,
      comment: "Latest known outcome of the review-creation proxy POST for this run " \
               "(outcome: attempted/timeout/connection_failed/upstream_error/succeeded, " \
               "plus http_status/error_class/error_message/recorded_at when available). " \
               "Lets CompleteReviewGoalActivity explain review-goal failures without raw log " \
               "inspection (#2779). Not part of run history/state."
  end
end
