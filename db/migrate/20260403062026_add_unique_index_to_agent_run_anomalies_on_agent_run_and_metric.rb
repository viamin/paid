# frozen_string_literal: true

class AddUniqueIndexToAgentRunAnomaliesOnAgentRunAndMetric < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :agent_run_anomalies, [ :agent_run_id, :metric_name ],
      name: "index_agent_run_anomalies_on_agent_run_id_and_metric_name",
      unique: true,
      algorithm: :concurrently
  end
end
