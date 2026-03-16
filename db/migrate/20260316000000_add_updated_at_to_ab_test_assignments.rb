# frozen_string_literal: true

class AddUpdatedAtToAbTestAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :ab_test_assignments, :updated_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }
  end
end
