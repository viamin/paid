# frozen_string_literal: true

class CreatePromptsAndPromptVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :prompts do |t|
      t.string :slug, limit: 100, null: false
      t.string :name, limit: 255, null: false
      t.text :description
      t.string :category, limit: 50, null: false

      t.references :account, null: true, foreign_key: { on_delete: :cascade }
      t.references :project, null: true, foreign_key: { on_delete: :cascade }

      t.bigint :current_version_id, null: true

      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :prompts, :current_version_id
    add_index :prompts, :category
    add_index :prompts, :active

    # Partial unique indexes for slug uniqueness at each scope level
    # (PostgreSQL treats NULLs as distinct in unique indexes)
    add_index :prompts, :slug, unique: true,
      where: "account_id IS NULL AND project_id IS NULL",
      name: "index_prompts_on_slug_global"
    add_index :prompts, [:slug, :account_id], unique: true,
      where: "account_id IS NOT NULL AND project_id IS NULL",
      name: "index_prompts_on_slug_account"
    add_index :prompts, [:slug, :project_id], unique: true,
      where: "project_id IS NOT NULL",
      name: "index_prompts_on_slug_project"

    create_table :prompt_versions do |t|
      t.references :prompt, null: false, foreign_key: { on_delete: :cascade }

      t.integer :version, null: false
      t.text :template, null: false
      t.jsonb :variables, default: [], null: false
      t.text :system_prompt

      t.text :change_notes
      t.string :created_by, limit: 50
      t.references :created_by_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :parent_version, null: true, foreign_key: { to_table: :prompt_versions, on_delete: :nullify }

      t.integer :usage_count, default: 0, null: false
      t.decimal :avg_quality_score, precision: 4, scale: 2
      t.decimal :avg_iterations, precision: 4, scale: 2

      t.datetime :created_at, null: false
    end

    add_index :prompt_versions, [:prompt_id, :version], unique: true

    add_foreign_key :prompts, :prompt_versions, column: :current_version_id, on_delete: :nullify
  end
end
