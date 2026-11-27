# frozen_string_literal: true

# idx_llm_output_metrics_project_type_time covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5602 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :llm_output_metrics, name: "index_llm_output_metrics_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :llm_output_metrics, [ :project_id ],
      name: "index_llm_output_metrics_on_project_id", algorithm: :concurrently
  end
end
