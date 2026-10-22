# frozen_string_literal: true

class AddLocalControlStatesToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_control_columns
    add_control_indexes
  end

  private

  def add_control_columns
    add_column :issues, :auto_pick_excluded_reason, :text, comment: "Human-provided reason this issue is excluded from automatic selection in ignored label mode." unless column_exists?(:issues, :auto_pick_excluded_reason)
    add_column :issues, :control_priority, :string, comment: "Local P1/P2/P3 priority used in ignored label mode." unless column_exists?(:issues, :control_priority)
    add_column :issues, :hold_for_review, :boolean, default: false, null: false, comment: "Local per-PR human-review hold used in ignored label mode." unless column_exists?(:issues, :hold_for_review)
    add_column :issues, :skip_auto_merge, :boolean, default: false, null: false, comment: "Local per-PR automatic-merge exclusion used in ignored label mode." unless column_exists?(:issues, :skip_auto_merge)
    add_column :issues, :tdd_review_state, :string, comment: "Local TDD test-review gate state used in ignored label mode." unless column_exists?(:issues, :tdd_review_state)
  end

  def add_control_indexes
    unless index_exists?(:issues, [ :project_id, :control_priority ], name: "index_issues_on_project_id_and_control_priority")
      add_index :issues, [ :project_id, :control_priority ], name: "index_issues_on_project_id_and_control_priority", algorithm: :concurrently
    end

    return if index_exists?(:issues, [ :project_id, :auto_pick_excluded_reason ], name: "index_issues_on_auto_pick_exclusion")

    add_index :issues, [ :project_id, :auto_pick_excluded_reason ],
      where: "auto_pick_excluded_reason IS NOT NULL", name: "index_issues_on_auto_pick_exclusion", algorithm: :concurrently
  end
end
