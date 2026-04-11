# frozen_string_literal: true

class AddDraftReviewRoundTrackingToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_runs, :count_toward_draft_review_round, :boolean, default: false, null: false
    add_column :agent_runs, :expected_draft_review_count, :integer

    # No backfill: legacy in-flight draft followup runs were already counted
    # at trigger time by the unpatched RecordDraftReviewActivity call in
    # GitHubPollWorkflow. Backfilling them here would cause double-counted
    # draft rounds and premature escalation against max_draft_review_rounds.
  end

  def down
    remove_column :agent_runs, :expected_draft_review_count
    remove_column :agent_runs, :count_toward_draft_review_round
  end
end
