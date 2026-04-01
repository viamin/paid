# frozen_string_literal: true

class CreatePreCommitRequirements < ActiveRecord::Migration[8.1]
  def change
    create_table :pre_commit_requirements do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: true, foreign_key: { on_delete: :cascade }
      t.references :user, null: true, foreign_key: { on_delete: :cascade }
      t.string :name, limit: 255, null: false
      t.text :command, null: false
      t.string :check_type, limit: 50, null: false, default: "shell_command"
      t.text :fix_command
      t.string :failure_behavior, limit: 50, null: false, default: "block"
      t.integer :position, null: false, default: 0
      t.boolean :enabled, null: false, default: true

      t.timestamps null: false
    end

    add_index :pre_commit_requirements, [ :account_id, :project_id, :user_id, :name ],
      unique: true, name: "idx_pre_commit_requirements_unique_name"
    add_index :pre_commit_requirements, [ :project_id, :position ],
      where: "project_id IS NOT NULL", name: "idx_pre_commit_requirements_project_position"
    add_index :pre_commit_requirements, [ :user_id, :position ],
      where: "user_id IS NOT NULL", name: "idx_pre_commit_requirements_user_position"
    add_index :pre_commit_requirements, [ :account_id, :position ],
      where: "project_id IS NULL AND user_id IS NULL",
      name: "idx_pre_commit_requirements_account_position"
  end
end
