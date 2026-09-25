# frozen_string_literal: true

class AddReopenAuditToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:issues, :reopened_at)
      add_column :issues, :reopened_at, :datetime, comment: "When a closed issue was last reopened through chat."
    end
    unless column_exists?(:issues, :reopened_by_id)
      add_reference :issues, :reopened_by, index: false, comment: "Paid user who last reopened this issue through chat."
    end
    add_index :issues, :reopened_by_id, algorithm: :concurrently unless index_exists?(:issues, :reopened_by_id)
    unless column_exists?(:issues, :reopen_reason)
      add_column :issues, :reopen_reason, :text, comment: "Reason supplied when this closed issue was last reopened through chat."
    end
  end

  def down
    remove_index :issues, :reopened_by_id, algorithm: :concurrently if index_exists?(:issues, :reopened_by_id)
    remove_reference :issues, :reopened_by, index: false if column_exists?(:issues, :reopened_by_id)
    remove_column :issues, :reopened_at if column_exists?(:issues, :reopened_at)
    remove_column :issues, :reopen_reason if column_exists?(:issues, :reopen_reason)
  end
end
