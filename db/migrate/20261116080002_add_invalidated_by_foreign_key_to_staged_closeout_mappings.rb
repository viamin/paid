# frozen_string_literal: true

class AddInvalidatedByForeignKeyToStagedCloseoutMappings < ActiveRecord::Migration[8.1]
  def up
    add_foreign_key :staged_closeout_mappings, :users, column: :invalidated_by_id, validate: false
  end

  def down
    remove_foreign_key :staged_closeout_mappings, column: :invalidated_by_id
  end
end
