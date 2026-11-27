# frozen_string_literal: true

# idx_on_apple_verification_attempt_id_kind_82be1ab43b covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5461 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :apple_verification_artifacts, name: "idx_on_apple_verification_attempt_id_0873cc6e26", algorithm: :concurrently
  end

  def down
    add_index :apple_verification_artifacts, [ :apple_verification_attempt_id ],
      name: "idx_on_apple_verification_attempt_id_0873cc6e26", algorithm: :concurrently
  end
end
