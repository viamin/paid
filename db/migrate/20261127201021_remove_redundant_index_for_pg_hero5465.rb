# frozen_string_literal: true

# idx_apple_verification_images_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5465 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :apple_verification_images, name: "index_apple_verification_images_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :apple_verification_images, [ :account_id ],
      name: "index_apple_verification_images_on_account_id", algorithm: :concurrently
  end
end
