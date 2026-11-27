# frozen_string_literal: true

# idx_shadow_evaluation_labels_case covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5580 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_shadow_evaluation_labels, name: "idx_on_shadow_evaluation_id_faf0701cf6", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_shadow_evaluation_labels, [ :shadow_evaluation_id ],
      name: "idx_on_shadow_evaluation_id_faf0701cf6", algorithm: :concurrently
  end
end
