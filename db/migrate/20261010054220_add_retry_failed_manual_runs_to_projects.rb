# frozen_string_literal: true

class AddRetryFailedManualRunsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :retry_failed_manual_runs, :boolean, default: true, null: false,
      comment: "When true, a failed manual agent run with no issue/PR attachment and no observable work " \
        "is automatically re-queued with backoff, up to AgentRun::MAX_MANUAL_RETRY_ATTEMPTS."
  end
end
