# frozen_string_literal: true

# idx_failure_classifications_project_created covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5546 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :failure_classifications, name: "index_failure_classifications_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :failure_classifications, [ :project_id ],
      name: "index_failure_classifications_on_project_id", algorithm: :concurrently
  end
end
