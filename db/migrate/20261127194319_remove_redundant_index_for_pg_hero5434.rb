# frozen_string_literal: true

# index_ab_test_assignments_unique covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5434 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :ab_test_assignments, name: "index_ab_test_assignments_on_ab_test_id", algorithm: :concurrently
  end

  def down
    add_index :ab_test_assignments, [ :ab_test_id ],
      name: "index_ab_test_assignments_on_ab_test_id", algorithm: :concurrently
  end
end
