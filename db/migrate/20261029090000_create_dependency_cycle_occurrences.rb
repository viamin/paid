# frozen_string_literal: true

class CreateDependencyCycleOccurrences < ActiveRecord::Migration[8.1]
  def change
    create_table :dependency_cycle_occurrences do |t|
      t.references :account, null: false, foreign_key: true
      t.string :cycle_key, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :details, null: false, default: {}
      t.datetime :last_detected_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :dependency_cycle_occurrences, [ :account_id, :cycle_key ], unique: true
    add_index :dependency_cycle_occurrences, [ :account_id, :active ]
  end
end
