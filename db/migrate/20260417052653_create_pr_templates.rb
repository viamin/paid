# frozen_string_literal: true

class CreatePrTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :pr_templates do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: true, foreign_key: { on_delete: :cascade }
      t.references :user, null: true, foreign_key: { on_delete: :cascade }
      t.string :name, limit: 255, null: false
      t.string :pr_type, limit: 50, null: false, default: "default"
      t.text :body, null: false
      t.text :description
      t.integer :position, null: false, default: 0
      t.boolean :enabled, null: false, default: true

      t.timestamps null: false
    end

    # Partial unique indexes — PostgreSQL treats NULLs as distinct
    add_index :pr_templates, [ :account_id, :name ],
      unique: true,
      where: "project_id IS NULL AND user_id IS NULL",
      name: "idx_pr_templates_account_name_unique"
    add_index :pr_templates, [ :project_id, :name ],
      unique: true,
      where: "project_id IS NOT NULL",
      name: "idx_pr_templates_project_name_unique"
    add_index :pr_templates, [ :user_id, :name ],
      unique: true,
      where: "user_id IS NOT NULL AND project_id IS NULL",
      name: "idx_pr_templates_user_name_unique"
    add_index :pr_templates, [ :project_id, :position ],
      where: "project_id IS NOT NULL",
      name: "idx_pr_templates_project_position"
    add_index :pr_templates, [ :user_id, :position ],
      where: "user_id IS NOT NULL",
      name: "idx_pr_templates_user_position"
    add_index :pr_templates, [ :account_id, :position ],
      where: "project_id IS NULL AND user_id IS NULL",
      name: "idx_pr_templates_account_position"

    # Prevent a template from being scoped to both a project and a user
    add_check_constraint :pr_templates,
      "NOT (project_id IS NOT NULL AND user_id IS NOT NULL)",
      name: "pr_templates_scope_check"
  end
end
