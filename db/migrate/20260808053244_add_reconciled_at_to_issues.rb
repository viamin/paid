# frozen_string_literal: true

class AddReconciledAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :reconciled_at, :datetime,
               comment: "When this issue was last verified via reconciliation; null = never reconciled"
  end
end
