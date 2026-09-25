# frozen_string_literal: true

class AddReopenAuditToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reopened_at unless column_exists?(:issues, :reopened_at)
    add_reopened_by unless column_exists?(:issues, :reopened_by_id)
    add_reopened_by_index unless index_exists?(:issues, :reopened_by_id)
    add_reopen_reason unless column_exists?(:issues, :reopen_reason)
  end

  private

  def add_reopened_at
    add_column :issues, :reopened_at, :datetime, comment: "When a closed issue was last reopened through chat."
  end

  def add_reopened_by
    add_reference :issues, :reopened_by, index: false, comment: "Paid user who last reopened this issue through chat."
  end

  def add_reopened_by_index
    add_index :issues, :reopened_by_id, algorithm: :concurrently
  end

  def add_reopen_reason
    add_column :issues, :reopen_reason, :text, comment: "Reason supplied when this closed issue was last reopened through chat."
  end
end
