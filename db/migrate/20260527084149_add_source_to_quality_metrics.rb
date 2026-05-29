# frozen_string_literal: true

class AddSourceToQualityMetrics < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:quality_metrics, :source)
      add_column :quality_metrics, :source, :string,
        null: false,
        default: "agent_run",
        comment: "Origin of the metric row so scheduled mutation sweeps stay distinct from per-agent-run quality metrics."
    end

    unless index_exists?(:quality_metrics, :source)
      add_index :quality_metrics, :source, algorithm: :concurrently
    end
  end

  def down
    remove_index :quality_metrics, :source, algorithm: :concurrently if index_exists?(:quality_metrics, :source)
    remove_column :quality_metrics, :source if column_exists?(:quality_metrics, :source)
  end
end
