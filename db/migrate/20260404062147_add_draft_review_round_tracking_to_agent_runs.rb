# frozen_string_literal: true

class AddDraftReviewRoundTrackingToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_runs, :count_toward_draft_review_round, :boolean, default: false, null: false
    add_column :agent_runs, :expected_draft_review_count, :integer

    backfill_legacy_draft_followup_runs!
  end

  def down
    remove_column :agent_runs, :expected_draft_review_count
    remove_column :agent_runs, :count_toward_draft_review_round
  end

  private

  def backfill_legacy_draft_followup_runs!
    execute <<~SQL.squish
      UPDATE agent_runs
      SET count_toward_draft_review_round = TRUE,
          expected_draft_review_count = issues.draft_review_count
      FROM issues
      WHERE agent_runs.issue_id = issues.id
        AND issues.is_pull_request = TRUE
        AND issues.pr_review_phase IN ('draft', 'restarted')
        AND agent_runs.status IN ('queued', 'pending', 'running', 'paused')
        AND agent_runs.trigger_type = 'automatic'
        AND agent_runs.source_pull_request_number IS NOT NULL
        AND agent_runs.count_toward_draft_review_round = FALSE
        AND agent_runs.expected_draft_review_count IS NULL
    SQL
  end
end
