# frozen_string_literal: true

class NullifyConflictRepairRequesterOnUserDeletion < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :conflict_repair_scope_evidences, :users, column: :requested_by_id
    add_foreign_key :conflict_repair_scope_evidences, :users,
      column: :requested_by_id, on_delete: :nullify, validate: false
  end
end
