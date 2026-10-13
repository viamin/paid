# frozen_string_literal: true

class AddPaidActivationStateToIssues < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:issues, :paid_activation_state)
      add_column :issues, :paid_activation_state, :string,
        comment: "Paid-local per-item activation state for ignored label mode. " \
                 "Set to 'activated' when a user marks this issue/PR as Paid's to work on; " \
                 "auto-pick, auto-enhance, and PR-scan scope read this column " \
                 "instead of GitHub labels in ignored mode."
    end
    return if column_exists?(:issues, :paid_activated_at)

    add_column :issues, :paid_activated_at, :datetime,
      comment: "Timestamp this issue/PR was most recently marked paid-activated. " \
               "Distinct from updated_at so unrelated sync metadata cannot clear the activation signal."
  end
end
