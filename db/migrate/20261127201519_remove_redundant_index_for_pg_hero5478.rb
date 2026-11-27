# frozen_string_literal: true

# index_bounded_actions_on_project_issue_action covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5478 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :bounded_delegated_actions, name: "index_bounded_delegated_actions_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :bounded_delegated_actions, [ :project_id ],
      name: "index_bounded_delegated_actions_on_project_id", algorithm: :concurrently
  end
end
