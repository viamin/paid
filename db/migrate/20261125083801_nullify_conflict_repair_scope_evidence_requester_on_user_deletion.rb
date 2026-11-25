# frozen_string_literal: true

class NullifyConflictRepairScopeEvidenceRequesterOnUserDeletion < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :conflict_repair_scope_evidences, column: :requested_by_id
    add_foreign_key :conflict_repair_scope_evidences, :users, column: :requested_by_id,
      on_delete: :nullify, validate: false
  end

  def down
    remove_foreign_key :conflict_repair_scope_evidences, column: :requested_by_id
    add_foreign_key :conflict_repair_scope_evidences, :users, column: :requested_by_id
  end
end
