# frozen_string_literal: true

# index_onboarding_steps_on_account_id_and_step covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5668 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :onboarding_steps, name: "index_onboarding_steps_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :onboarding_steps, [ :account_id ],
      name: "index_onboarding_steps_on_account_id", algorithm: :concurrently
  end
end
