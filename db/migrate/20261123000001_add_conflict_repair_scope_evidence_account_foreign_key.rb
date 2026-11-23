# frozen_string_literal: true

class AddConflictRepairScopeEvidenceAccountForeignKey < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_foreign_key :conflict_repair_scope_evidences, :accounts, column: :account_id, validate: false
    validate_foreign_key :conflict_repair_scope_evidences, :accounts
  end

  def down
    remove_foreign_key :conflict_repair_scope_evidences, column: :account_id
  end
end
