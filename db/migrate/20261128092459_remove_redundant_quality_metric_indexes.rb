# frozen_string_literal: true

class RemoveRedundantQualityMetricIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-028
  def up
    remove_index :quality_metrics, name: "index_quality_metrics_on_agent_run_id", algorithm: :concurrently, if_exists: true
    remove_index :quality_metrics, name: "index_quality_metrics_on_prompt_version_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :quality_metrics, :agent_run_id, algorithm: :concurrently, if_not_exists: true
    add_index :quality_metrics, :prompt_version_id, algorithm: :concurrently, if_not_exists: true
  end
end
