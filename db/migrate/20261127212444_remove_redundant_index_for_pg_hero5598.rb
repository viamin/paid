# frozen_string_literal: true

# index_layered_verification_review_packages_revision covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5598 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :layered_verification_review_packages, name: "index_layered_verification_review_packages_on_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :layered_verification_review_packages, [ :agent_run_id ],
      name: "index_layered_verification_review_packages_on_agent_run_id", algorithm: :concurrently
  end
end
