# frozen_string_literal: true

# idx_shadow_evaluations_one_per_evidence_generation covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5582 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :intent_conformance_shadow_evaluations, name: "index_intent_conformance_shadow_evaluations_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :intent_conformance_shadow_evaluations, [ :project_id ],
      name: "index_intent_conformance_shadow_evaluations_on_project_id", algorithm: :concurrently
  end
end
