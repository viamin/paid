# frozen_string_literal: true

# Per-run snapshot of the project-level review_depth preset. Captured at
# review-run creation time so a later project-level preset change cannot
# retroactively alter the run's review behavior or downstream
# interpretability. Existing rows backfill to "balanced", which is the
# project-level default, so legacy review runs behave exactly as before.
# @spec REVIEW-DEPTH-005
class AddReviewDepthSnapshotToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:agent_runs, :review_depth_snapshot)
      add_column :agent_runs, :review_depth_snapshot, :string, limit: 32,
        default: "balanced", null: false,
        comment: "Effective review_depth preset snapshotted at run creation. Focused/Balanced/Thorough."
    end
  end
end
