# frozen_string_literal: true

class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      # Associations
      t.references :account, null: false, foreign_key: true
      t.references :github_token, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }

      # GitHub identifiers
      t.bigint :github_id, null: false
      t.string :owner, null: false
      t.string :repo, null: false
      t.string :default_branch, default: "main", null: false

      # Configuration
      t.string :name, null: false
      t.boolean :active, default: true, null: false
      t.integer :poll_interval_seconds, default: 300, null: false

      # Label mappings for workflow stages (JSONB)
      t.jsonb :label_mappings, default: {}, null: false

      # Cached metrics for performance
      t.bigint :total_cost_cents, default: 0, null: false
      t.bigint :total_tokens_used, default: 0, null: false

      t.timestamps
    end

    add_index :projects, [ :account_id, :github_id ], unique: true
    add_index :projects, [ :account_id, :active ]
    add_index :projects, [ :owner, :repo ]
  end
end
