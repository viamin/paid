# frozen_string_literal: true

class ValidateReopenedByForeignKeyOnIssues < ActiveRecord::Migration[8.1]
  def change
    return unless foreign_key_exists?(:issues, :users, column: :reopened_by_id)

    validate_foreign_key :issues, :users, column: :reopened_by_id
  end
end
