# frozen_string_literal: true

class ValidateInvalidatedByForeignKeyOnStagedCloseoutMappings < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :staged_closeout_mappings, :users, column: :invalidated_by_id
  end

  def down
  end
end
