# frozen_string_literal: true

class AddSourceToQualityMetrics < ActiveRecord::Migration[8.1]
  def up
    add_column :quality_metrics, :source, :string,
      null: false,
      default: "agent_run",
      comment: "Origin of the metric row so scheduled mutation sweeps stay distinct from per-agent-run quality metrics."
    add_index :quality_metrics, :source
  end

  def down
    remove_index :quality_metrics, :source if index_exists?(:quality_metrics, :source)
    remove_column :quality_metrics, :source
  end
end
