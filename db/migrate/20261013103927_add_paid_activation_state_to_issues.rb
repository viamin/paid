# frozen_string_literal: true

class AddPaidActivationStateToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_activation_columns
    add_activation_index
  end

  def down
    remove_activation_index
    remove_column :issues, :paid_activated_at if column_exists?(:issues, :paid_activated_at)
    remove_column :issues, :paid_activation_state if column_exists?(:issues, :paid_activation_state)
  end

  private

  def add_activation_columns
    add_column :issues, :paid_activation_state, :string, comment: "Paid-local per-item activation state for ignored label mode. Set to 'activated' when a user marks this issue/PR as Paid's to work on; auto-pick, auto-enhance, and PR-scan scope read this column instead of GitHub labels in ignored mode." unless column_exists?(:issues, :paid_activation_state)
    add_column :issues, :paid_activated_at, :datetime, comment: "Timestamp this issue/PR was most recently marked paid-activated. Distinct from updated_at so unrelated sync metadata cannot clear the activation signal." unless column_exists?(:issues, :paid_activated_at)
  end

  def add_activation_index
    return if index_exists?(:issues, [ :project_id, :paid_activation_state ], name: "index_issues_on_project_id_and_paid_activation_state")

    add_index :issues, [ :project_id, :paid_activation_state ],
      name: "index_issues_on_project_id_and_paid_activation_state", algorithm: :concurrently
  end

  def remove_activation_index
    return unless index_exists?(:issues, [ :project_id, :paid_activation_state ], name: "index_issues_on_project_id_and_paid_activation_state")

    remove_index :issues, name: "index_issues_on_project_id_and_paid_activation_state", algorithm: :concurrently
  end
end
