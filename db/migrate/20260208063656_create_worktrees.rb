# frozen_string_literal: true

class CreateWorktrees < ActiveRecord::Migration[8.1]
  def change
    create_table :worktrees do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, foreign_key: { on_delete: :nullify }

      t.string :path, null: false
      t.string :branch_name, null: false
      t.string :base_commit, limit: 40
      t.string :status, limit: 50, default: "active", null: false
      t.boolean :pushed, default: false, null: false

      t.datetime :cleaned_at

      t.timestamps
    end

    add_index :worktrees, [ :project_id, :branch_name ], unique: true
    add_index :worktrees, :status
  end
end
