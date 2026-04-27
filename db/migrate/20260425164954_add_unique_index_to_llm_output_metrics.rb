# frozen_string_literal: true

class AddUniqueIndexToLlmOutputMetrics < ActiveRecord::Migration[8.1]
  def change
    add_index :llm_output_metrics,
      [ :project_id, :output_type, :source_type, :source_id ],
      unique: true,
      name: "idx_llm_output_metrics_unique_source"
  end
end
