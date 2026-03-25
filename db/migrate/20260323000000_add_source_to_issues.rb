# frozen_string_literal: true

class AddSourceToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    # PostgreSQL 11+ stores the DEFAULT in pg_attribute metadata without
    # rewriting the table, so this ADD COLUMN is fast even on large tables.
    # disable_ddl_transaction! is required only for the CONCURRENTLY indexes
    # below. The idempotent guards (column_exists?/index_exists?) make re-runs
    # safe if the non-atomic migration is interrupted between statements.
    add_column :issues, :source, :string, default: "github", null: false unless column_exists?(:issues, :source)
    add_index :issues, :source, algorithm: :concurrently unless index_exists?(:issues, :source)
    unless index_exists?(:issues, [ :project_id, :source, :github_state ])
      add_index :issues, [ :project_id, :source, :github_state ], algorithm: :concurrently,
        name: "idx_issues_on_project_source_state"
    end
  end

  def down
    remove_index :issues, name: "idx_issues_on_project_source_state", algorithm: :concurrently, if_exists: true
    remove_index :issues, :source, algorithm: :concurrently, if_exists: true
    remove_column :issues, :source if column_exists?(:issues, :source)
  end
end
