# frozen_string_literal: true

# idx_facet_confidence_evaluation_labels_case covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5542 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :facet_confidence_evaluation_labels, name: "idx_on_facet_confidence_evaluation_id_2126f02a77", algorithm: :concurrently
  end

  def down
    add_index :facet_confidence_evaluation_labels, [ :facet_confidence_evaluation_id ],
      name: "idx_on_facet_confidence_evaluation_id_2126f02a77", algorithm: :concurrently
  end
end
