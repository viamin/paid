# frozen_string_literal: true

# index_agent_planning_holds_on_issue_id_and_label covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5446 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_planning_holds, name: "index_agent_planning_holds_on_issue_id", algorithm: :concurrently
  end

  def down
    add_index :agent_planning_holds, [ :issue_id ],
      name: "index_agent_planning_holds_on_issue_id", algorithm: :concurrently
  end
end
