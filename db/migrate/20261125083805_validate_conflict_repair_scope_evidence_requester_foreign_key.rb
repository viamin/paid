# frozen_string_literal: true

class ValidateConflictRepairScopeEvidenceRequesterForeignKey < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :conflict_repair_scope_evidences, :users, column: :requested_by_id
  end

  def down
  end
end
