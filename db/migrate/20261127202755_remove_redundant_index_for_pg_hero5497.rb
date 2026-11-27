# frozen_string_literal: true

# index_conflict_repair_scope_evidence_identity covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5497 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :conflict_repair_scope_evidences, name: "index_conflict_repair_scope_evidences_on_agent_run_id", algorithm: :concurrently
  end

  def down
    add_index :conflict_repair_scope_evidences, [ :agent_run_id ],
      name: "index_conflict_repair_scope_evidences_on_agent_run_id", algorithm: :concurrently
  end
end
