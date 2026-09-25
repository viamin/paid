# frozen_string_literal: true

class AddReopenedByForeignKeyToIssues < ActiveRecord::Migration[8.1]
  def change
    return if foreign_key_exists?(:issues, :users, column: :reopened_by_id)

    add_foreign_key :issues, :users, column: :reopened_by_id, validate: false
  end
end
