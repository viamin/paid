# frozen_string_literal: true

# index_ab_tests_on_prompt_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5436 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :ab_tests, name: "index_ab_tests_on_prompt_id", algorithm: :concurrently
  end

  def down
    add_index :ab_tests, [ :prompt_id ],
      name: "index_ab_tests_on_prompt_id", algorithm: :concurrently
  end
end
