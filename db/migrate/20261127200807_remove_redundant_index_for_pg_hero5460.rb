# frozen_string_literal: true

# idx_api_usage_attempts_project_created covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5460 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :api_usage_attempts, name: "index_api_usage_attempts_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :api_usage_attempts, [ :project_id ],
      name: "index_api_usage_attempts_on_project_id", algorithm: :concurrently
  end
end
