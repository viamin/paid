# frozen_string_literal: true

# idx_shadow_evaluation_runs_case covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5581 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_shadow_evaluation_runs, name: "idx_on_shadow_evaluation_id_ffb203051f", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_shadow_evaluation_runs, [ :shadow_evaluation_id ],
      name: "idx_on_shadow_evaluation_id_ffb203051f", algorithm: :concurrently
  end
end
