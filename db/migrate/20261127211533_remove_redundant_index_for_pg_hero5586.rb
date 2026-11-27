# frozen_string_literal: true

# index_issues_on_project_id_and_paid_activation_state covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5586 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :issues, name: "index_issues_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :issues, [ :project_id ],
      name: "index_issues_on_project_id", algorithm: :concurrently
  end
end
