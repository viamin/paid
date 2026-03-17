# frozen_string_literal: true

class CreateAbTestAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :ab_test_assignments do |t|
      t.references :ab_test, null: false, foreign_key: { on_delete: :cascade }
      t.references :ab_test_variant, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, index: false, foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :ab_test_assignments, :agent_run_id, unique: true
  end
end
