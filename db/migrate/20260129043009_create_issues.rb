# frozen_string_literal: true

class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues do |t|
      # Foreign keys
      t.references :project, null: false, foreign_key: true
      t.references :parent_issue, foreign_key: { to_table: :issues }

      # GitHub identifiers
      t.bigint :github_issue_id, null: false
      t.integer :github_number, null: false

      # Cached GitHub data
      t.string :title, limit: 1000, null: false
      t.text :body
      t.string :github_state, null: false
      t.jsonb :labels, default: [], null: false

      # Paid-specific state tracking
      t.string :paid_state, default: "new", null: false

      # Timestamps
      t.datetime :github_created_at, null: false
      t.datetime :github_updated_at, null: false
      t.timestamps
    end

    # Composite unique index on project_id + github_issue_id
    add_index :issues, [ :project_id, :github_issue_id ], unique: true

    # Index for querying by state
    add_index :issues, :paid_state

    # Index for parent_issue lookups (sub-issues)
    add_index :issues, :parent_issue_id
  end
end
