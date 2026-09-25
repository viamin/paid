# frozen_string_literal: true

class AddOrphanedNeedsInputLabelEvaluationToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_issues_pending_orphaned_needs_input_label_evaluation"

  def up
    unless column_exists?(:issues, :orphaned_needs_input_label_evaluated_at)
      add_column :issues, :orphaned_needs_input_label_evaluated_at, :datetime,
        comment: "When the historical questionless needs-input label reconciliation last evaluated this issue. Cleared labels do not need a later backfill scan; labels added after the evaluation are handled directly by the GitHub sync delta."
    end

    return if index_exists?(:issues, [ :project_id, :orphaned_needs_input_label_evaluated_at ], name: INDEX_NAME)

    add_index :issues, [ :project_id, :orphaned_needs_input_label_evaluated_at ],
      where: "orphaned_needs_input_label_evaluated_at IS NULL",
      name: INDEX_NAME,
      algorithm: :concurrently
  end

  def down
    remove_index :issues, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    safety_assured do
      remove_column :issues, :orphaned_needs_input_label_evaluated_at if column_exists?(:issues, :orphaned_needs_input_label_evaluated_at)
    end
  end
end
