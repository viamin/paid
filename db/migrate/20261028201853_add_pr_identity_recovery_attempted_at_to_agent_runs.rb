# frozen_string_literal: true

class AddPrIdentityRecoveryAttemptedAtToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :pr_identity_recovery_attempted_at, :datetime,
      comment: "Last successful GitHub lookup that found zero or ambiguous open PRs for the run branch."
  end
end
