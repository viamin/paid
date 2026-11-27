# frozen_string_literal: true

# idx_issue_dependencies_unique covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5584 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :issue_dependencies, name: "index_issue_dependencies_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :issue_dependencies, [ :issue_id ],
      name: "index_issue_dependencies_on_issue_id", algorithm: :concurrently
  end
end
